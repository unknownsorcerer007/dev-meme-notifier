#!/usr/bin/env bash
# Live test — this one really plays the video, with sound, fullscreen.
# Cross-platform: macOS, Linux, Windows (Git Bash/MSYS2).
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

# Source platform/player for cross-platform player check
. "$ROOT/lib/platform.sh"
. "$ROOT/lib/player.sh"
detect_player

check_player_running() {
  case "$PLAYER_NAME" in
    ffplay)
      if [ "$WAKEUP_OS" = "windows" ]; then
        tasklist.exe 2>/dev/null | grep -qi ffplay
      else
        pgrep -x ffplay >/dev/null 2>&1
      fi
      ;;
    mpv)
      if [ "$WAKEUP_OS" = "windows" ]; then
        tasklist.exe 2>/dev/null | grep -qi mpv
      else
        pgrep -x mpv >/dev/null 2>&1
      fi
      ;;
    vlc)
      if [ "$WAKEUP_OS" = "windows" ]; then
        tasklist.exe 2>/dev/null | grep -qi vlc
      else
        pgrep -x vlc >/dev/null 2>&1
      fi
      ;;
    quicktime)
      osascript -e 'tell application "System Events" to (name of processes) contains "QuickTime Player"' 2>/dev/null | grep -q true
      ;;
    wmplayer)
      tasklist.exe 2>/dev/null | grep -qi wmplayer
      ;;
    *)
      # Generic: check if any player process is running
      false
      ;;
  esac
}

kill_player() {
  case "$PLAYER_NAME" in
    ffplay)   pkill -x ffplay 2>/dev/null || true ;;
    mpv)      pkill -x mpv 2>/dev/null || true ;;
    vlc)      pkill -x vlc 2>/dev/null || true ;;
    quicktime) _qt_stop ;;
    wmplayer) taskkill.exe /F /IM wmplayer.exe >/dev/null 2>&1 || true ;;
  esac
}

if [ "${1:-}" = "--real" ]; then
  echo
  echo "Real end-to-end test."
  echo "Platform: $WAKEUP_OS | Player: $PLAYER_NAME"
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
echo "Platform: $WAKEUP_OS | Player: $PLAYER_NAME"
echo
echo "1/2  playing the alarm (pretending you've been away 60s)"
env WAKEUP_LOG="$LOG" WAKEUP_LOCK="$LOCK" \
    WAKEUP_DELAY_SECS=1 WAKEUP_IDLE_OVERRIDE_FILE="$IDLE" \
    "$ROOT/wakeup.sh" <"$HERE/fixtures/permission_prompt.json"

# Give it the grace period plus a moment to launch the player.
sleep 4

if check_player_running; then
  echo "     ✓ video is playing"
else
  echo "     ✗ nothing is playing"
  cat "$LOG"
  exit 1
fi

echo "2/2  simulating you coming back to the desk..."
echo 0 >"$IDLE"

for i in $(seq 1 60); do
  check_player_running || break
  sleep 0.25
done

if check_player_running; then
  echo "     ✗ player is still running — it should have stopped"
  kill_player
  cat "$LOG"
  exit 1
fi

echo "     ✓ alarm cut out when you came back"
echo
cat "$LOG"
