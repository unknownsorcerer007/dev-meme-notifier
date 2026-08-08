#!/usr/bin/env bash
# Remove the wake-up hooks again. Leaves every other setting untouched.
#
#   ./uninstall.sh            # from ~/.claude/settings.json
#   ./uninstall.sh --project  # from this repo's .claude/settings.json

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "${1:-}" = "--project" ]; then
  SETTINGS="$ROOT/.claude/settings.json"
else
  SETTINGS="$HOME/.claude/settings.json"
fi

if [ ! -f "$SETTINGS" ]; then
  echo "nothing to do: $SETTINGS does not exist"
  exit 0
fi

BACKUP="$SETTINGS.bak.$(date +%s)"
cp "$SETTINGS" "$BACKUP"

TMP="$(mktemp)"
jq '
  def strip:
    map(.hooks |= map(select((.command // "") | test("wakeup\\.sh") | not)))
    | map(select((.hooks | length) > 0));

  if .hooks then
    .hooks |= with_entries(.value |= strip)
    | .hooks |= with_entries(select((.value | length) > 0))
    | if (.hooks | length) == 0 then del(.hooks) else . end
  else . end
' "$SETTINGS" >"$TMP"

jq empty "$TMP" 2>/dev/null || { echo "error: refusing to write invalid JSON" >&2; rm -f "$TMP"; exit 1; }
mv "$TMP" "$SETTINGS"

echo "removed from → $SETTINGS"
echo "backup       → $BACKUP"
