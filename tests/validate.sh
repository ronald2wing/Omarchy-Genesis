#!/bin/bash

# Static validation for the Genesis plugin without a Quattro machine:
#   - manifest.json against the omarchy-plugin-validate rules
#   - bash syntax for every script in bin/
#   - JSON validity for config.example.json
#
# Usage: tests/validate.sh

set -uo pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
fail=0

manifest="$PLUGIN_DIR/manifest.json"

echo "== manifest.json =="
jq -e '.schemaVersion == 1' "$manifest" >/dev/null 2>&1 \
  || { echo "FAIL: schemaVersion must be 1"; fail=$((fail + 1)); }

for field in id name version author description; do
  jq -e --arg f "$field" 'has($f) and (.[$f] | type == "string") and (.[$f] | length > 0)' "$manifest" >/dev/null 2>&1 \
    || { echo "FAIL: missing required string field '$field'"; fail=$((fail + 1)); }
done

id=$(jq -r '.id // ""' "$manifest")
[[ $id =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ && $id != *..* && $id != omarchy.* ]] \
  || { echo "FAIL: invalid plugin id '$id'"; fail=$((fail + 1)); }
[[ $id == "${id,,}" ]] || { echo "FAIL: community plugin id must be lowercase ('$id')"; fail=$((fail + 1)); }

jq -e '(.kinds | type) == "array" and (.kinds | length) > 0' "$manifest" >/dev/null 2>&1 \
  || { echo "FAIL: kinds must be a non-empty array"; fail=$((fail + 1)); }

# kind -> entry point map enforced by omarchy-plugin-validate
for kind_entry in "bar:bar" "bar-widget:barWidget" "menu:menu" "overlay:overlay" "panel:panel" "service:service"; do
  kind="${kind_entry%%:*}"
  ep="${kind_entry##*:}"
  if jq -e --arg k "$kind" '(.kinds | index($k)) != null' "$manifest" >/dev/null 2>&1; then
    jq -e --arg e "$ep" '.entryPoints | has($e)' "$manifest" >/dev/null 2>&1 \
      || { echo "FAIL: kind '$kind' requires entryPoints.$ep"; fail=$((fail + 1)); }
    val=$(jq -r --arg e "$ep" '.entryPoints[$e] // ""' "$manifest")
    [[ -n $val && $val != /* && $val != *..* && -f "$PLUGIN_DIR/$val" ]] \
      || { echo "FAIL: entry point '$ep' -> '$val' missing or unsafe"; fail=$((fail + 1)); }
  fi
done

echo "== scripts (bash -n) =="
for f in "$PLUGIN_DIR"/bin/*; do
  [[ -f $f ]] || continue
  case "$f" in
  *.sh) continue ;;
  esac
  bash -n "$f" 2>/dev/null || { echo "FAIL: $f"; fail=$((fail + 1)); }
done

echo "== config.example.json =="
jq -e . "$PLUGIN_DIR/config.example.json" >/dev/null 2>&1 \
  || { echo "FAIL: config.example.json is not valid JSON"; fail=$((fail + 1)); }

echo
if (( fail == 0 )); then
  echo "all validations passed"
else
  echo "failed: $fail"
  exit 1
fi
