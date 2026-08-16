#!/bin/bash

# Shared helpers for the Genesis plugin scripts.
# Sourced by the scripts in this directory; not meant to be executed directly.

PLUGIN_ID="genesis"

# Config lives outside the plugin dir. The Omarchy shell hot-reloads any plugin
# whose directory changes (inotifywait -r on ~/.config/omarchy/plugins/), so
# writing config.json inside the plugin dir tears down the bar widget and closes
# the popup menu. GENESIS_CONFIG is a test override.
CONFIG_FILE="${GENESIS_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/$PLUGIN_ID/config.json}"

# One-time migration from the old in-plugin location (see above).
if [[ -z ${GENESIS_CONFIG:-} ]]; then
  OLD_CONFIG="$HOME/.config/omarchy/plugins/$PLUGIN_ID/config.json"
  if [[ -f $OLD_CONFIG && ! -f $CONFIG_FILE ]]; then
    mkdir -p "$(dirname "$CONFIG_FILE")"
    mv "$OLD_CONFIG" "$CONFIG_FILE"
  fi
fi
RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/$PLUGIN_ID"
CAPTURE_WAV="$RUNTIME_DIR/recording.wav"
CAPTURE_PID="$RUNTIME_DIR/capture.pid"

# True when a command exists on PATH.
have() { command -v "$1" >/dev/null 2>&1; }

# Resolve a language name to its interpreter and file extension:
#   lang_info <name>  →  "<interpreter> <extension>\n"
# Empty, "bash", and "sh" resolve to bash. Unknown names return non-zero.
lang_info() {
  case "${1:-bash}" in
    bash | sh) printf 'bash sh\n' ;;
    python | py) printf 'python3 py\n' ;;
    node | js | javascript) printf 'node js\n' ;;
    ruby | rb) printf 'ruby rb\n' ;;
    *) return 1 ;;
  esac
}

# Validate a language name and print its normalized form ("bash"/"sh" become ""
# — the "default" marker). Exits with a usage error on an unknown language.
normalize_lang() {
  local prefix="$1" lang="$2"
  lang_info "$lang" >/dev/null 2>&1 || { echo "$prefix: unknown language '$lang' (use bash, python, node, or ruby)" >&2; exit 2; }
  if [[ $lang == "bash" || $lang == "sh" ]]; then echo ""; else echo "$lang"; fi
}

# Print $1, or $2 when $1 is empty.
fallback() { local val="$1" default="$2"; [[ -n $val ]] && printf '%s' "$val" || printf '%s' "$default"; }

# Send a desktop notification titled "Genesis".
notify() {
  local body="${1:-}"
  if have omarchy-notification-send; then
    omarchy-notification-send "Genesis" "$body" >/dev/null 2>&1 || true
  elif have notify-send; then
    notify-send "Genesis" "$body" >/dev/null 2>&1 || true
  fi
}

# Read a config value by dot path (e.g. "agent.enabled"), falling back to $2.
config_get() {
  local path="$1" default="${2:-}"
  local val=""
  if [[ -f $CONFIG_FILE ]]; then
    val=$(jq -r --arg path "$path" --arg d "$default" '
      ($path | split(".")) as $parts
      | if getpath($parts) == null then $d else (getpath($parts) | tostring) end
    ' "$CONFIG_FILE" 2>/dev/null || true)
  fi
  fallback "$val" "$default"
}

# True when an action appears in the configured confirmActions list, read from
# config with a built-in fallback.
action_needs_confirm() {
  local action="$1" list=""
  if [[ -f $CONFIG_FILE ]]; then
    list=$(jq -r '.confirmActions // [] | join(" ")' "$CONFIG_FILE" 2>/dev/null || true)
  fi
  list=$(fallback "$list" "shutdown reboot logout suspend")
  [[ -n $action && " $list " == *" $action "* ]]
}

# Resolve a spoken device/room name to a Home Assistant entity_id via the
# `homeAssistant.entities` alias map. Matching order: exact, then substring
# (longest alias first), then word-subset (every alias word present, order-free
# — so "lights in the office" resolves "office lights"). Prints the entity_id,
# or nothing on failure. Always returns 0; callers check emptiness.
resolve_entity() {
  local name="$1" key
  key=$(normalize_text "$name")
  [[ -z $key ]] && return 0
  [[ -f $CONFIG_FILE ]] || return 0

  local eid
  eid=$(jq -r --arg k "$key" '.homeAssistant.entities[$k] // empty' "$CONFIG_FILE" 2>/dev/null || true)
  [[ -n $eid ]] && { printf '%s' "$eid"; return 0; }

  # Longest alias first, shared by both fuzzy passes.
  local aliases alias entity w ok
  aliases=$(jq -r '.homeAssistant.entities | to_entries | sort_by(.key | length) | reverse | .[] | "\(.key)|\(.value)"' "$CONFIG_FILE" 2>/dev/null || true)

  while IFS='|' read -r alias entity; do
    [[ -n $alias ]] || continue
    [[ $key == *"$alias"* ]] && { printf '%s' "$entity"; return 0; }
  done <<<"$aliases"

  while IFS='|' read -r alias entity; do
    [[ -n $alias ]] || continue
    ok=1
    for w in $alias; do
      [[ " $key " == *" $w "* ]] || { ok=0; break; }
    done
    (( ok )) && { printf '%s' "$entity"; return 0; }
  done <<<"$aliases"

  return 0
}

# Normalize free text for matching: lowercase, letters/numbers/spaces only,
# with runs of whitespace collapsed and leading/trailing space trimmed.
normalize_text() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:] ' | tr -s ' ' | sed 's/^ //; s/ $//'
}

