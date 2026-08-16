#!/usr/bin/env bash
# Universal hook entrypoint for all coding agents.
#
# Two rules: return in milliseconds (sits in the path of every session),
# and never exit non-zero (a failing hook must not break your work).
# So it only decides *whether* to wake you, then hands off to a detached worker.

set -uo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

# Read the hook payload from stdin.
payload="$(cat 2>/dev/null)"

# Normalize the event into a key.
# Supports: Claude Code JSON, Codex JSON, generic event/type/kind fields.
key="$(parse_hook_event "$payload")"

# Also try parsing as a simple string (some agents pass plain text events).
if [ -z "$key" ]; then
  key="$(printf '%s' "$payload" | tr -d '[:space:]' | tr '[:upper:]' '[:lower:]')"
  case "$key" in
    *permission*|*needs_approval*)  key="permission_prompt" ;;
    *idle*|*waiting*)               key="idle_prompt" ;;
    *needs_input*|*question*)       key="agent_needs_input" ;;
    *completed*|*done*)             key="agent_completed" ;;
    *stop*|*finished*)              key="stop" ;;
    *)                              key="" ;;
  esac
fi

# No recognizable event → silently exit.
[ -n "$key" ] || exit 0

# Not an event you asked to be woken for.
case " $WAKEUP_EVENTS " in
  *" $key "*) ;;
  *) exit 0 ;;
esac

# A permission prompt and a Stop can land seconds apart; one alarm is plenty.
if lock_held; then
  log "skip $key (an alarm is already armed)"
  exit 0
fi

# Detached: subshell + nohup + all stdio redirected — survives agent reaping this
# hook's process group. tests/run-tests.sh asserts it actually does.
( nohup "$WAKEUP_HOME/lib/play.sh" "$key" </dev/null >>"$WAKEUP_LOG" 2>&1 & ) >/dev/null 2>&1

exit 0
