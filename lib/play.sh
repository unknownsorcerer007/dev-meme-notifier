#!/usr/bin/env bash
# Detached worker: wait out the grace period, check you're actually away, play the
# alarm, and cut it the moment you touch the keyboard.

set -uo pipefail

# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

trigger="${1:-unknown}"
PLAYER_PID=""
PREV_VOLUME=""

# --- lock -------------------------------------------------------------------
# mkdir is atomic, so two hooks firing at the same instant produce one alarm.
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

# --- volume -----------------------------------------------------------------
set_volume() {
  [ -n "$WAKEUP_VOLUME" ] || return 0
  PREV_VOLUME="$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)"
  osascript -e "set volume output volume $WAKEUP_VOLUME" \
            -e 'set volume without output muted' >/dev/null 2>&1
}

restore_volume() {
  [ -n "$PREV_VOLUME" ] || return 0
  osascript -e "set volume output volume $PREV_VOLUME" >/dev/null 2>&1
}

# --- players ----------------------------------------------------------------
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

start_player() {
  if [ "$WAKEUP_PLAYER" != "quicktime" ] && ! command -v ffplay >/dev/null 2>&1; then
    log "ffplay not installed — using QuickTime instead"
    WAKEUP_PLAYER="quicktime"
  fi
  if [ "$WAKEUP_PLAYER" = "quicktime" ]; then
    qt_start "$1"
  else
    ffplay -fs -autoexit -loglevel quiet "$1" >/dev/null 2>&1 &
    PLAYER_PID=$!
  fi
}

player_running() {
  if [ "$WAKEUP_PLAYER" = "quicktime" ]; then
    qt_running
  else
    [ -n "$PLAYER_PID" ] && kill -0 "$PLAYER_PID" 2>/dev/null
  fi
}

stop_player() {
  if [ "$WAKEUP_PLAYER" = "quicktime" ]; then
    qt_stop
  elif [ -n "$PLAYER_PID" ]; then
    kill "$PLAYER_PID" 2>/dev/null
    wait "$PLAYER_PID" 2>/dev/null
  fi
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
  log "WARN nothing to play (WAKEUP_VIDEO='$WAKEUP_VIDEO', no clips in media/?)"
  exit 0
fi

if [ "${WAKEUP_DRY_RUN:-0}" = "1" ]; then
  log "PLAY $video (dry run, trigger=$trigger, idle=${idle}s)"
  exit 0
fi

set_volume
log "PLAY $video (trigger=$trigger, idle=${idle}s)"

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
