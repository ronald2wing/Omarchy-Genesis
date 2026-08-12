#!/bin/bash

# Regression tests for command/routine export and import.

set -uo pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
COMMANDS="$PLUGIN_DIR/bin/commands"
ROUTINE="$PLUGIN_DIR/bin/routines"

pass=0
fail=0

tmp=$(mktemp -d)
export GENESIS_CONFIG="$tmp/config.json"
export XDG_CONFIG_HOME="$tmp/xdg"
export XDG_STATE_HOME="$tmp/state"

# mock systemctl so `routine import`'s install step is a no-op (and capture
# its args so we can assert the install targets the .timer unit, not the bare
# name — a bare name resolves to the .service and would run the routine now)
mkdir -p "$tmp/bin"
cat > "$tmp/bin/systemctl" <<'EOF'
#!/bin/bash
printf "%s " "$@" >> "$SCTL_LOG"
printf "\n" >> "$SCTL_LOG"
EOF
chmod +x "$tmp/bin/systemctl"
export PATH="$tmp/bin:$PATH" SCTL_LOG="$tmp/sctl.log"

check() {
  local label="$1" want="$2" got="$3"
  if [[ $got == "$want" ]]; then
    (( pass += 1 ))
  else
    (( fail += 1 ))
    printf 'FAIL: %-24s expected=[%s] got=[%s]\n' "$label" "$want" "$got"
  fi
}

printf '%s' '{"commands":{"keep":{"run":"echo keep"}},"routines":{}}' > "$tmp/config.json"

got=$("$COMMANDS" export | jq -c .)
check "commands export" '{"keep":{"run":"echo keep"}}' "$got"

printf '%s' '{"new":{"run":"echo new"}}' > "$tmp/import.json"
"$COMMANDS" import "$tmp/import.json" >/dev/null
got=$(jq -c '.commands' "$tmp/config.json")
check "commands import" '{"keep":{"run":"echo keep"},"new":{"run":"echo new"}}' "$got"

printf '%s' 'not json' > "$tmp/bad.json"
if "$COMMANDS" import "$tmp/bad.json" >/dev/null 2>&1; then
  (( fail += 1 )); echo 'FAIL: bad import should fail'
else
  (( pass += 1 ))
fi

printf '%s' '{"commands":{},"routines":{"08:00":{"run":"notify hi"}}}' > "$tmp/config.json"

got=$("$ROUTINE" export | jq -c .)
check "routine export" '{"08:00":{"run":"notify hi"}}' "$got"

printf '%s' '{"09:00":{"run":"new"}}' > "$tmp/import.json"
"$ROUTINE" import "$tmp/import.json" >/dev/null 2>&1
got=$(jq -c '.routines' "$tmp/config.json")
check "routine import" '{"08:00":{"run":"notify hi"},"09:00":{"run":"new"}}' "$got"

# --dry-run previews the import without writing config or installing timers
before=$(jq -c . "$tmp/config.json")
: > "$tmp/sctl.log"
out=$("$PLUGIN_DIR/bin/config-import" --dry-run '{"commands":{"pc":{"phrase":"preview cmd","run":"echo x"}},"routines":{"pr":{"schedule":"08:00","run":"preview routine"}}}')
check "config-import dry-run no write" "$before" "$(jq -c . "$tmp/config.json")"
check "config-import dry-run preview" "1" "$(printf '%s' "$out" | grep -c 'preview routine' || true)"

printf '%s' '{"routines":{"pr":{"schedule":"09:00","run":"preview timer"}}}' > "$tmp/import.json"
out=$("$ROUTINE" import --dry-run "$tmp/import.json")
check "routine import dry-run no write" "$before" "$(jq -c . "$tmp/config.json")"
check "routine import dry-run preview" "1" "$(printf '%s' "$out" | grep -c 'preview timer' || true)"
check "routine import dry-run no install" "0" "$(grep -c 'enable --now' "$tmp/sctl.log" || true)"

# a bash routine with shell operators is grouped so `!` negates the whole command
printf '%s' '{"routines":{"ten":{"schedule":"10:00","run":"echo a && echo b"}}}' > "$tmp/config.json"
"$ROUTINE" install >/dev/null 2>&1
sh_file=$(ls "$tmp/xdg/systemd/user"/genesis-routine-*.sh 2>/dev/null | head -1)
got=$(grep -cF '( echo a && echo b )' "$sh_file" 2>/dev/null || true)
check "routine && grouping" "1" "$got"

# `install` must `enable --now <name>.timer` (with the .timer suffix) — a bare
# name resolves to the .service and would run the routine immediately on install
if grep -qE 'enable --now [^ ]+\.timer( |$)' "$tmp/sctl.log"; then
  (( pass += 1 ))
else
  (( fail += 1 )); printf 'FAIL: %-24s expected enable --now <unit>.timer\n' "timer suffix"
  sed 's/^/       /' "$tmp/sctl.log"
fi

# --name stores a display label without changing the trigger/schedule
"$COMMANDS" set --name "My command" "titled" notifications toggleDnd >/dev/null
got=$(jq -c '.commands | to_entries[] | select(.value.phrase == "titled") | .value.name' "$tmp/config.json")
check "commands set --name" '"My command"' "$got"
"$ROUTINE" set --name "My routine" "22:00" "echo hi" >/dev/null 2>&1
got=$(jq -c '.routines | to_entries[] | select(.value.schedule == "22:00") | .value.name' "$tmp/config.json")
check "routine set --name" '"My routine"' "$got"

# a name that duplicates the phrase (or schedule) is dropped
"$COMMANDS" set --name "dup phrase" "dup phrase" notifications toggleDnd >/dev/null
got=$(jq -c '.commands | to_entries[] | select(.value.phrase == "dup phrase") | .value.name // "none"' "$tmp/config.json")
check "commands drop phrase-name" '"none"' "$got"
"$ROUTINE" set --name "23:00" "23:00" "echo hi" >/dev/null 2>&1
got=$(jq -c '.routines | to_entries[] | select(.value.schedule == "23:00") | .value.name // "none"' "$tmp/config.json")
check "routine drop schedule-name" '"none"' "$got"

echo
echo "passed: $pass  failed: $fail"
(( fail == 0 )) || exit 1
