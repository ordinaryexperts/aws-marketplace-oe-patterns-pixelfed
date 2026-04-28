"""
User workflow tests for Pixelfed using Playwright.

Headline test: log in, upload a photo through the web UI, and assert
the uploaded media object actually lands in the configured S3 bucket.
This validates the end-to-end media pipeline (Vue UI -> /api/v1/media
controller -> Storage::disk('s3') -> bucket).

Prerequisites:
  - A confirmed admin user named `testadmin` (see config.yaml).
  - TEST_PIXELFED_PASSWORD env var set to that user's password.
  - Stack deployed with cloud storage enabled (PF_ENABLE_CLOUD=true).
"""

import io
import os
import struct
import time
import zlib
from pathlib import Path

import boto3
import pytest
from playwright.sync_api import sync_playwright, expect


def _make_test_png(width=320, height=240) -> bytes:
    """Generate a tiny valid PNG entirely in memory (no test fixture file).

    Solid-fill RGB image. Avoids depending on Pillow or a checked-in fixture
    image that could rot. Pixelfed accepts any valid image MIME type.
    """
    def _chunk(tag: bytes, data: bytes) -> bytes:
        return (
            struct.pack(">I", len(data))
            + tag
            + data
            + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)
        )

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    # Each row is filter byte + RGB triples; fill with a single color so
    # Pixelfed's image processor can't reject it as malformed.
    raw = b""
    for _ in range(height):
        raw += b"\x00" + (b"\x33\x66\xaa" * width)
    idat = _chunk(b"IDAT", zlib.compress(raw))
    iend = _chunk(b"IEND", b"")
    return sig + ihdr + idat + iend


@pytest.fixture(scope="session")
def test_password():
    """Test user password sourced from env (never committed)."""
    pw = os.environ.get("TEST_PIXELFED_PASSWORD")
    if not pw:
        pytest.skip(
            "TEST_PIXELFED_PASSWORD not set; create the test admin via SSM "
            "(`php artisan user:create --is_admin=1 --confirm_email=1 ...`) "
            "and export the password."
        )
    return pw


@pytest.fixture(scope="session")
def assets_bucket(cloudformation_client, stack_name):
    """Resolve the AssetsBucket physical resource ID from CloudFormation."""
    resp = cloudformation_client.describe_stack_resources(StackName=stack_name)
    for r in resp["StackResources"]:
        if (
            r["ResourceType"] == "AWS::S3::Bucket"
            and r["LogicalResourceId"] == "AssetsBucket"
        ):
            return r["PhysicalResourceId"]
    pytest.fail(f"AssetsBucket not found in stack {stack_name}")


@pytest.fixture(scope="session")
def s3_client(aws_region):
    return boto3.client("s3", region_name=aws_region)


@pytest.mark.ui
class TestPixelfedWebUI:
    """Level 3: Browser-driven workflow tests."""

    @pytest.fixture(scope="class")
    def browser_context(self):
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            context = browser.new_context(
                viewport={"width": 1280, "height": 800},
                user_agent="OE-Patterns-Integration-Test/1.0 (Chromium)",
            )
            yield context
            context.close()
            browser.close()

    def test_homepage_loads(self, base_url, browser_context):
        """Pixelfed homepage should render with the expected title."""
        page = browser_context.new_page()
        try:
            page.goto(base_url, wait_until="networkidle", timeout=30000)
            assert page.title(), "Page title should not be empty"
            assert "pixelfed" in page.content().lower(), "Page should mention Pixelfed"
        finally:
            page.close()

    def test_login_redirects_to_web_app(
        self, base_url, browser_context, config, test_password
    ):
        """Login as testadmin and verify we land on /i/web (the SPA)."""
        page = browser_context.new_page()
        try:
            page.goto(f"{base_url}/login", timeout=30000)

            # Fill email + password (Pixelfed login form is standard Laravel)
            page.fill('input[name="email"]', config["test_user"]["email"])
            page.fill('input[name="password"]', test_password)
            page.click('button[type="submit"]')

            # Successful login redirects to /i/web (the Vue app)
            page.wait_for_url("**/i/web", timeout=30000)
            assert "/i/web" in page.url, f"Expected /i/web, got {page.url}"
        finally:
            page.close()


