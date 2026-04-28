"""
Health and basic connectivity tests for Pixelfed.
These tests validate infrastructure and basic application health.
"""

import pytest
import requests


class TestPixelfedHealth:
    """Level 1: Infrastructure and basic health tests."""

    def test_https_accessible(self, base_url):
        """Test that Pixelfed is accessible over HTTPS."""
        response = requests.get(base_url, timeout=30, allow_redirects=True)
        assert response.status_code == 200, \
            f"Failed to access Pixelfed at {base_url}"
        assert response.url.startswith("https://"), \
            "Pixelfed should be accessible via HTTPS"

    def test_instance_api(self, base_url, config):
        """Test Pixelfed instance API endpoint (Mastodon-compatible)."""
        instance_url = f"{base_url}/api/v1/instance"
        response = requests.get(instance_url, timeout=10)

        assert response.status_code == 200, \
            f"Instance API failed with status {response.status_code}"

        data = response.json()

        # Validate response structure
        assert "uri" in data, "Instance response missing 'uri' field"
        assert "version" in data, "Instance response missing 'version' field"

        # Validate version contains the expected Pixelfed version string
        expected_version = config["application"]["expected_version"]
        assert expected_version in data["version"], \
            f"Version mismatch. Expected: {expected_version}, Got: {data['version']}"

    def test_response_time(self, base_url):
        """Test that Pixelfed responds within acceptable time."""
        import time

        start = time.time()
        response = requests.get(f"{base_url}/api/v1/instance", timeout=30)
        elapsed = time.time() - start

        assert response.status_code == 200, "Instance API failed"
        assert elapsed < 5.0, \
            f"Response time {elapsed:.2f}s exceeds 5 seconds"

    def test_ssl_certificate(self, base_url):
        """Verify SSL certificate is valid."""
        import ssl
        import socket
        from urllib.parse import urlparse

        parsed = urlparse(base_url)
        hostname = parsed.hostname
        port = parsed.port or 443

        context = ssl.create_default_context()
        try:
            with socket.create_connection((hostname, port), timeout=10) as sock:
                with context.wrap_socket(sock, server_hostname=hostname) as ssock:
                    cert = ssock.getpeercert()
                    assert cert is not None, "No SSL certificate found"
        except ssl.SSLError as e:
            pytest.fail(f"SSL certificate validation failed: {e}")


class TestPixelfedInfrastructure:
    """Level 2: AWS infrastructure tests."""

    def test_cloudformation_stack_exists(self, cloudformation_client, stack_name):
        """Verify CloudFormation stack exists and is in good state."""
        response = cloudformation_client.describe_stacks(StackName=stack_name)

        assert len(response["Stacks"]) == 1, \
            f"Expected 1 stack, found {len(response['Stacks'])}"

        stack = response["Stacks"][0]
        assert stack["StackStatus"] in ["CREATE_COMPLETE", "UPDATE_COMPLETE"], \
            f"Stack is in unexpected state: {stack['StackStatus']}"

    def test_stack_outputs(self, stack_outputs):
        """Verify CloudFormation stack has required outputs."""
        required_outputs = [
            "DnsSiteUrlOutput",
            "VpcIdOutput",
        ]

        for output in required_outputs:
            assert output in stack_outputs, \
                f"Required output '{output}' missing from stack"
            assert stack_outputs[output], \
                f"Output '{output}' is empty"

    def test_ec2_instance_running(self, instance_id, ec2_client):
        """Verify EC2 instance is running."""
        response = ec2_client.describe_instances(InstanceIds=[instance_id])

        assert len(response["Reservations"]) > 0, \
            f"No reservations found for instance {instance_id}"

        instance = response["Reservations"][0]["Instances"][0]
        assert instance["State"]["Name"] == "running", \
            f"Instance is not running: {instance['State']['Name']}"

    def test_assets_bucket_exists(self, cloudformation_client, stack_name, aws_region):
        """Verify the AssetsBucket S3 bucket exists and is accessible."""
        import boto3

        cf_resources = cloudformation_client.describe_stack_resources(
            StackName=stack_name
        )
        buckets = [
            r["PhysicalResourceId"]
            for r in cf_resources["StackResources"]
            if r["ResourceType"] == "AWS::S3::Bucket"
            and r["LogicalResourceId"] == "AssetsBucket"
        ]
        assert buckets, "AssetsBucket not found in stack resources"

        s3 = boto3.client("s3", region_name=aws_region)
        # head_bucket succeeds if bucket exists and we have access
        s3.head_bucket(Bucket=buckets[0])
