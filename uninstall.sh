#!/usr/bin/env bash
# Universal uninstaller for all coding agents.
#
#   ./uninstall.sh              # global: all detected agents
#   ./uninstall.sh --project    # this repo only
#   ./uninstall.sh --agent claude   # specific agent only

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Parse args
SCOPE="global"
TARGET_AGENTS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --project)  SCOPE="project"; shift ;;
    --agent)    TARGET_AGENTS+=("$2"); shift 2 ;;
    --help|-h)
      echo "Usage: $0 [--project] [--agent NAME ...]"
      exit 0
      ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

# Source shared modules
. "$SCRIPT_DIR/lib/common.sh"

echo
echo "uninstalling claude-code-wakeup-alarm hooks..."
echo

# If no specific agents given, detect all
if [ ${#TARGET_AGENTS[@]} -eq 0 ]; then
  while IFS= read -r agent; do
    [ -n "$agent" ] && TARGET_AGENTS+=("$agent")
  done < <(detect_agents)
fi

if [ ${#TARGET_AGENTS[@]} -eq 0 ]; then
  echo "  no supported agents detected — nothing to do"
  exit 0
fi

export WAKEUP_SCOPE="$SCOPE"

for agent in "${TARGET_AGENTS[@]}"; do
  name="$(agent_display_name "$agent")"
  echo "  $name ($SCOPE scope):"
  agent_uninstall_hook "$agent"
done

echo
echo "done. restart your agent(s) for changes to take effect."
echo