@pytest.mark.ui
@pytest.mark.slow
class TestPixelfedPhotoUploadToS3:
    """End-to-end: upload a photo via the web UI and verify it lands in S3.

    The single test here is the headline integration assertion for the
    pattern's most important data path. If this passes, the cloud-storage
    wiring (IAM role -> bucket -> filesystem disk binding) is correct.
    """

    @pytest.fixture(scope="class")
    def browser_context(self):
        with sync_playwright() as p:
            browser = p.chromium.launch(headless=True)
            context = browser.new_context(
                viewport={"width": 1280, "height": 800},
                accept_downloads=False,
            )
            yield context
            context.close()
            browser.close()

    def _login(self, page, base_url, email, password):
        page.goto(f"{base_url}/login", timeout=30000)
        page.fill('input[name="email"]', email)
        page.fill('input[name="password"]', password)
        page.click('button[type="submit"]')
        page.wait_for_url("**/i/web", timeout=30000)

    def test_upload_photo_lands_in_s3(
        self,
        base_url,
        browser_context,
        config,
        test_password,
        assets_bucket,
        s3_client,
        tmp_path,
    ):
        """Verify a real photo upload via Pixelfed's HTTP API lands in S3.

        Approach: log in through the UI (validates the real auth+CSRF flow),
        then post the photo via /api/v1/media using the same cookie context
        — that's the same endpoint Pixelfed's Vue compose UI hits via XHR,
        and exercises the same controller -> Storage::disk('cloud') path.

        We deliberately don't drive Dropzone from the UI because its hidden
        <input type="file"> doesn't fire a Vue change handler from
        set_input_files() and the visible drop zone uses an internal
        Dropzone.js handle that's awkward to invoke headlessly. The cookie
        session preserves auth + CSRF state from the real login.
        """
        from urllib.parse import unquote

        before = {
            obj["Key"]
            for obj in (
                s3_client.list_objects_v2(Bucket=assets_bucket).get("Contents") or []
            )
        }

        png_bytes = _make_test_png()
        page = browser_context.new_page()
        try:
            self._login(page, base_url, config["test_user"]["email"], test_password)

            # Pull the XSRF-TOKEN cookie set by Laravel during the session
            # bootstrap; this is the value Pixelfed's web UI sends as the
            # X-XSRF-TOKEN header on every XHR.
            cookies = {c["name"]: c["value"] for c in browser_context.cookies()}
            assert "XSRF-TOKEN" in cookies, "Login did not set XSRF-TOKEN cookie"

            response = browser_context.request.post(
                f"{base_url}/api/v1/media",
                headers={
                    "X-XSRF-TOKEN": unquote(cookies["XSRF-TOKEN"]),
                    "Accept": "application/json",
                },
                multipart={
                    "file": {
                        "name": "pixelfed-upload-validation.png",
                        "mimeType": "image/png",
                        "buffer": png_bytes,
                    }
                },
            )
            assert response.status == 200, (
                f"POST /api/v1/media returned {response.status}: {response.text()[:500]}"
            )
            media = response.json()
            assert "url" in media, f"Response missing url field: {media}"
            assert "id" in media, f"Response missing id field: {media}"

        finally:
            page.close()

        # Pixelfed processes uploads via Laravel queue jobs (image optimize,
        # thumbnail, persist to disk), so the S3 write may lag the 200
        # response by a few seconds. Poll up to 30s before failing.
        new_keys = set()
        deadline = time.time() + 30
        while time.time() < deadline:
            after = {
                obj["Key"]
                for obj in (
                    s3_client.list_objects_v2(Bucket=assets_bucket).get("Contents") or []
                )
            }
            new_keys = after - before
            if new_keys:
                break
            time.sleep(2)

        assert new_keys, (
            f"No new objects appeared in s3://{assets_bucket}/ within 30s of upload. "
            f"Pixelfed cloud-storage wiring may be broken. Bucket size before: "
            f"{len(before)}. The /api/v1/media response was: {media}"
        )

        # The originals live under public/m/_v2/<user>/<hash>/<dir>/<filename>
        # and Pixelfed creates a _thumb.png alongside.
        media_keys = [k for k in new_keys if k.startswith("public/m/")]
        assert media_keys, (
            f"New objects appeared but none under public/m/ — Pixelfed may "
            f"be writing to an unexpected prefix. New keys: {sorted(new_keys)}"
        )
        head = s3_client.head_object(Bucket=assets_bucket, Key=media_keys[0])
        assert head["ContentLength"] > 0, "Uploaded object is empty"
