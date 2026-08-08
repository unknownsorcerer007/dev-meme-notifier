#!/usr/bin/env bash
# Install the wake-up hooks into ~/.claude/settings.json.
#
#   ./install.sh              # global: every agent session, every project
#   ./install.sh --project    # just this repo (.claude/settings.json here)
#
# Safe to run repeatedly: it strips any previous dev-meme-notifier entries first,
# and backs up your settings before touching them.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$ROOT/wakeup.sh"

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required (brew install jq)" >&2
  exit 1
fi

if [ "${1:-}" = "--project" ]; then
  SETTINGS="$ROOT/.claude/settings.json"
  SCOPE="this project only"
else
  SETTINGS="$HOME/.claude/settings.json"
  SCOPE="every agent session"
fi

mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo '{}' >"$SETTINGS"

if ! jq empty "$SETTINGS" 2>/dev/null; then
  echo "error: $SETTINGS is not valid JSON — fix it before installing" >&2
  exit 1
fi

BACKUP="$SETTINGS.bak.$(date +%s)"
cp "$SETTINGS" "$BACKUP"

TMP="$(mktemp)"
jq --arg cmd "$HOOK" '
  def strip:
    map(.hooks |= map(select((.command // "") | test("wakeup\\.sh") | not)))
    | map(select((.hooks | length) > 0));

  def entry: { matcher: "*", hooks: [ { type: "command", command: $cmd, timeout: 5 } ] };

  .hooks //= {}
  | .hooks.Notification = ((.hooks.Notification // []) | strip) + [entry]
  | .hooks.Stop         = ((.hooks.Stop         // []) | strip) + [entry]
' "$SETTINGS" >"$TMP"

jq empty "$TMP" 2>/dev/null || { echo "error: refusing to write invalid JSON" >&2; rm -f "$TMP"; exit 1; }
mv "$TMP" "$SETTINGS"

echo "installed → $SETTINGS  (active for: $SCOPE)"
echo "backup    → $BACKUP"
echo
jq '.hooks' "$SETTINGS"
echo
echo "Hooks load when a session starts, so restart your agent to arm it."
echo "Log: ${WAKEUP_LOG:-$HOME/.claude/wakeup.log}"
