#!/usr/bin/env bash
# Install the wake-up hooks into ~/.claude/settings.json.
# Also optionally sets up the MCP server.
#
#   ./install.sh              # global: every agent session, every project
#   ./install.sh --project    # just this repo (.claude/settings.json here)
#   ./install.sh --mcp        # also install MCP server dependencies
#   ./install.sh --project --mcp  # both
#
# Safe to run repeatedly: it strips any previous dev-meme-notifier entries first,
# and backs up your settings before touching them.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$ROOT/wakeup.sh"

# Parse arguments
PROJECT_ONLY=false
INSTALL_MCP=false
for arg in "$@"; do
  case "$arg" in
    --project) PROJECT_ONLY=true ;;
    --mcp)     INSTALL_MCP=true ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required" >&2
  echo "  macOS:  brew install jq" >&2
  echo "  Linux:  apt install jq / dnf install jq" >&2
  exit 1
fi

if [ "$PROJECT_ONLY" = true ]; then
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

# --- MCP Server Setup ---
if [ "$INSTALL_MCP" = true ]; then
  echo
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  MCP Server Setup"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  if ! command -v node >/dev/null 2>&1; then
    echo "⚠️  Node.js not found — MCP server requires Node.js >= 18"
    echo "   Install: https://nodejs.org/"
    echo "   Skipping MCP setup."
  else
    NODE_VER="$(node -v | sed 's/v//' | cut -d. -f1)"
    if [ "$NODE_VER" -lt 18 ]; then
      echo "⚠️  Node.js $NODE_VER found, but MCP requires >= 18"
      echo "   Update: https://nodejs.org/"
      echo "   Skipping MCP setup."
    else
      echo "📦 Installing MCP server dependencies..."
      cd "$ROOT/mcp-server"
      if command -v npm >/dev/null 2>&1; then
        npm install --production 2>&1 | tail -3
      elif command -v pnpm >/dev/null 2>&1; then
        pnpm install --prod 2>&1 | tail -3
      else
        echo "⚠️  Neither npm nor pnpm found. Install dependencies manually:"
        echo "   cd $ROOT/mcp-server && npm install"
      fi
      echo
      echo "✅ MCP server ready!"
      echo
      echo "To use with your agent, add to your MCP config:"
      echo
      echo '  "dev-meme-notifier": {'
      echo '    "command": "node",'
      echo "    \"args\": [\"$ROOT/mcp-server/server.js\"]"
      echo '  }'
      echo
      echo "Or run directly:"
      echo "  node $ROOT/mcp-server/server.js"
      echo
      echo "For remote agents (SSE mode):"
      echo "  node $ROOT/mcp-server/server.js --port 3000"
      cd "$ROOT"
    fi
  fi
fi

# --- Check dependencies ---
echo
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Dependency Check"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

OS="$(uname -s)"

# Check for a video player
PLAYER_FOUND=false
for p in mpv ffplay vlc; do
  if command -v "$p" >/dev/null 2>&1; then
    echo "✅ $p — available"
    PLAYER_FOUND=true
  fi
done
if [ "$OS" = "Darwin" ]; then
  echo "✅ quicktime — available (macOS)"
  PLAYER_FOUND=true
fi
if [ "$PLAYER_FOUND" = false ]; then
  echo "⚠️  No video player found!"
  echo "   Install one of: mpv (recommended), ffmpeg (ffplay), vlc"
  echo "   macOS:  brew install mpv"
  echo "   Linux:  apt install mpv / dnf install mpv"
fi

# Check for idle detection
if [ "$OS" = "Darwin" ]; then
  echo "✅ idle detection — ioreg (macOS)"
elif command -v xprintidle >/dev/null 2>&1; then
  echo "✅ idle detection — xprintidle (X11)"
elif command -v gdbus >/dev/null 2>&1; then
  echo "✅ idle detection — gdbus (Wayland/GNOME)"
else
  echo "⚠️  No idle detection tool found (alarm will still work but can't detect your return)"
  echo "   Install: apt install xprintidle (X11) or use GNOME/Wayland"
fi

echo
echo "Done! Drop your own .mp4/.mov/.gif files into media/ for custom alarms."
echo "Or set WAKEUP_MEME_API=reddit in config.env to auto-fetch dev memes."
