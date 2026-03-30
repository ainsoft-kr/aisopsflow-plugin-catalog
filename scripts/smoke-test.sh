#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 10 ] || [ "$#" -gt 12 ]; then
  echo "usage: $0 <catalog-base-url> <catalog-token> <plugin-name> <version> <publisher> <runtime> <platform> <entrypoint> <capabilities-csv> <bundle-path> [core-base-url] [core-bearer-token]" >&2
  exit 1
fi

catalog_base_url="${1%/}"
catalog_token="$2"
plugin_name="$3"
version="$4"
publisher="$5"
runtime="$6"
platform="$7"
entrypoint="$8"
capabilities_csv="$9"
bundle_path="${10}"
core_base_url="${11:-}"
core_bearer_token="${12:-}"
IFS=',' read -r -a capabilities <<< "$capabilities_csv"

script_dir="$(cd "$(dirname "$0")" && pwd)"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "missing required command: $1" >&2
    exit 1
  fi
}

require_cmd curl
require_cmd ruby
require_cmd bash

echo "[smoke] checking catalog health"
curl --fail --silent --show-error "${catalog_base_url}/healthz" >/dev/null

echo "[smoke] publish and export ${plugin_name}@${version}"
bash "${script_dir}/publish-and-export.sh" \
  "$catalog_base_url" \
  "$catalog_token" \
  "$plugin_name" \
  "$version" \
  "$publisher" \
  "$runtime" \
  "$platform" \
  "$entrypoint" \
  "$capabilities_csv" \
  "$bundle_path"

echo "[smoke] promote ${plugin_name}@${version} to stable"
curl --fail --silent --show-error \
  -X POST \
  -H "Content-Type: application/json" \
  -d '{"channel":"stable"}' \
  "${catalog_base_url}/api/plugins/${plugin_name}/${version}/promote" >/dev/null

for capability in "${capabilities[@]}"; do
  echo "[smoke] resolve ${capability} from stable"
  resolve_payload="$(
    curl --fail --silent --show-error \
      "${catalog_base_url}/api/resolve/${capability}?platform=${platform}&channel=stable"
  )"
  printf '%s\n' "$resolve_payload" | ruby -rjson -e '
payload = JSON.parse(STDIN.read)
artifact_url = payload.fetch("plugin").fetch("artifact").fetch("url")
abort("resolve payload missing artifact url") if artifact_url.to_s.empty?
source = payload["source"].to_s
abort("unexpected resolve source: #{source}") unless source.include?("stable")
'
done

echo "[smoke] validate catalog repository"
( cd "${script_dir}/.." && ruby scripts/validate-catalog.rb )

if [ -n "$core_base_url" ]; then
  if [ -z "$core_bearer_token" ]; then
    echo "core bearer token is required when core base url is provided" >&2
    exit 1
  fi
  for capability in "${capabilities[@]}"; do
    echo "[smoke] apply core override for ${capability}"
    curl --fail --silent --show-error \
      -X PUT \
      -H "Authorization: Bearer ${core_bearer_token}" \
      -H "Content-Type: application/json" \
      -d "$(printf '{"capability":"%s","plugin_ref":"","manifest_path":"runner-plugin.yaml","channel":"stable","enabled":true}' "$capability")" \
      "${core_base_url%/}/api/ops/catalog-overrides/${capability}" >/dev/null
  done
fi

echo "[smoke] success"
