#!/usr/bin/env bash
# Shared settings and helpers. Sourced by wakeup.sh and lib/play.sh.

WAKEUP_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
[ -r "$WAKEUP_HOME/config.env" ] && . "$WAKEUP_HOME/config.env"

# Defaults, so a missing or half-edited config.env can never break an agent session.
: "${WAKEUP_DELAY_SECS:=10}"
: "${WAKEUP_IDLE_SECS:=10}"
: "${WAKEUP_EVENTS:=permission_prompt idle_prompt agent_needs_input agent_completed stop}"
: "${WAKEUP_VIDEO:=}"
: "${WAKEUP_PLAYER:=ffplay}"
: "${WAKEUP_VOLUME:=}"
: "${WAKEUP_LOOP:=0}"
: "${WAKEUP_MAX_SECS:=120}"
: "${WAKEUP_RETURN_SECS:=2}"
: "${WAKEUP_LOG:=$HOME/.claude/wakeup.log}"
: "${WAKEUP_LOCK:=${TMPDIR:-/tmp}/claude-wakeup.lock}"

log() {
  mkdir -p "$(dirname "$WAKEUP_LOG")" 2>/dev/null
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$WAKEUP_LOG" 2>/dev/null
  return 0
}

# Seconds since the last keyboard or mouse input.
# The two OVERRIDE vars are test seams: a fixed number, or a file whose contents can
# change mid-run so tests can simulate you walking back to the desk.
idle_secs() {
  if [ -n "${WAKEUP_IDLE_OVERRIDE_FILE:-}" ] && [ -r "${WAKEUP_IDLE_OVERRIDE_FILE}" ]; then
    printf '%s\n' "$(cat "$WAKEUP_IDLE_OVERRIDE_FILE" 2>/dev/null || echo 0)"
    return 0
  fi
  if [ -n "${WAKEUP_IDLE_OVERRIDE:-}" ]; then
    printf '%s\n' "$WAKEUP_IDLE_OVERRIDE"
    return 0
  fi
  local n
  n="$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')"
  case "$n" in
    ''|*[!0-9]*)
      # Can't tell how long you've been away. Assume you're gone rather than stay silent.
      printf '999\n' ;;
    *) printf '%s\n' "$n" ;;
  esac
}

# The video to play: WAKEUP_VIDEO if set, otherwise a random .mp4 from media/.
resolve_video() {
  if [ -n "$WAKEUP_VIDEO" ]; then
    printf '%s\n' "$WAKEUP_VIDEO"
    return 0
  fi
  local -a clips=()
  local f
  for f in "$WAKEUP_HOME"/media/*.mp4 "$WAKEUP_HOME"/media/*.mov; do
    [ -f "$f" ] && clips+=("$f")
  done
  [ ${#clips[@]} -gt 0 ] || return 0
  printf '%s\n' "${clips[RANDOM % ${#clips[@]}]}"
}

# True if an alarm is already armed or playing.
lock_held() {
  [ -d "$WAKEUP_LOCK" ] || return 1
  local pid
  pid="$(cat "$WAKEUP_LOCK/pid" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
