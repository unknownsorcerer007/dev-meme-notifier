#!/usr/bin/env bash
# Universal installer for all coding agents.
#
#   ./install.sh              # global: all detected agents
#   ./install.sh --project    # this repo only
#   ./install.sh --agent claude   # specific agent only
#
# Auto-installs dependencies (jq, ffmpeg, xprintidle).
# Safe to run repeatedly: strips previous entries first, backs up settings.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/wakeup.sh"

# Parse args
SCOPE="global"
TARGET_AGENTS=()
INSTALL_MCP=false

while [ $# -gt 0 ]; do
  case "$1" in
    --project)  SCOPE="project"; shift ;;
    --agent)    TARGET_AGENTS+=("$2"); shift 2 ;;
    --mcp)      INSTALL_MCP=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--project] [--agent NAME ...] [--mcp]"
      echo
      echo "  --project     Install hooks for this project only"
      echo "  --agent NAME  Install for a specific agent (claude, codex, hermes, goose, aider)"
      echo "                Can be repeated. Without --agent, installs for all detected agents."
      echo "  --mcp         Also install MCP server dependencies (Node.js >= 18 required)"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# Create config.env from example if it doesn't exist
if [ ! -f "$SCRIPT_DIR/config.env" ] && [ -f "$SCRIPT_DIR/config.env.example" ]; then
  cp "$SCRIPT_DIR/config.env.example" "$SCRIPT_DIR/config.env"
  echo "created config.env from config.env.example"
fi

# Source shared modules
. "$SCRIPT_DIR/lib/common.sh"
. "$SCRIPT_DIR/lib/deps.sh"

echo
echo "╔══════════════════════════════════════════════╗"
echo "║    claude-code-wakeup-alarm — installer      ║"
echo "╚══════════════════════════════════════════════╝"
echo
print_env_summary
echo

# --- Install dependencies ---
install_deps

# --- Detect agents ---
if [ ${#TARGET_AGENTS[@]} -eq 0 ]; then
  echo "detecting installed agents..."
  while IFS= read -r agent; do
    [ -n "$agent" ] && TARGET_AGENTS+=("$agent")
  done < <(detect_agents)
fi

if [ ${#TARGET_AGENTS[@]} -eq 0 ]; then
  echo "  ⚠ no supported agents detected"
  echo "  install a supported agent (claude, codex, hermes, goose, aider) and re-run"
  echo
  echo "  you can also specify manually: $0 --agent claude"
  exit 0
fi

echo
echo "configuring agents..."
echo

export WAKEUP_SCOPE="$SCOPE"

HOOKS_INSTALLED=0
for agent in "${TARGET_AGENTS[@]}"; do
  name="$(agent_display_name "$agent")"
  echo "  $name ($SCOPE scope):"
  if agent_install_hook "$agent" "$HOOK"; then
    HOOKS_INSTALLED=$((HOOKS_INSTALLED + 1))
  fi
done

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
      cd "$SCRIPT_DIR/mcp-server"
      if command -v npm >/dev/null 2>&1; then
        npm install --production 2>&1 | tail -3
      elif command -v pnpm >/dev/null 2>&1; then
        pnpm install --prod 2>&1 | tail -3
      else
        echo "⚠️  Neither npm nor pnpm found. Install dependencies manually:"
        echo "   cd $SCRIPT_DIR/mcp-server && npm install"
      fi
      echo
      echo "✅ MCP server ready!"
      echo
      echo "To use with your agent, add to your MCP config:"
      echo
      echo '  "dev-meme-notifier": {'
      echo '    "command": "node",'
      echo "    \"args\": [\"$SCRIPT_DIR/mcp-server/server.js\"]"
      echo '  }'
      echo
      echo "Or run directly:"
      echo "  node $SCRIPT_DIR/mcp-server/server.js"
      echo
      echo "For remote agents (SSE mode):"
      echo "  node $SCRIPT_DIR/mcp-server/server.js --port 3000"
      cd "$SCRIPT_DIR"
    fi
  fi
fi

echo
echo "╔══════════════════════════════════════════════╗"
echo "║    installation complete!                    ║"
echo "╚══════════════════════════════════════════════╝"
echo
echo "  hooks installed for: $(printf '%s ' "${TARGET_AGENTS[@]}")"
echo "  scope: $SCOPE"
echo "  player: $PLAYER_NAME"
echo "  log: ${WAKEUP_LOG:-$HOME/.claude/wakeup.log}"
echo
echo "  drop .mp4/.mov/.avi/.mkv/.webm files into media/ for custom alarms"
echo
echo "  restart your agent(s) to activate the hooks"
echo
