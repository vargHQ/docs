#!/usr/bin/env sh
# Copy the varg API's OpenAPI spec into this repo's openapi.yaml.
#
# The source of truth is the API repo (vargHQ/api):
#   varg-api-proto/apps/api/src/routes/openapi/openapi.yaml
# Edit the spec there, in the same PR as the route change, then sync it here.
#
#   scripts/sync-openapi.sh            # from the sibling api checkout (vargHQ meta-repo layout)
#   scripts/sync-openapi.sh <file>     # from a given file
#   scripts/sync-openapi.sh --live     # what production serves (https://api.varg.ai/v2/openapi.yaml)
set -eu
cd "$(dirname "$0")/.."

src="${1:-../api/varg-api-proto/apps/api/src/routes/openapi/openapi.yaml}"
if [ "$src" = "--live" ]; then
  curl -fsSL https://api.varg.ai/v2/openapi.yaml -o openapi.yaml
else
  cp "$src" openapi.yaml
fi
echo "openapi.yaml synced from $src"
