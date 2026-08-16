#!/usr/bin/env bash
# Detached worker: wait out the grace period, check you're actually away, play the
# alarm, and cut it the moment you touch the keyboard.
# Cross-platform: macOS, Linux, Windows (Git Bash/MSYS2/WSL).

set -uo pipefail

# shellcheck source=common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

trigger="${1:-unknown}"
PREV_VOLUME=""

# --- lock -------------------------------------------------------------------
# mkdir is atomic — two hooks firing at the same instant produce one alarm.
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
  case "$WAKEUP_OS" in
    macos)
      PREV_VOLUME="$(osascript -e 'output volume of (get volume settings)' 2>/dev/null)"
      osascript -e "set volume output volume $WAKEUP_VOLUME" \
                -e 'set volume without output muted' >/dev/null 2>&1
      ;;
    linux)
      if command -v amixer >/dev/null 2>&1; then
        PREV_VOLUME="$(amixer get Master 2>/dev/null | grep -oP '\[\d+%\]' | head -1 | tr -d '[]%')"
        amixer set Master "${WAKEUP_VOLUME}%" unmute >/dev/null 2>&1
      elif command -v pactl >/dev/null 2>&1; then
        PREV_VOLUME="$(pactl get-sink-volume @DEFAULT_SINK@ 2>/dev/null | grep -oP '\d+%' | head -1 | tr -d '%')"
        pactl set-sink-volume @DEFAULT_SINK@ "${WAKEUP_VOLUME}%" >/dev/null 2>&1
        pactl set-sink-mute @DEFAULT_SINK@ 0 >/dev/null 2>&1
      fi
      ;;
    windows)
      if command -v powershell.exe >/dev/null 2>&1; then
        PREV_VOLUME="$(powershell.exe -NoProfile -Command '(Get-AudioDevice -PlaybackVolume)' 2>/dev/null | tr -d '[:space:]')"
        powershell.exe -NoProfile -Command "Set-AudioDevice -PlaybackVolume $WAKEUP_VOLUME" >/dev/null 2>&1
      fi
      ;;
  esac
}

restore_volume() {
  [ -n "$PREV_VOLUME" ] || return 0
  case "$WAKEUP_OS" in
    macos)
      osascript -e "set volume output volume $PREV_VOLUME" >/dev/null 2>&1
      ;;
    linux)
      if command -v amixer >/dev/null 2>&1; then
        amixer set Master "${PREV_VOLUME}%" >/dev/null 2>&1
      elif command -v pactl >/dev/null 2>&1; then
        pactl set-sink-volume @DEFAULT_SINK@ "${PREV_VOLUME}%" >/dev/null 2>&1
      fi
      ;;
    windows)
      if command -v powershell.exe >/dev/null 2>&1; then
        powershell.exe -NoProfile -Command "Set-AudioDevice -PlaybackVolume $PREV_VOLUME" >/dev/null 2>&1
      fi
      ;;
  esac
}

# --- cleanup ----------------------------------------------------------------
cleanup() {
  stop_player
  restore_volume
  rm -rf "$WAKEUP_LOCK" 2>/dev/null
}

# --- run --------------------------------------------------------------------
acquire_lock || { log "skip $trigger (another alarm holds the lock)"; exit 0; }
trap cleanup EXIT INT TERM

log "armed by $trigger — waiting ${WAKEUP_DELAY_SECS}s (os=$WAKEUP_OS player=$PLAYER_NAME)"
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
  log "PLAY $video (dry run, trigger=$trigger, idle=${idle}s, os=$WAKEUP_OS, player=$PLAYER_NAME)"
  exit 0
fi

set_volume
log "PLAY $video (trigger=$trigger, idle=${idle}s, os=$WAKEUP_OS, player=$PLAYER_NAME)"

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
