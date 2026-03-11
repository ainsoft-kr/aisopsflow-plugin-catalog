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
