# Submission Guide

Publishers should submit metadata, not source code uploads.

Required:

- plugin manifest
- OCI image reference pinned by digest
- compatibility declaration
- support/security contact
- schema compliance with `schemas/plugin-manifest-v1.yaml`

Required for `verification.status: official`:

- `verification.signed_image` metadata
- `verification.signature_ref` artifact committed to this catalog
- `verification.vulnerabilities` summary
- `verification.vulnerabilities.report_ref` artifact committed to this catalog

Preferred:

- SBOM
- conformance test report

## Official Plugin Source Layout

For the AisOpsFlow-maintained SDK repository, catalog entries that represent official published plugins should point to implementations that live under:

- `plugins/official/<plugin-name>/`

Examples, simulators, and fixtures should stay outside the official publish path, typically under:

- `examples/`

This keeps the catalog aligned with build and release targets and avoids mixing runnable product plugins with teaching fixtures.
