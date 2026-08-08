#!/usr/bin/env bash
# Agent hook entrypoint.
#
# Two rules live here: this script must return in milliseconds (it sits in the path of
# every session), and it must never exit non-zero (a failing hook must not break your work).
# So it only decides *whether* to wake you, then hands off to a detached worker.

set -uo pipefail

# shellcheck source=lib/common.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

payload="$(cat 2>/dev/null)"

event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"
ntype="$(printf '%s' "$payload" | jq -r '.notification_type // empty' 2>/dev/null)"

case "$event" in
  Stop)         key="stop"   ;;
  Notification) key="$ntype" ;;
  *)            key=""       ;;
esac

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

# Detached: subshell + nohup + all stdio redirected is what survives the agent
# reaping this hook's process group. tests/run-tests.sh asserts it actually does.
( nohup "$WAKEUP_HOME/lib/play.sh" "$key" </dev/null >>"$WAKEUP_LOG" 2>&1 & ) >/dev/null 2>&1

exit 0
