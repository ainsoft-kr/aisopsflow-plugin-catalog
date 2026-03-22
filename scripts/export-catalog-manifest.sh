#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 3 ] || [ "$#" -gt 4 ]; then
  echo "usage: $0 <server-base-url> <plugin-name> <version> [output-path]" >&2
  exit 1
fi

server_base_url="${1%/}"
plugin_name="$2"
version="$3"
output_path="${4:-plugins/official/${plugin_name}.yaml}"

tmp_path="$(mktemp)"
trap 'rm -f "$tmp_path"' EXIT

curl --fail --silent --show-error \
  "${server_base_url}/api/plugins/${plugin_name}/${version}/catalog-manifest" \
  -o "$tmp_path"

mkdir -p "$(dirname "$output_path")"
mv "$tmp_path" "$output_path"

echo "exported ${plugin_name}@${version} to ${output_path}"
