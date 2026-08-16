#!/usr/bin/env bash
# Shared settings and helpers. Sourced by wakeup.sh and lib/play.sh.
# Wires together platform detection, player abstraction, and agent support.

WAKEUP_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Load platform detection (sets WAKEUP_OS, provides idle_secs).
. "$WAKEUP_HOME/lib/platform.sh"

# Load player abstraction (provides detect_player, start_player, etc.).
. "$WAKEUP_HOME/lib/player.sh"

# Load agent support (provides detect_agents, parse_hook_event, etc.).
. "$WAKEUP_HOME/lib/agents.sh"

# Load config.
[ -r "$WAKEUP_HOME/config.env" ] && . "$WAKEUP_HOME/config.env"

# Defaults — a missing or half-edited config.env must never break the agent session.
: "${WAKEUP_DELAY_SECS:=10}"
: "${WAKEUP_IDLE_SECS:=10}"
: "${WAKEUP_EVENTS:=permission_prompt idle_prompt agent_needs_input agent_completed stop}"
: "${WAKEUP_VIDEO:=}"
: "${WAKEUP_PLAYER:=auto}"
: "${WAKEUP_VOLUME:=}"
: "${WAKEUP_LOOP:=0}"
: "${WAKEUP_MAX_SECS:=120}"
: "${WAKEUP_RETURN_SECS:=2}"
: "${WAKEUP_LOG:=$HOME/.claude/wakeup.log}"
: "${WAKEUP_LOCK:=${TMPDIR:-${TMP:-/tmp}}/claude-wakeup.lock}"

# Initialize player detection.
detect_player

# Logging — appends timestamped line to the log file.
log() {
  mkdir -p "$(dirname "$WAKEUP_LOG")" 2>/dev/null
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$WAKEUP_LOG" 2>/dev/null
  return 0
}

# Resolve the video to play: explicit path, or random from media/.
resolve_video() {
  if [ -n "$WAKEUP_VIDEO" ]; then
    printf '%s\n' "$WAKEUP_VIDEO"
    return 0
  fi
  local -a clips=()
  local f
  for f in "$WAKEUP_HOME"/media/*.mp4 "$WAKEUP_HOME"/media/*.mov "$WAKEUP_HOME"/media/*.avi "$WAKEUP_HOME"/media/*.mkv "$WAKEUP_HOME"/media/*.webm; do
    [ -f "$f" ] && clips+=("$f")
  done
  [ ${#clips[@]} -gt 0 ] || return 0
  printf '%s\n' "${clips[RANDOM % ${#clips[@]}]}"
}

# True if an alarm is already armed or playing (atomic lock via mkdir).
lock_held() {
  [ -d "$WAKEUP_LOCK" ] || return 1
  local pid
  pid="$(cat "$WAKEUP_LOCK/pid" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# Print a summary of the current environment (for debugging / install output).
print_env_summary() {
  echo "  OS:        $WAKEUP_OS"
  echo "  Player:    $PLAYER_NAME"
  if [ "$WAKEUP_OS" = "linux" ]; then
    echo "  Display:   $(detect_display_server)"
  fi
  echo "  Log:       $WAKEUP_LOG"
}
