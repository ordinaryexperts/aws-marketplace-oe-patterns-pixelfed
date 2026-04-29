# Pixelfed Integration Tests

Integration tests for the Pixelfed AWS Marketplace pattern. Modeled on `aws-marketplace-oe-patterns-mastodon/test/integration/`.

## What's in here

- `test_health.py` — infrastructure + API health (HTTPS, TLS, version pin, CFN stack state, EC2 health, AssetsBucket existence)
- `test_workflows.py` — playwright UI workflow tests, including the **headline `test_upload_photo_lands_in_s3`** which:
  1. Logs in via the real `/login` form (validates CSRF + Laravel session)
  2. POSTs a generated PNG to `/api/v1/media` using the same cookie context (same path the Vue compose UI hits)
  3. Asserts new objects appear under `public/m/_v2/...` in the AssetsBucket S3 bucket within 30s

## Prerequisites

### Test admin user

The workflow tests log in as `testadmin` (configured in `config.yaml`). Create this user once on the running stack via SSM:

```bash
aws ssm send-command --instance-ids <i-...> --document-name AWS-RunShellScript \
  --parameters 'commands=["cd /usr/share/webapps/pixelfed && sudo -u www-data php artisan user:create --name=\"Test Admin\" --username=testadmin --email=testadmin@example.com --password=$PASSWORD --is_admin=1 --confirm_email=1 -n"]'
```

Save the password somewhere; the test reads it from `TEST_PIXELFED_PASSWORD`.

### Container deps

Tests run inside the devenv container via `make test-integration*`. Requires `ordinaryexperts/aws-marketplace-patterns-devenv:2.8.4` or newer (earlier images had a broken `playwright install` step that left chromium uninstalled — see devenv `2.8.4` CHANGELOG entry).

## Running

```bash
# health + infra only (fast, no UI)
make test-integration-health      # if defined
make test-integration              # via common.mk

# UI workflows (includes photo-upload-to-S3)
export TEST_PIXELFED_PASSWORD=...
make test-integration-ui

# everything
export TEST_PIXELFED_PASSWORD=...
make test-integration-all
```

The `TEST_BASE_URL`, `TEST_STACK_NAME`, and `TEST_PIXELFED_PASSWORD` env vars are passed through to the devenv container via `docker-compose.yml`.

## Markers

- `@pytest.mark.ui` — UI/browser tests (require chromium)
- `@pytest.mark.slow` — End-to-end tests with media upload + S3 polling

Skip UI: `pytest -m "not ui" -v`
