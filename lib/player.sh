#!/usr/bin/env bash
# Cross-platform media player abstraction.
# Finds the best available player, starts/stops/checks playback.

PLAYER_PID=""
PLAYER_NAME=""

# Discover available player in priority order.
# Sets PLAYER_NAME. Called once at startup.
detect_player() {
  if [ -n "${WAKEUP_PLAYER:-}" ] && [ "$WAKEUP_PLAYER" != "auto" ]; then
    PLAYER_NAME="$WAKEUP_PLAYER"
    return
  fi

  case "$WAKEUP_OS" in
    macos)
      if command -v ffplay >/dev/null 2>&1; then
        PLAYER_NAME="ffplay"
      elif command -v mpv >/dev/null 2>&1; then
        PLAYER_NAME="mpv"
      else
        PLAYER_NAME="quicktime"
      fi
      ;;
    linux)
      if command -v ffplay >/dev/null 2>&1; then
        PLAYER_NAME="ffplay"
      elif command -v mpv >/dev/null 2>&1; then
        PLAYER_NAME="mpv"
      elif command -v vlc >/dev/null 2>&1; then
        PLAYER_NAME="vlc"
      elif command -v xdg-open >/dev/null 2>&1; then
        PLAYER_NAME="xdg-open"
      elif command -v totem >/dev/null 2>&1; then
        PLAYER_NAME="totem"
      else
        PLAYER_NAME="none"
      fi
      ;;
    windows)
      if command -v ffplay.exe >/dev/null 2>&1; then
        PLAYER_NAME="ffplay"
      elif command -v ffplay >/dev/null 2>&1; then
        PLAYER_NAME="ffplay"
      elif command -v mpv.exe >/dev/null 2>&1; then
        PLAYER_NAME="mpv"
      elif command -v mpv >/dev/null 2>&1; then
        PLAYER_NAME="mpv"
      else
        PLAYER_NAME="wmplayer"
      fi
      ;;
    *)
      PLAYER_NAME="ffplay"
      ;;
  esac
}

# Start playing a video file. Sets PLAYER_PID.
start_player() {
  local file="$1"
  case "$PLAYER_NAME" in
    ffplay)
      ffplay -fs -autoexit -loglevel quiet "$file" >/dev/null 2>&1 &
      PLAYER_PID=$!
      ;;
    mpv)
      mpv --fs --no-terminal --really-quiet "$file" >/dev/null 2>&1 &
      PLAYER_PID=$!
      ;;
    vlc)
      vlc --fullscreen --play-and-exit --quiet "$file" >/dev/null 2>&1 &
      PLAYER_PID=$!
      ;;
    quicktime)
      _qt_start "$file"
      ;;
    xdg-open)
      xdg-open "$file" >/dev/null 2>&1 &
      PLAYER_PID=$!
      ;;
    totem)
      totem --fullscreen "$file" >/dev/null 2>&1 &
      PLAYER_PID=$!
      ;;
    wmplayer)
      # Windows Media Player via PowerShell
      powershell.exe -NoProfile -Command "
        Start-Process wmplayer -ArgumentList '\"$file\" /fullscreen /play /close'
      " >/dev/null 2>&1 &
      PLAYER_PID=$!
      ;;
    none)
      log "ERROR no media player found — install ffplay, mpv, or vlc"
      return 1
      ;;
  esac
}

# Check if player is still running.
player_running() {
  case "$PLAYER_NAME" in
    quicktime)
      _qt_running
      ;;
    *)
      [ -n "$PLAYER_PID" ] && kill -0 "$PLAYER_PID" 2>/dev/null
      ;;
  esac
}

# Stop the player.
stop_player() {
  case "$PLAYER_NAME" in
    quicktime)
      _qt_stop
      ;;
    wmplayer)
      if [ -n "$PLAYER_PID" ]; then
        kill "$PLAYER_PID" 2>/dev/null
        wait "$PLAYER_PID" 2>/dev/null
      fi
      # Also kill wmplayer.exe if it's lingering
      taskkill.exe /F /IM wmplayer.exe >/dev/null 2>&1 || true
      ;;
    *)
      if [ -n "$PLAYER_PID" ]; then
        kill "$PLAYER_PID" 2>/dev/null
        wait "$PLAYER_PID" 2>/dev/null
      fi
      ;;
  esac
}

# --- macOS QuickTime helpers (AppleScript) ---
_qt_start() {
  osascript >/dev/null 2>&1 <<OSA
tell application "QuickTime Player"
  activate
  set d to open POSIX file "$1"
  tell d
    set looping to false
    present
    play
  end tell
end tell
OSA
}

_qt_running() {
  local r
  r="$(osascript -e 'tell application "QuickTime Player" to if (count documents) > 0 then return (playing of front document) else return false' 2>/dev/null)"
  [ "$r" = "true" ]
}

_qt_stop() {
  osascript -e 'tell application "QuickTime Player" to if (count documents) > 0 then close front document saving no' \
            -e 'tell application "QuickTime Player" to quit' >/dev/null 2>&1
}