# Apply a jq filter to a JSON file, creating it from {} if absent. Usage:
#   json_write <file> [jq options...] <filter>
# The filter is the last argument; everything before it (--arg/--argjson) is
# passed to jq.
json_write() {
  local file="$1" filter tmp
  shift
  filter="${@: -1}"
  local -a jqargs=("${@:1:$#-1}")
  mkdir -p "$(dirname "$file")"
  tmp=$(mktemp)
  if [[ -f $file ]]; then
    jq -e "${jqargs[@]}" "$filter" "$file" > "$tmp"
  else
    echo '{}' | jq -e "${jqargs[@]}" "$filter" > "$tmp"
  fi
  mv "$tmp" "$file"
}

# Apply a jq filter to config.json, creating it if absent. Used by the
# `commands` and `routines` CLIs to edit user config safely.
config_write() { json_write "$CONFIG_FILE" "$@"; }

# Derive a unique, stable map key for a new command/routine: a slug of the
# display name (or a fallback string), deduped against the section's existing
# keys so two entries with the same name never collide.
slug_id() {
  local base="$1" section="$2" slug candidate n=1
  slug=$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g; s/-\{2,\}/-/g; s/^-//; s/-$//')
  [[ -n $slug ]] || slug="entry"
  candidate="$slug"
  while jq -e --arg section "$section" --arg k "$candidate" '.[$section][$k] != null' "$CONFIG_FILE" >/dev/null 2>&1; do
    n=$((n + 1))
    candidate="${slug}-${n}"
  done
  printf '%s' "$candidate"
}

# Find the id of the existing entry whose $field equals $value, or derive a new
# unique id from $name (falling back to $value). Shared by `commands` and
# `routines` so a set/run on an existing trigger updates instead of duplicating.
resolve_entry_id() {
  local section="$1" field="$2" value="$3" name="$4" id
  id=$(jq -r --arg s "$section" --arg f "$field" --arg v "$value" '.[$s] // {} | to_entries[] | select(.value[$f] == $v) | .key' "$CONFIG_FILE" 2>/dev/null | head -1 || true)
  [[ -n $id ]] || id=$(slug_id "${name:-$value}" "$section")
  printf '%s' "$id"
}

# Print one config section as JSON, or write it to a file when given one.
config_export() {
  local section="$1" file="${2:-}"
  if [[ -n $file ]]; then
    jq --arg section "$section" '.[$section] // {}' "$CONFIG_FILE" > "$file" 2>/dev/null || echo '{}' > "$file"
    echo "Exported $section to $file"
  else
    jq --arg section "$section" '.[$section] // {}' "$CONFIG_FILE" 2>/dev/null || echo '{}'
  fi
}

# Merge one config section from a JSON object file (same-key entries overwritten).
config_import() {
  local section="$1" file="$2"
  [[ -n $file && -f $file ]] || { echo "Usage: import <file>" >&2; exit 2; }
  jq -e 'type == "object"' "$file" >/dev/null 2>&1 || { echo "import: $file is not a JSON object" >&2; exit 1; }
  config_write --arg section "$section" --slurpfile in "$file" \
    '.[$section] = ((.[$section] // {}) + ($in[0] // {}))'
  echo "Imported $section from $file"
}

STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/$PLUGIN_ID"
ERROR_FILE="$STATE_DIR/errors.json"

# Record or clear an error for a command (kind "commands") or routine (kind
# "routines"), keyed by phrase/schedule. The GUI reads these to show alerts.
set_error() {
  local kind="$1" key="$2" message="$3" at
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  json_write "$ERROR_FILE" --arg kind "$kind" --arg key "$key" --arg msg "$message" --arg at "$at" \
    '.[$kind] = ((.[$kind] // {}) + {($key): {error: $msg, at: $at}})'
}

clear_error() {
  local kind="$1" key="$2"
  [[ -f $ERROR_FILE ]] || return 0
  json_write "$ERROR_FILE" --arg kind "$kind" --arg key "$key" 'del(.[$kind][$key])'
}

# Print the recorded error for a key, or nothing.
get_error() {
  local kind="$1" key="$2"
  [[ -f $ERROR_FILE ]] || return 0
  jq -r --arg kind "$kind" --arg key "$key" '.[$kind][$key].error // empty' "$ERROR_FILE" 2>/dev/null || true
}

LOG_FILE="$STATE_DIR/log.json"

# Append an entry to the activity log (capped to the last 200 entries).
log_action() {
  local action="$1" detail="${2:-}" at
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  json_write "$LOG_FILE" --arg at "$at" --arg action "$action" --arg detail "$detail" \
    'if type == "array" then . else [] end | . + [{at: $at, action: $action, detail: $detail}] | .[-200:]'
}

ensure_runtime_dir() {
  mkdir -p "$RUNTIME_DIR"
}
