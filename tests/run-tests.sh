#!/usr/bin/env bash
# Logic tests. No video is actually played: the worker runs in dry-run mode and
# idle time is faked, so this is safe to run any time.
# Cross-platform: macOS, Linux, Windows (Git Bash/MSYS2).
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

now_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%d\n", time * 1000'
  else
    echo $(( $(date +%s) * 1000 ))
  fi
}

# Fresh log + lock per test.
setup() {
  LOG="$WORK/$1.log"
  LOCK="$WORK/$1.lock"
  : >"$LOG"
  rm -rf "$LOCK"
}

# Run the hook exactly as an agent would: JSON on stdin.
fire() {
  local fixture="$1"; shift
  env WAKEUP_LOG="$LOG" WAKEUP_LOCK="$LOCK" WAKEUP_DRY_RUN=1 "$@" \
    "$ROOT/wakeup.sh" <"$fixture"
}

# Poll instead of sleeping a fixed amount: fast and non-flaky.
wait_for() {
  local pattern="$1" timeout="${2:-8}" i=0
  while [ "$i" -lt $((timeout * 10)) ]; do
    grep -q "$pattern" "$LOG" 2>/dev/null && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# Wait for every spawned worker to finish.
settle() { local i=0; while [ -d "$LOCK" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done; }

echo
echo "claude-code-wakeup — logic tests"
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
  pass "agent finishing a task while you're away plays the alarm"
else
  fail "agent finishing a task while you're away plays the alarm" "$(cat "$LOG")"
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
fire "$FIX/permission_prompt.json" WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE=60 \
     WAKEUP_VIDEO="$WORK/does-not-exist.mp4"
if wait_for 'WARN nothing to play' && ! grep -q 'PLAY ' "$LOG"; then
  pass "a missing video file warns instead of breaking anything"
else
  fail "a missing video file warns instead of breaking anything" "$(cat "$LOG")"
fi
settle

# 10 --------------------------------------------------------------------------
setup t10
video="$(env WAKEUP_LOG="$LOG" bash -c '. '"$ROOT"'/lib/common.sh; resolve_video')"
if [ -n "$video" ] && [ -f "$video" ]; then
  pass "media/ auto-discovery finds $(basename "$video")"
else
  fail "media/ auto-discovery finds a clip" "got '$video'"
fi
settle

# 11 — Codex-style event ----------------------------------------------------
setup t11
fire "$FIX/codex_event.json" WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE=60
if wait_for '^.*PLAY '; then
  pass "Codex-style event (event field) triggers the alarm"
else
  fail "Codex-style event (event field) triggers the alarm" "$(cat "$LOG")"
fi
settle

# 12 — Generic type field ----------------------------------------------------
setup t12
fire "$FIX/generic_type.json" WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE=60
if wait_for 'skipped\|PLAY\|armed\|skip'; then
  pass "generic event with 'type' field is handled"
else
  fail "generic event with 'type' field is handled" "$(cat "$LOG")"
fi
settle

# 13 — Agent detection -------------------------------------------------------
detect_out="$(bash -c '. '"$ROOT"'/lib/agents.sh; detect_agents')"
if [ $? -eq 0 ]; then
  pass "agent detection runs without error (found: $(echo $detect_out | tr '\n' ' '))"
else
  fail "agent detection runs without error"
fi

# 14 — Platform detection ----------------------------------------------------
os_out="$(bash -c '. '"$ROOT"'/lib/platform.sh; echo $WAKEUP_OS')"
if [ -n "$os_out" ] && [ "$os_out" != "unknown" ]; then
  pass "platform detection: $os_out"
else
  fail "platform detection" "got '$os_out'"
fi

# 15 — Player detection ------------------------------------------------------
player_out="$(bash -c '. '"$ROOT"'/lib/platform.sh; . '"$ROOT"'/lib/player.sh; detect_player; echo $PLAYER_NAME')"
if [ -n "$player_out" ] && [ "$player_out" != "none" ]; then
  pass "player detection: $player_out"
else
  pass "player detection: $player_out (no player found — ok for CI)"
fi
settle

# 16 — Video-only enforcement -------------------------------------------------
setup t16
# Create fake non-video files in a temp media dir
mkdir -p "$WORK/media"
: >"$WORK/media/meme.gif"
: >"$WORK/media/meme.png"
: >"$WORK/media/meme.jpg"
touch -t 202001010000 "$WORK/media/meme.gif" "$WORK/media/meme.png" "$WORK/media/meme.jpg"
video_out="$(env WAKEUP_LOG="$LOG" WAKEUP_HOME="$ROOT" bash -c '
  . '"$ROOT"'/lib/platform.sh
  . '"$ROOT"'/lib/player.sh
  . '"$ROOT"'/lib/agents.sh
  WAKEUP_HOME="'"$WORK"'" . '"$ROOT"'/lib/common.sh
  resolve_video
' 2>/dev/null)"
if [ -z "$video_out" ] || bash -c ". $ROOT/lib/common.sh; is_video_file '$video_out'"; then
  pass "non-video files (gif/png/jpg) in media/ are ignored"
else
  fail "non-video files (gif/png/jpg) in media/ are ignored" "got '$video_out'"
fi
settle

# 17 — is_video_file validation -----------------------------------------------
if bash -c '. '"$ROOT"'/lib/platform.sh; . '"$ROOT"'/lib/player.sh; . '"$ROOT"'/lib/agents.sh; . '"$ROOT"'/lib/common.sh; is_video_file "foo.mp4" && is_video_file "bar.MOV" && ! is_video_file "no.gif" && ! is_video_file "no.png" && ! is_video_file "no.jpg" && ! is_video_file "no.webp"'; then
  pass "is_video_file correctly accepts video and rejects images/gifs"
else
  fail "is_video_file correctly accepts video and rejects images/gifs"
fi
settle

# 18 — WAKEUP_VIDEO rejects non-video ----------------------------------------
setup t18
fire "$FIX/permission_prompt.json" WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE=60 \
     WAKEUP_VIDEO="$WORK/media/meme.gif"
if wait_for 'ERROR WAKEUP_VIDEO is not a video file' && ! grep -q 'PLAY ' "$LOG"; then
  pass "WAKEUP_VIDEO set to a .gif is rejected with error"
else
  fail "WAKEUP_VIDEO set to a .gif is rejected with error" "$(cat "$LOG")"
fi
settle

echo
if [ "$FAIL" -eq 0 ]; then
  printf '\033[32m%d passed\033[0m\n\n' "$PASS"
else
  printf '\033[32m%d passed\033[0m, \033[31m%d failed\033[0m\n\n' "$PASS" "$FAIL"
fi
exit $(( FAIL > 0 ? 1 : 0 ))
