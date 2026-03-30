# AisOpsFlow Plugin Catalog

Public catalog metadata for AisOpsFlow plugins.

Catalog entries may point to either:

- an OCI image reference via `image`
- a generic plugin source reference via `plugin_ref`
- a bundle artifact via `artifact.url`

## Purpose

- publish plugin manifests
- track compatibility with Core/Runner versions
- record verification status
- store lightweight signature and vulnerability evidence for cataloged plugins
- separate catalog metadata from private product code

This repository does not build or publish plugin artifacts by itself.
It tracks plugin metadata, compatibility, and verification state for OCI- and bundle-based plugins.

## Admin Login

There is no built-in default admin username/password.

- The catalog server creates admin users only when one of these environment variables is set at startup:
- `PLUGIN_CATALOG_BOOTSTRAP_ADMIN_USERNAME` and `PLUGIN_CATALOG_BOOTSTRAP_ADMIN_PASSWORD`
- `PLUGIN_CATALOG_SEED_OWNER_PASSWORD`
- `PLUGIN_CATALOG_SEED_ADMIN_PASSWORD`
- `PLUGIN_CATALOG_SEED_PUBLISHER_PASSWORD`
- `PLUGIN_CATALOG_SEED_VIEWER_PASSWORD`

With the current default deploy file [`deploy/stack.catalog.yml`](/Users/ygpark2/pjt/ainsoft/aisopsflow/aisopsflow-plugin-catalog/deploy/stack.catalog.yml), only `PLUGIN_CATALOG_UPLOAD_TOKEN=dev-token` is configured, so no admin account is created automatically.

Example bootstrap config:

```bash
PLUGIN_CATALOG_BOOTSTRAP_ADMIN_USERNAME=admin
PLUGIN_CATALOG_BOOTSTRAP_ADMIN_PASSWORD=change-me
PLUGIN_CATALOG_BOOTSTRAP_ADMIN_DISPLAY_NAME=Administrator
```

Bundle upload size is controlled by `PLUGIN_CATALOG_MAX_UPLOAD_BYTES`.
The default in [`deploy/stack.catalog.yml`](/Users/ygpark2/pjt/ainsoft/aisopsflow/aisopsflow-plugin-catalog/deploy/stack.catalog.yml) is `104857600` (100 MiB).

## Layout

- `plugins/official/`
- `compatibility/`
- `schemas/`
- `verification/`
- `docs/`

## Make Targets

The default operational entrypoints are exposed through `make`:

```bash
make help
make server-run
make server-stop
make server-restart
make swarm-local-build
make swarm-local-up
make swarm-local-down
make swarm-local-restart
make validate
make publish-export BUNDLE_PATH=/path/to/bundle.tar.gz
make promote CHANNEL=stable
make resolve
make smoke-test BUNDLE_PATH=/path/to/bundle.tar.gz
```

Common overrides:

```bash
make publish-export \
  CATALOG_BASE_URL=http://127.0.0.1:3100 \
  CATALOG_TOKEN=dev-token \
  PLUGIN_NAME=http-client \
  PLUGIN_VERSION=0.1.0 \
  PLATFORM=linux-amd64 \
  BUNDLE_PATH=/path/to/bundle.tar.gz
```

## Direct Scripts

When using the Yesod catalog server, export a published catalog manifest back into this repository with:

```bash
bash scripts/export-catalog-manifest.sh http://127.0.0.1:3100 http-client 0.1.0
```

To publish a bundle and immediately export the catalog manifest in one step:

```bash
bash scripts/publish-and-export.sh \
  http://127.0.0.1:3100 \
  dev-token \
  http-client \
  0.1.0 \
  aisopsflow \
  node \
  linux-amd64 \
  dist/runner-entrypoint.js \
  http.request \
  /path/to/bundle.tar.gz
```

Promote a version to `stable`:

```bash
curl -X POST \
  -H 'Content-Type: application/json' \
  -d '{"channel":"stable"}' \
  http://127.0.0.1:3100/api/plugins/http-client/0.1.0/promote
```

Resolve a capability through the `stable` channel:

```bash
curl "http://127.0.0.1:3100/api/resolve/http.request?platform=linux-amd64&channel=stable"
```

Detailed operational steps are in [docs/channel-operations.md](./docs/channel-operations.md).

Run an end-to-end catalog smoke test:

```bash
bash scripts/smoke-test.sh \
  http://127.0.0.1:3100 \
  dev-token \
  http-client \
  0.1.0 \
  aisopsflow \
  node \
  linux-amd64 \
  dist/runner-entrypoint.js \
  http.request \
  /path/to/bundle.tar.gz
```
