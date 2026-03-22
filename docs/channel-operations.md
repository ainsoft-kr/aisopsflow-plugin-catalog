# Channel Operations

This document describes the operational flow for bundle-based plugin release and channel rollout.

## Publish Flow

1. Build a plugin bundle containing `runner-plugin.yaml` and the declared entrypoint.
2. Publish the bundle to the catalog server.
3. Export the generated catalog manifest into `plugins/official/`.
4. Validate the repository.
5. Promote the version into `stable` when ready.

Recommended command:

```bash
make publish-export BUNDLE_PATH=/tmp/http-client-0.1.0.tar.gz
```

Equivalent direct script example:

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
  /tmp/http-client-0.1.0.tar.gz
```

Validation:

```bash
make validate
```

## Promote Flow

Promote a published version into `stable`:

```bash
make promote CHANNEL=stable
```

Inspect plugin versions and channels:

```bash
curl http://127.0.0.1:3100/api/plugins/http-client
```

Resolve a capability from `stable`:

```bash
make resolve CHANNEL=stable
```

## Notes

- `latest` is updated automatically at publish time.
- `stable` is an explicit operational decision.
- Runner should consume the `artifact.url` returned by the resolve API, not build URLs locally.

## Smoke Test

Use the bundled smoke test script to run:

- catalog health check
- publish and export
- `stable` promotion
- resolve verification
- catalog validation
- optional Core override update

Example:

```bash
make smoke-test BUNDLE_PATH=/tmp/http-client-0.1.0.tar.gz
```
