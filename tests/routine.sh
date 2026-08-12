#!/bin/bash

# Regression tests for bin/routines' one-off scheduling (once/at), using a
# stubbed systemd-run so no real timer is created.

set -uo pipefail

PLUGIN_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
ROUTINE="$PLUGIN_DIR/bin/routines"
export GENESIS_CONFIG="$PLUGIN_DIR/tests/fixtures/config.json"

pass=0
fail=0

tmp=$(mktemp -d)
mkdir -p "$tmp/bin" "$tmp/state"
cat > "$tmp/bin/systemd-run" <<'EOF'
#!/bin/bash
printf '%s\n' "$@" >> "$SR_LOG"
EOF
chmod +x "$tmp/bin/systemd-run"
export PATH="$tmp/bin:$PATH" SR_LOG="$tmp/log" XDG_STATE_HOME="$tmp/state"

# Run `routine ...`, then check the captured systemd-run invocation contains
# the expected fragment.
check() {
  local label="$1" want="$2"
  shift 2
  rm -f "$tmp/log"
  "$ROUTINE" "$@" >/dev/null 2>&1
  if grep -qF -- "$want" "$tmp/log"; then
    (( pass += 1 ))
  else
    (( fail += 1 ))
    printf 'FAIL: %-20s expected [%s]\n' "$label" "$want"
    sed 's/^/       /' "$tmp/log"
  fi
}

check "once delay"  "--on-active=5m"     once "5m" "echo hi"
check "once bash"   "bash"                once "5m" "echo hi"
check "once python" "python3"             once --lang python "5m" "print(1)"
check "at time"     "--on-calendar=15:00" at "15:00" "echo hi"
check "at node"     "node"                at --lang node "15:00" "console.log(1)"
check "run now"     "--on-active=1s"      run "08:00"

# an unknown language is rejected without scheduling
rm -f "$tmp/log"
if "$ROUTINE" once --lang lua "5m" "x" >/dev/null 2>&1; then
  (( fail += 1 )); printf 'FAIL: %-20s expected non-zero exit\n' "unknown language"
else
  (( pass += 1 ))
fi

echo
echo "passed: $pass  failed: $fail"
(( fail == 0 )) || exit 1
