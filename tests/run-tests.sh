#!/usr/bin/env bash
# Logic tests. No video is actually played: the worker runs in dry-run mode and
# idle time is faked, so this is safe to run any time.
#
#   ./tests/run-tests.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FIX="$HERE/fixtures"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31m✗\033[0m %s\n     %s\n' "$1" "${2:-}"; FAIL=$((FAIL + 1)); }

now_ms() { perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'; }

# Fresh log + lock per test, so cases can't contaminate each other.
setup() {
  LOG="$WORK/$1.log"
  LOCK="$WORK/$1.lock"
  : >"$LOG"
  rm -rf "$LOCK"
}

# Run the hook exactly as an agent would: JSON on stdin.
# Uses real media/ folder by default (via WAKEUP_HOME).
fire() {
  local fixture="$1"; shift
  env WAKEUP_LOG="$LOG" WAKEUP_LOCK="$LOCK" WAKEUP_DRY_RUN=1 "$@" \
    "$ROOT/wakeup.sh" <"$fixture"
}

# Poll instead of sleeping a fixed amount: keeps the suite fast and non-flaky.
wait_for() {
  local pattern="$1" timeout="${2:-8}" i=0
  while [ "$i" -lt $((timeout * 10)) ]; do
    grep -q "$pattern" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Wait for every spawned worker to finish so the next test starts clean.
settle() { local i=0; while [ -d "$LOCK" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; }

echo
echo "dev-meme-notifier — logic tests"
echo

# 1 --------------------------------------------------------------------------
setup t1
fire "$FIX/permission_prompt.json" WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE=60
if wait_for '^.*PLAY '; then
  pass "permission prompt while you're away (idle 60s) plays the alarm"
else
  fail "permission prompt while you're away (idle 60s) plays the alarm" "$(cat "$LOG")"
fi
settle

# 2 --------------------------------------------------------------------------
setup t2
fire "$FIX/permission_prompt.json" WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE=2
if wait_for "skipped: you're here" && ! grep -q 'PLAY ' "$LOG"; then
  pass "permission prompt while you're at the desk (idle 2s) stays silent"
else
  fail "permission prompt while you're at the desk (idle 2s) stays silent" "$(cat "$LOG")"
fi
settle

# 3 --------------------------------------------------------------------------
setup t3
fire "$FIX/stop.json" WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE=60
if wait_for 'PLAY .*trigger=stop'; then
  pass "Claude finishing a task while you're away plays the alarm"
else
  fail "Claude finishing a task while you're away plays the alarm" "$(cat "$LOG")"
fi
settle

# 4 --------------------------------------------------------------------------
setup t4
fire "$FIX/auth_success.json" WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE=60
sleep 2
if [ ! -s "$LOG" ]; then
  pass "an event you didn't subscribe to (auth_success) is ignored"
else
  fail "an event you didn't subscribe to (auth_success) is ignored" "$(cat "$LOG")"
fi
settle

# 5 --------------------------------------------------------------------------
setup t5
fire "$FIX/permission_prompt.json" WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE=60
fire "$FIX/stop.json"              WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE=60
wait_for 'PLAY ' >/dev/null
sleep 2
count="$(grep -c 'PLAY ' "$LOG")"
if [ "$count" -eq 1 ]; then
  pass "two events firing at once produce exactly one alarm"
else
  fail "two events firing at once produce exactly one alarm" "got $count PLAY lines"
fi
settle

# 6 --------------------------------------------------------------------------
setup t6
start="$(now_ms)"
fire "$FIX/permission_prompt.json" WAKEUP_DELAY_SECS=30 WAKEUP_IDLE_OVERRIDE=60
elapsed=$(( $(now_ms) - start ))
if [ "$elapsed" -lt 500 ]; then
  pass "the hook never blocks the agent (returned in ${elapsed}ms)"
else
  fail "the hook never blocks the agent" "took ${elapsed}ms"
fi
# Kill the 30s worker rather than waiting it out.
[ -f "$LOCK/pid" ] && kill "$(cat "$LOCK/pid")" 2>/dev/null
rm -rf "$LOCK"

# 7 --------------------------------------------------------------------------
setup t7
fire "$FIX/permission_prompt.json" WAKEUP_DELAY_SECS=2 WAKEUP_IDLE_OVERRIDE=60
if grep -q 'PLAY ' "$LOG"; then
  fail "the worker outlives the hook process" "played before the hook returned"
elif wait_for 'PLAY ' 6; then
  pass "the worker outlives the hook process and plays after the grace period"
else
  fail "the worker outlives the hook process" "$(cat "$LOG")"
fi
settle

# 8 --------------------------------------------------------------------------
setup t8
out="$(fire "$FIX/malformed.json" 2>&1)"; rc_bad=$?
out2="$(fire "$FIX/empty.json" 2>&1)"; rc_empty=$?
if [ "$rc_bad" -eq 0 ] && [ "$rc_empty" -eq 0 ] && [ -z "$out$out2" ]; then
  pass "malformed and empty hook input exit 0 silently"
else
  fail "malformed and empty hook input exit 0 silently" "rc=$rc_bad/$rc_empty out='$out$out2'"
fi
settle

# 9 --------------------------------------------------------------------------
setup t9
EMPTY_MEDIA="$WORK/t9-empty-media"
mkdir -p "$EMPTY_MEDIA"
fire "$FIX/permission_prompt.json" WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE=60 \
     WAKEUP_VIDEO="$WORK/does-not-exist.mp4" WAKEUP_MEME_DIR="$EMPTY_MEDIA"
if wait_for 'WARN nothing to play' && ! grep -q 'PLAY ' "$LOG"; then
  pass "a missing video file warns instead of breaking anything"
else
  fail "a missing video file warns instead of breaking anything" "$(cat "$LOG")"
fi
settle

# 10 — media auto-discovery (uses real media/) --------------------------------
setup t10
video="$(env WAKEUP_LOG="$LOG" bash -c ". $ROOT/lib/common.sh; resolve_video")"
if [ -n "$video" ] && [ -f "$video" ]; then
  pass "media/ auto-discovery finds $(basename "$video")"
else
  fail "media/ auto-discovery finds a clip" "got '$video'"
fi

# 11 — cross-format media discovery (.mp4, .mov, .webm, .gif) ----------------
setup t11
MEDIA_DIR="$WORK/t11-media"
mkdir -p "$MEDIA_DIR"
touch "$MEDIA_DIR/test.mp4" "$MEDIA_DIR/test.mov" "$MEDIA_DIR/test.webm" "$MEDIA_DIR/test.gif"
video="$(env WAKEUP_LOG="$LOG" WAKEUP_MEME_DIR="$MEDIA_DIR" bash -c ". $ROOT/lib/common.sh; resolve_video")"
if [ -n "$video" ] && [ -f "$video" ]; then
  pass "cross-format media discovery (.mp4/.mov/.webm/.gif)"
else
  fail "cross-format media discovery" "got '$video'"
fi

# 12 — player auto-detection -------------------------------------------------
setup t12
player="$(env WAKEUP_LOG="$LOG" bash -c ". $ROOT/lib/common.sh; detect_player; echo \$WAKEUP_PLAYER")"
if [ -n "$player" ] && [ "$player" != "" ]; then
  pass "player auto-detection found: $player"
else
  fail "player auto-detection found a player" "got '$player'"
fi

# 13 — meme API fallback (no local media, API set) ---------------------------
setup t13
MOCK_MEDIA="$WORK/t13-mock-media"
mkdir -p "$MOCK_MEDIA"
MOCK_SCRIPT="$WORK/mock-meme-fetch.sh"
cat > "$MOCK_SCRIPT" << 'MOCKEOF'
#!/bin/bash
MOCK_DIR="${WAKEUP_MEME_DIR:-/tmp}"
MOCK_FILE="$MOCK_DIR/meme-mock.gif"
echo "dummy" > "$MOCK_FILE"
echo "$MOCK_FILE"
MOCKEOF
chmod +x "$MOCK_SCRIPT"

# Write a test helper script to avoid nested quoting hell
HELPER="$WORK/test-meme-helper.sh"
cat > "$HELPER" << HELPEREOF
#!/bin/bash
. "$ROOT/lib/common.sh"
WAKEUP_MEME_DIR="$MOCK_MEDIA"
WAKEUP_MEME_API="reddit"
resolve_video() {
  local -a clips=()
  local f
  for f in "$MOCK_MEDIA"/*.mp4 "$MOCK_MEDIA"/*.mov "$MOCK_MEDIA"/*.webm "$MOCK_MEDIA"/*.gif; do
    [ -f "\$f" ] && clips+=("\$f")
  done
  if [ \${#clips[@]} -gt 0 ]; then
    printf "%s\n" "\${clips[RANDOM % \${#clips[@]}]}"
    return 0
  fi
  if [ -n "\$WAKEUP_MEME_API" ]; then
    local fetched
    fetched="\$("$MOCK_SCRIPT")"
    if [ -n "\$fetched" ] && [ -f "\$fetched" ]; then
      printf "%s\n" "\$fetched"
      return 0
    fi
  fi
  return 1
}
resolve_video
HELPEREOF
chmod +x "$HELPER"

video="$(env WAKEUP_LOG="$LOG" WAKEUP_MEME_DIR="$MOCK_MEDIA" WAKEUP_MEME_API="reddit" \
  WAKEUP_HOME="$ROOT" bash "$HELPER")"
if [ -n "$video" ] && [ -f "$video" ]; then
  pass "meme API fallback fetches when media/ is empty"
else
  fail "meme API fallback fetches when media/ is empty" "got '$video'"
fi

# 14 — config.env loads new settings -----------------------------------------
setup t14
config_check="$(env WAKEUP_LOG="$LOG" bash -c ". $ROOT/lib/common.sh; echo PLAYER=\$WAKEUP_PLAYER; echo MEME_API=\$WAKEUP_MEME_API; echo MEME_DIR=\$WAKEUP_MEME_DIR")"
if echo "$config_check" | grep -q "PLAYER="; then
  pass "config.env loads new cross-platform settings"
else
  fail "config.env loads new cross-platform settings" "$config_check"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%d passed\033[0m\n\n' "$PASS"
else
  printf '\033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n\n' "$PASS" "$FAIL"
fi
exit $(( FAIL > 0 ? 1 : 0 ))
