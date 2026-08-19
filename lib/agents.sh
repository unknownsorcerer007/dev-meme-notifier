#!/usr/bin/env bash
# Multi-agent support: detect installed agents, their config paths, hook formats.
# Supported: Claude Code, OpenAI Codex, Hermes (MSRC), Goose, generic.

# Discover all installed coding agents on this system.
# Returns a newline-separated list of agent IDs.
detect_agents() {
  local found=""

  # Claude Code
  if _agent_exists_claude; then
    found="${found}claude\n"
  fi

  # OpenAI Codex CLI
  if _agent_exists_codex; then
    found="${found}codex\n"
  fi

  # Hermes (MSRC)
  if _agent_exists_hermes; then
    found="${found}hermes\n"
  fi

  # Goose (Block)
  if _agent_exists_goose; then
    found="${found}goose\n"
  fi

  # Aider
  if _agent_exists_aider; then
    found="${found}aider\n"
  fi

  printf '%b' "$found"
}

# Get the settings file path for an agent.
agent_settings_path() {
  local agent="$1"
  case "$agent" in
    claude)
      if [ "${WAKEUP_SCOPE:-global}" = "project" ]; then
        echo "$WAKEUP_HOME/.claude/settings.json"
      else
        echo "${HOME}/.claude/settings.json"
      fi
      ;;
    codex)
      if [ "${WAKEUP_SCOPE:-global}" = "project" ]; then
        echo "$WAKEUP_HOME/.codex/config.toml"
      else
        echo "${HOME}/.codex/config.toml"
      fi
      ;;
    hermes)
      if [ "${WAKEUP_SCOPE:-global}" = "project" ]; then
        echo "$WAKEUP_HOME/.hermes/config.toml"
      else
        echo "${HOME}/.hermes/config.toml"
      fi
      ;;
    goose)
      if [ "${WAKEUP_SCOPE:-global}" = "project" ]; then
        echo "$WAKEUP_HOME/.goose/config.yaml"
      else
        echo "${HOME}/.goose/config.yaml"
      fi
      ;;
    aider)
      if [ "${WAKEUP_SCOPE:-global}" = "project" ]; then
        echo "$WAKEUP_HOME/.aider.conf.yml"
      else
        echo "${HOME}/.aider.conf.yml"
      fi
      ;;
    *)
      echo ""
      ;;
  esac
}

# Inject the wakeup hook into an agent's config.
# Handles idempotency (strips old entries first).
agent_install_hook() {
  local agent="$1"
  local hook_cmd="$2"

  case "$agent" in
    claude)   _install_claude "$hook_cmd" ;;
    codex)    _install_codex "$hook_cmd" ;;
    hermes)   _install_hermes "$hook_cmd" ;;
    goose)    _install_goose "$hook_cmd" ;;
    aider)    _install_aider "$hook_cmd" ;;
    *)        echo "  unknown agent: $agent" >&2 ;;
  esac
}

# Remove the wakeup hook from an agent's config.
agent_uninstall_hook() {
  local agent="$1"
  case "$agent" in
    claude)   _uninstall_claude ;;
    codex)    _uninstall_codex ;;
    hermes)   _uninstall_hermes ;;
    goose)    _uninstall_goose ;;
    aider)    _uninstall_aider ;;
    *)        echo "  unknown agent: $agent" >&2 ;;
  esac
}

# Get a human-readable name for an agent.
agent_display_name() {
  case "$1" in
    claude) echo "Claude Code" ;;
    codex)  echo "OpenAI Codex" ;;
    hermes) echo "Hermes" ;;
    goose)  echo "Goose" ;;
    aider)  echo "Aider" ;;
    *)      echo "$1" ;;
  esac
}

# --- Agent detection helpers ---

_agent_exists_claude() {
  command -v claude >/dev/null 2>&1 || \
  [ -d "${HOME}/.claude" ] || \
  [ -f "${HOME}/.claude/settings.json" ]
}

_agent_exists_codex() {
  command -v codex >/dev/null 2>&1 || \
  [ -d "${HOME}/.codex" ] || \
  [ -f "${HOME}/.codex/config.toml" ]
}

