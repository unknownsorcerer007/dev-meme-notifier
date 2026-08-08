#!/usr/bin/env bash
# Live test — this one really plays the video, with sound, fullscreen.
#
#   ./tests/live-test.sh          # fakes "you're away", plays, then fakes you coming back
#   ./tests/live-test.sh --real   # no faking: take your hands off the keyboard and wait

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
WORK="$(mktemp -d)"
LOG="$WORK/live.log"
LOCK="$WORK/live.lock"
trap 'rm -rf "$WORK"' EXIT

if [ "${1:-}" = "--real" ]; then
  echo
  echo "Real end-to-end test."
  echo "Take your hands off the keyboard and mouse now — pretend you're on your phone."
  echo "The alarm should fire in about 10 seconds, and stop the moment you touch anything."
  echo
  for i in 5 4 3 2 1; do printf '\r  starting in %s ' "$i"; sleep 1; done
  printf '\r                        \n'
  env WAKEUP_LOG="$LOG" WAKEUP_LOCK="$LOCK" "$ROOT/wakeup.sh" \
    <"$HERE/fixtures/permission_prompt.json"
  echo "hook returned. waiting..."
  sleep 25
  echo
  cat "$LOG"
  exit 0
fi

IDLE="$WORK/idle"
echo 60 >"$IDLE"

echo
echo "1/2  playing the alarm (pretending you've been away 60s)"
env WAKEUP_LOG="$LOG" WAKEUP_LOCK="$LOCK" \
    WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE_FILE="$IDLE" \
    "$ROOT/wakeup.sh" <"$HERE/fixtures/permission_prompt.json"

# Give it the grace period plus a moment to launch the player.
sleep 4

if pgrep -x ffplay >/dev/null 2>&1 || \
   osascript -e 'tell application "System Events" to (name of processes) contains "QuickTime Player"' 2>/dev/null | grep -q true; then
  echo "     ✓ video is playing"
else
  echo "     ✗ nothing is playing"
  cat "$LOG"
  exit 1
fi

echo "2/2  simulating you coming back to the desk..."
echo 0 >"$IDLE"

for i in $(seq 1 60); do
  pgrep -x ffplay >/dev/null 2>&1 || break
  sleep 0.25
done

if pgrep -x ffplay >/dev/null 2>&1; then
  echo "     ✗ player is still running — it should have stopped"
  pkill -x ffplay
  cat "$LOG"
  exit 1
fi

echo "     ✓ alarm cut out when you came back"
echo
cat "$LOG"
