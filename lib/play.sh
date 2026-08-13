#!/usr/bin/env bash
# Detached worker: wait out the grace period, check you're actually away, play the
# alarm, and cut it the moment you touch the keyboard.
# Cross-platform: macOS (ffplay/QuickTime/mpv), Linux (mpv/ffplay/vlc).

set -uo pipefail

# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

trigger="${1:-unknown}"
PLAYER_PID=""
PREV_VOLUME=""

# --- lock -------------------------------------------------------------------
acquire_lock() {
  if mkdir "$WAKEUP_LOCK" 2>/dev/null; then
    echo $$ >"$WAKEUP_LOCK/pid"
    return 0
  fi
  local pid
  pid="$(cat "$WAKEUP_LOCK/pid" 2>/dev/null)"
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    return 1
  fi
  rm -rf "$WAKEUP_LOCK" 2>/dev/null
  mkdir "$WAKEUP_LOCK" 2>/dev/null || return 1
  echo $$ >"$WAKEUP_LOCK/pid"
}

# --- volume (cross-platform) -------------------------------------------------
set_volume() {
  [ -n "$WAKEUP_VOLUME" ] || return 0
  case "$OS" in
    Darwin)
      PREV_VOLUME="$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)"
      osascript -e "set volume output volume $WAKEUP_VOLUME" \
                -e 'set volume without output muted' >/dev/null 2>&1
      ;;
    Linux)
      # Save current volume, try pactl (PulseAudio/PipeWire) then amixer (ALSA)
      if command -v pactl >/dev/null 2>&1; then
        PREV_VOLUME="$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -o '[0-9]\+%' | head -1 | tr -d '%')"
        pactl set-sink-volume @DEFAULT_SINK@ "${WAKEUP_VOLUME}%" >/dev/null 2>&1
        pactl set-sink-mute @DEFAULT_SINK@ 0 >/dev/null 2>&1
      elif command -v amixer >/dev/null 2>&1; then
        PREV_VOLUME="$(amixer get Master 2>/dev/null | grep -o '[0-9]\+%' | head -1 | tr -d '%')"
        amixer set Master "${WAKEUP_VOLUME}%" unmute >/dev/null 2>&1
      fi
      ;;
  esac
}

restore_volume() {
  [ -n "$PREV_VOLUME" ] || return 0
  case "$OS" in
    Darwin)
      osascript -e "set volume output volume $PREV_VOLUME" >/dev/null 2>&1
      ;;
    Linux)
      if command -v pactl >/dev/null 2>&1; then
        pactl set-sink-volume @DEFAULT_SINK@ "${PREV_VOLUME}%" >/dev/null 2>&1
      elif command -v amixer >/dev/null 2>&1; then
        amixer set Master "${PREV_VOLUME}%" >/dev/null 2>&1
      fi
      ;;
  esac
}

# --- players (cross-platform) ------------------------------------------------

# macOS QuickTime
qt_start() {
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

qt_running() {
  local r
  r="$(osascript -e 'tell application "QuickTime Player" to if (count documents) > 0 then return (playing of front document) else return false' 2>/dev/null)"
  [ "$r" = "true" ]
}

qt_stop() {
  osascript -e 'tell application "QuickTime Player" to if (count documents) > 0 then close front document saving no' \
            -e 'tell application "QuickTime Player" to quit' >/dev/null 2>&1
}

# mpv (cross-platform, preferred)
mpv_start() {
  mpv --fs --no-terminal --no-config "$1" >/dev/null 2>&1 &
  PLAYER_PID=$!
}

# ffplay (cross-platform)
ffplay_start() {
  ffplay -fs -autoexit -loglevel quiet "$1" >/dev/null 2>&1 &
  PLAYER_PID=$!
}

# vlc (cross-platform)
vlc_start() {
  vlc --fullscreen --play-and-exit --quiet "$1" >/dev/null 2>&1 &
  PLAYER_PID=$!
}

start_player() {
  detect_player
  if [ -z "$WAKEUP_PLAYER" ]; then
    log "ERROR: no video player available"
    return 1
  fi
  case "$WAKEUP_PLAYER" in
    quicktime) qt_start "$1" ;;
    mpv)       mpv_start "$1" ;;
    ffplay)    ffplay_start "$1" ;;
    vlc)       vlc_start "$1" ;;
    *)         log "ERROR: unknown player '$WAKEUP_PLAYER'"; return 1 ;;
  esac
}

player_running() {
  case "$WAKEUP_PLAYER" in
    quicktime) qt_running ;;
    *)
      [ -n "$PLAYER_PID" ] && kill -0 "$PLAYER_PID" 2>/dev/null
      ;;
  esac
}

stop_player() {
  case "$WAKEUP_PLAYER" in
    quicktime) qt_stop ;;
    *)
      if [ -n "$PLAYER_PID" ]; then
        kill "$PLAYER_PID" 2>/dev/null
        wait "$PLAYER_PID" 2>/dev/null
      fi
      ;;
  esac
}

cleanup() {
  stop_player
  restore_volume
  rm -rf "$WAKEUP_LOCK" 2>/dev/null
}

# --- run --------------------------------------------------------------------
acquire_lock || { log "skip $trigger (another alarm holds the lock)"; exit 0; }
trap cleanup EXIT INT TERM

log "armed by $trigger — waiting ${WAKEUP_DELAY_SECS}s"
sleep "$WAKEUP_DELAY_SECS"

idle="$(idle_secs)"
if [ "$idle" -lt "$WAKEUP_IDLE_SECS" ]; then
  log "skipped: you're here (idle ${idle}s < ${WAKEUP_IDLE_SECS}s)"
  exit 0
fi

video="$(resolve_video)"
if [ -z "$video" ] || [ ! -f "$video" ]; then
  log "WARN nothing to play (WAKEUP_VIDEO='$WAKEUP_VIDEO', no clips in media/ and no meme API)"
  exit 0
fi

if [ "${WAKEUP_DRY_RUN:-0}" = "1" ]; then
  log "PLAY $video (dry run, trigger=$trigger, idle=${idle}s)"
  exit 0
fi

set_volume
detect_player
log "PLAY $video (trigger=$trigger, idle=${idle}s, player=$WAKEUP_PLAYER)"

deadline=$(( SECONDS + WAKEUP_MAX_SECS ))
while :; do
  start_player "$video"
  while player_running; do
    if [ "$(idle_secs)" -lt "$WAKEUP_RETURN_SECS" ]; then
      log "you're back — stopping"
      exit 0
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      log "hit WAKEUP_MAX_SECS (${WAKEUP_MAX_SECS}s) — stopping"
      exit 0
    fi
    sleep 1
  done
  [ "$WAKEUP_LOOP" = "1" ] && [ "$SECONDS" -lt "$deadline" ] || break
done

log "played through"
