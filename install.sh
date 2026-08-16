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

while [ $# -gt 0 ]; do
  case "$1" in
    --project)  SCOPE="project"; shift ;;
    --agent)    TARGET_AGENTS+=("$2"); shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--project] [--agent NAME ...]"
      echo
      echo "  --project     Install hooks for this project only"
      echo "  --agent NAME  Install for a specific agent (claude, codex, hermes, goose, aider)"
      echo "                Can be repeated. Without --agent, installs for all detected agents."
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

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