_agent_exists_hermes() {
  command -v hermes >/dev/null 2>&1 || \
  [ -d "${HOME}/.hermes" ] || \
  [ -f "${HOME}/.hermes/config.toml" ]
}

_agent_exists_goose() {
  command -v goose >/dev/null 2>&1 || \
  [ -d "${HOME}/.goose" ] || \
  [ -f "${HOME}/.goose/config.yaml" ]
}

_agent_exists_aider() {
  command -v aider >/dev/null 2>&1 || \
  [ -f "${HOME}/.aider.conf.yml" ] || \
  [ -f "${HOME}/.aider.conf" ]
}

# --- Claude Code hook install/uninstall (JSON via jq) ---

_install_claude() {
  local hook_cmd="$1"
  local settings
  settings="$(agent_settings_path claude)"

  mkdir -p "$(dirname "$settings")"
  [ -f "$settings" ] || echo '{}' >"$settings"

  if ! jq empty "$settings" 2>/dev/null; then
    echo "  ✗ $settings is not valid JSON" >&2
    return 1
  fi

  cp "$settings" "$settings.bak.$(date +%s)"

  local tmp
  tmp="$(mktemp)"
  jq --arg cmd "$hook_cmd" '
    def strip:
      map(.hooks |= map(select((.command // "") | test("wakeup\\.sh") | not)))
      | map(select((.hooks | length) > 0));

    def entry: { matcher: "*", hooks: [{ type: "command", command: $cmd, timeout: 5 }] };

    .hooks //= {}
    | .hooks.Notification = ((.hooks.Notification // []) | strip) + [entry]
    | .hooks.Stop         = ((.hooks.Stop         // []) | strip) + [entry]
  ' "$settings" >"$tmp"

  if ! jq empty "$tmp" 2>/dev/null; then
    echo "  ✗ refusing to write invalid JSON" >&2
    rm -f "$tmp"
    return 1
  fi

  mv "$tmp" "$settings"
  echo "  ✓ Claude Code → $settings"
}

_uninstall_claude() {
  local settings
  settings="$(agent_settings_path claude)"
  [ -f "$settings" ] || { echo "  nothing to do"; return 0; }

  cp "$settings" "$settings.bak.$(date +%s)"

  local tmp
  tmp="$(mktemp)"
  jq '
    def strip:
      map(.hooks |= map(select((.command // "") | test("wakeup\\.sh") | not)))
      | map(select((.hooks | length) > 0));

    if .hooks then
      .hooks |= with_entries(.value |= strip)
      | .hooks |= with_entries(select((.value | length) > 0))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ' "$settings" >"$tmp"

  if ! jq empty "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$settings"
  echo "  ✓ Claude Code → $settings"
}

# --- Codex hook install/uninstall (TOML config) ---

_install_codex() {
  local hook_cmd="$1"
  local config
  config="$(agent_settings_path codex)"

  mkdir -p "$(dirname "$config")"
  cp "$config" "$config.bak.$(date +%s)" 2>/dev/null || true

  # Remove old wakeup entries
  if [ -f "$config" ]; then
    grep -v 'wakeup\.sh' "$config" > "$config.tmp" 2>/dev/null || true
    mv "$config.tmp" "$config"
  fi

  # Add hook entry — Codex uses TOML with [hooks] section
  # Codex supports post_tool_call hooks
  cat >>"$config" <<EOF

# dev-meme-notifier hook
[hooks]
on_notification = "$hook_cmd"
on_idle = "$hook_cmd"
EOF

  echo "  ✓ Codex → $config"
}

_uninstall_codex() {
  local config
  config="$(agent_settings_path codex)"
  [ -f "$config" ] || { echo "  nothing to do"; return 0; }

  cp "$config" "$config.bak.$(date +%s)"
  grep -v 'wakeup\.sh' "$config" | grep -v 'dev-meme-notifier' | grep -v 'claude-code-wakeup-alarm' > "$config.tmp" 2>/dev/null || true
  mv "$config.tmp" "$config"
  echo "  ✓ Codex → $config"
}

# --- Hermes hook install/uninstall (TOML config) ---

_install_hermes() {
  local hook_cmd="$1"
  local config
  config="$(agent_settings_path hermes)"

  mkdir -p "$(dirname "$config")"
  cp "$config" "$config.bak.$(date +%s)" 2>/dev/null || true

  if [ -f "$config" ]; then
    grep -v 'wakeup\.sh' "$config" > "$config.tmp" 2>/dev/null || true
    mv "$config.tmp" "$config"
  fi

  cat >>"$config" <<EOF

# dev-meme-notifier hook
[hooks]
on_notification = "$hook_cmd"
on_idle = "$hook_cmd"
EOF

  echo "  ✓ Hermes → $config"
}

_uninstall_hermes() {
  local config
  config="$(agent_settings_path hermes)"
  [ -f "$config" ] || { echo "  nothing to do"; return 0; }

  cp "$config" "$config.bak.$(date +%s)"
  grep -v 'wakeup\.sh' "$config" | grep -v 'dev-meme-notifier' | grep -v 'claude-code-wakeup-alarm' > "$config.tmp" 2>/dev/null || true
  mv "$config.tmp" "$config"
  echo "  ✓ Hermes → $config"
}

# --- Goose hook install/uninstall (YAML config) ---

_install_goose() {
  local hook_cmd="$1"
  local config
  config="$(agent_settings_path goose)"

  mkdir -p "$(dirname "$config")"
  cp "$config" "$config.bak.$(date +%s)" 2>/dev/null || true

  if [ -f "$config" ]; then
    grep -v 'wakeup\.sh' "$config" > "$config.tmp" 2>/dev/null || true
    mv "$config.tmp" "$config"
  fi

  cat >>"$config" <<EOF

# dev-meme-notifier hook
hooks:
  on_notification: "$hook_cmd"
  on_idle: "$hook_cmd"
EOF

  echo "  ✓ Goose → $config"
}

_uninstall_goose() {
  local config
  config="$(agent_settings_path goose)"
  [ -f "$config" ] || { echo "  nothing to do"; return 0; }

  cp "$config" "$config.bak.$(date +%s)"
  grep -v 'wakeup\.sh' "$config" | grep -v 'dev-meme-notifier' | grep -v 'claude-code-wakeup-alarm' > "$config.tmp" 2>/dev/null || true
  mv "$config.tmp" "$config"
  echo "  ✓ Goose → $config"
}

# --- Aider hook install/uninstall (YAML config) ---

_install_aider() {
  local hook_cmd="$1"
  local config
  config="$(agent_settings_path aider)"

  mkdir -p "$(dirname "$config")"
  cp "$config" "$config.bak.$(date +%s)" 2>/dev/null || true

  if [ -f "$config" ]; then
    grep -v 'wakeup\.sh' "$config" > "$config.tmp" 2>/dev/null || true
    mv "$config.tmp" "$config"
  fi

  cat >>"$config" <<EOF

# dev-meme-notifier hook
hooks:
  on_notification: "$hook_cmd"
  on_idle: "$hook_cmd"
EOF

  echo "  ✓ Aider → $config"
}

_uninstall_aider() {
  local config
  config="$(agent_settings_path aider)"
  [ -f "$config" ] || { echo "  nothing to do"; return 0; }

  cp "$config" "$config.bak.$(date +%s)"
  grep -v 'wakeup\.sh' "$config" | grep -v 'dev-meme-notifier' | grep -v 'claude-code-wakeup-alarm' > "$config.tmp" 2>/dev/null || true
  mv "$config.tmp" "$config"
  echo "  ✓ Aider → $config"
}

# Parse hook JSON from stdin into a normalized event key.
# Supports Claude Code format; other agents may need adaptation.
# Returns: the event key (stop, permission_prompt, etc.) or empty string.
parse_hook_event() {
  local payload="$1"
  local event ntype key

  event="$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null)"
  ntype="$(printf '%s' "$payload" | jq -r '.notification_type // empty' 2>/dev/null)"

  case "$event" in
    Stop)         key="stop"   ;;
    Notification) key="$ntype" ;;
    *)
      # Try alternative field names used by other agents
      key="$(printf '%s' "$payload" | jq -r '.event // .type // .kind // empty' 2>/dev/null)"
      ;;
  esac

  echo "$key"
}
