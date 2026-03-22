#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 10 ] || [ "$#" -gt 11 ]; then
  echo "usage: $0 <server-base-url> <publish-token> <plugin-name> <version> <publisher> <runtime> <platform> <entrypoint> <capabilities-csv> <bundle-path> [output-path]" >&2
  exit 1
fi

server_base_url="${1%/}"
publish_token="$2"
plugin_name="$3"
version="$4"
publisher="$5"
runtime="$6"
platform="$7"
entrypoint="$8"
capabilities_csv="$9"
bundle_path="${10}"
output_path="${11:-plugins/official/${plugin_name}.yaml}"

if [ ! -f "$bundle_path" ]; then
  echo "bundle not found: $bundle_path" >&2
  exit 1
fi

curl --fail --silent --show-error \
  -X POST \
  -H "X-Plugin-Catalog-Token: ${publish_token}" \
  -F "name=${plugin_name}" \
  -F "version=${version}" \
  -F "publisher=${publisher}" \
  -F "runtime=${runtime}" \
  -F "platform=${platform}" \
  -F "entrypoint=${entrypoint}" \
  -F "capabilities=${capabilities_csv}" \
  -F "bundle=@${bundle_path}" \
  "${server_base_url}/api/publish" >/dev/null

bash "$(dirname "$0")/export-catalog-manifest.sh" \
  "$server_base_url" \
  "$plugin_name" \
  "$version" \
  "$output_path"

ruby "$(dirname "$0")/validate-catalog.rb"

echo "published and exported ${plugin_name}@${version}"
