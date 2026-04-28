# Unreleased

* Upgrade to Pixelfed v0.12.7 (from v0.12.4)
* Upgrade to OE devenv 2.8.3 (from 2.5.3); requires `--break-system-packages` for pip3 install (Ubuntu 24.04 / PEP 668)
* Upgrade to CDK 2.225.0 (from 2.120.0)
* Upgrade to OE Common Constructs 4.5.1 (from 4.1.2)
* Upgrade to OE Utilities 1.10.0 (packer SCRIPT_VERSION + common.mk)
* Adopt versioned AMI parameter convention (`AsgAmiIdv210`); `Asg()` now requires explicit `ami_id=AMI_ID`
* Remove hardcoded VPC parameters from `Makefile` deploy target — CDK now creates a fresh VPC per deploy (matches taskcat/mastodon convention)
* Switch deploy command from `docker-compose` (V1) to `docker compose` (V2)
* Rebrand AWS Marketplace listing to "Pixelfed on AWS by FOSSonCloud" with new FOSSonCloud logo (apply via `make marketplace-rebrand`)
* Flatten Marketplace pricing to $0.02/hr across all instance dimensions (apply via `make marketplace-reprice`)
* Adding TaskCat test
* Adding link to marketplace product

* Add `test/integration/` with playwright integration tests modeled on `aws-marketplace-oe-patterns-mastodon`. Includes a headline `test_upload_photo_lands_in_s3` that logs in via the UI, POSTs to `/api/v1/media` with the cookie session, and asserts the upload appears in the AssetsBucket within 30s. 11 tests total: HTTPS/TLS health, instance API version pin, CFN stack + EC2 + S3 infrastructure checks, homepage + login UI smoke, photo upload to S3.

**Outstanding before Phase 6 (Marketplace submission):**

* Generate `diagram.png` (architecture diagram) and publish via `make publish-diagram`. Placeholder URL is in `marketplace_config.yaml` (`pixelfed/2.1.0/diagram.png`).

# 2.0.0

* Upgrade devenv to 2.5.3
* Upgrade oe-patterns-cdk-common to 4.1.1
  * Upgrade MySQL to 8.0 (*update causes downtime*)
* Upgrade cdk to 2.120.0
* Upgrade Pixelfed to v0.12.4

# 1.1.0

* Upgrade to Pixelfed v0.11.9
* Add ActivityPubEnabled parameter
* Enable Mastodon Login feature
* Add health check URI

# 1.0.0

* Initial development
