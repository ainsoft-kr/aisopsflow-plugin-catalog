# Submission Guide

Publishers should submit metadata, not source code uploads.

Required:

- plugin manifest
- one plugin source declaration:
  - `image` for OCI-based plugins
  - `plugin_ref` for generic source refs
  - `artifact.url` for bundle-based plugins
- compatibility declaration
- support/security contact
- schema compliance with `schemas/plugin-manifest-v1.yaml`

Required for `verification.status: official`:

- `verification.signature_ref` artifact committed to this catalog when signatures are used
- `verification.signed_image` metadata for OCI-based plugins
- `artifact.sha256` for bundle-based plugins
- `verification.vulnerabilities` summary
- `verification.vulnerabilities.report_ref` artifact committed to this catalog

Preferred:

- SBOM
- conformance test report

## Server Publish Flow

For bundle-based plugins, the recommended flow is:

1. Upload the bundle to the Yesod catalog server with `scripts/publish-and-export.sh`
2. Export the generated catalog manifest back into `plugins/official/`
3. Run `ruby scripts/validate-catalog.rb`

The repository also provides a manual GitHub Actions workflow, `Catalog Publish Export`,
for environments that keep the bundle and publish token in CI-managed secrets.

After publish, promote the validated version into a serving channel such as `stable`:

```bash
curl -X POST \
  -H 'Content-Type: application/json' \
  -d '{"channel":"stable"}' \
  http://127.0.0.1:3100/api/plugins/http-client/0.1.0/promote
```

## Official Plugin Source Layout

For the AisOpsFlow-maintained SDK repository, catalog entries that represent official published plugins should point to implementations that live under:

- `plugins/official/<plugin-name>/`

Examples, simulators, and fixtures should stay outside the official publish path, typically under:

- `examples/`

This keeps the catalog aligned with build and release targets and avoids mixing runnable product plugins with teaching fixtures.
