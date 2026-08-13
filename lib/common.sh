#!/usr/bin/env bash
# Shared settings and helpers. Sourced by wakeup.sh and lib/play.sh.
# Cross-platform: macOS, Linux (X11/Wayland).

WAKEUP_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=/dev/null
[ -r "$WAKEUP_HOME/config.env" ] && . "$WAKEUP_HOME/config.env"

# Defaults, so a missing or half-edited config.env can never break an agent session.
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
: "${WAKEUP_LOCK:=${TMPDIR:-/tmp}/claude-wakeup.lock}"
: "${WAKEUP_MEME_API:=}"
# WAKEUP_MEME_DIR: use default if unset or empty
WAKEUP_MEME_DIR="${WAKEUP_MEME_DIR:-$WAKEUP_HOME/media}"
: "${WAKEUP_GIPHY_API_KEY:=}"
: "${WAKEUP_TENOR_API_KEY:=}"
: "${WAKEUP_IMGFLIP_USERNAME:=}"
: "${WAKEUP_IMGFLIP_PASSWORD:=}"
: "${WAKEUP_REDDIT_CLIENT_ID:=}"
: "${WAKEUP_REDDIT_CLIENT_SECRET:=}"
: "${WAKEUP_REDDIT_USERNAME:=}"
: "${WAKEUP_REDDIT_PASSWORD:=}"
: "${WAKEUP_CUSTOM_HEADERS:=}"

OS="$(uname -s)"

log() {
  mkdir -p "$(dirname "$WAKEUP_LOG")" 2>/dev/null
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$WAKEUP_LOG" 2>/dev/null
  return 0
}

# --- Cross-platform idle detection -------------------------------------------
# Seconds since the last keyboard or mouse input.
# The two OVERRIDE vars are test seams.
idle_secs() {
  if [ -n "${WAKEUP_IDLE_OVERRIDE_FILE:-}" ] && [ -r "${WAKEUP_IDLE_OVERRIDE_FILE}" ]; then
    printf '%s\n' "$(cat "$WAKEUP_IDLE_OVERRIDE_FILE" 2>/dev/null || echo 0)"
    return 0
  fi
  if [ -n "${WAKEUP_IDLE_OVERRIDE:-}" ]; then
    printf '%s\n' "$WAKEUP_IDLE_OVERRIDE"
    return 0
  fi

  local n=""
  case "$OS" in
    Darwin)
      n="$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')" ;;
    Linux)
      n="$(_idle_linux)" ;;
    *)
      n="" ;;
  esac

  case "$n" in
    ''|*[!0-9]*)
      # Can't tell how long you've been away. Assume you're gone rather than stay silent.
      printf '999\n' ;;
    *) printf '%s\n' "$n" ;;
  esac
}

# Linux idle detection: tries xprintidle (X11), then swayidle/gnome dbus (Wayland),
# then falls back to /dev/input event timing.
_idle_linux() {
  local n=""

  # xprintidle returns milliseconds on X11
  if command -v xprintidle >/dev/null 2>&1; then
    n="$(xprintidle 2>/dev/null)"
    case "$n" in
      ''|*[!0-9]*) ;;
      *) printf '%d\n' "$((n / 1000))"; return 0 ;;
    esac
  fi

  # GNOME Wayland: use gdbus to query Mutter IdleMonitor
  if command -v gdbus >/dev/null 2>&1; then
    n="$(gdbus call --session --dest org.gnome.Mutter.IdleMonitor \
         --object-path /org/gnome/Mutter/IdleMonitor/Core \
         --method org.gnome.Mutter.IdleMonitor.GetIdletime 2>/dev/null | grep -o '[0-9]\+')"
    case "$n" in
      ''|*[!0-9]*) ;;
      *) printf '%d\n' "$((n / 1000))"; return 0 ;;
    esac
  fi

  # KDE/Plasma: kscreen-doctor or qdbus
  if command -v qdbus >/dev/null 2>&1; then
    n="$(qdbus org.kde.screensaver /ScreenSaver GetRemainingTime 2>/dev/null)"
    case "$n" in
      ''|*[!0-9]*) ;;
      *) printf '%s\n' "$n"; return 0 ;;
    esac
  fi

  # Fallback: check /dev/input event timestamps (requires read access)
  if [ -r /dev/input ]; then
    local latest=0
    local dev
    for dev in /dev/input/event*; do
      [ -e "$dev" ] || continue
      local mtime
      mtime="$(stat -c %Y "$dev" 2>/dev/null || echo 0)"
      [ "$mtime" -gt "$latest" ] && latest="$mtime"
    done
    if [ "$latest" -gt 0 ]; then
      local now
      now="$(date +%s)"
      printf '%d\n' "$((now - latest))"
      return 0
    fi
  fi

  printf '999'
}

# --- Cross-platform player detection -----------------------------------------
# Returns the best available player: mpv > ffplay > vlc > quicktime (macOS only)
detect_player() {
  local preferred="${1:-$WAKEUP_PLAYER}"

  # If user explicitly set a player, try to use it
  if [ "$preferred" != "auto" ]; then
    case "$preferred" in
      quicktime)
        if [ "$OS" = "Darwin" ]; then return 0; fi
        log "QuickTime only available on macOS, falling back to auto-detect"
        ;;
      ffplay|mpv|vlc)
        if command -v "$preferred" >/dev/null 2>&1; then return 0; fi
        log "$preferred not found, falling back to auto-detect"
        ;;
    esac
  fi

  # Auto-detect best player
  if command -v mpv >/dev/null 2>&1; then
    WAKEUP_PLAYER="mpv"
  elif command -v ffplay >/dev/null 2>&1; then
    WAKEUP_PLAYER="ffplay"
  elif command -v vlc >/dev/null 2>&1; then
    WAKEUP_PLAYER="vlc"
  elif [ "$OS" = "Darwin" ]; then
    WAKEUP_PLAYER="quicktime"
  else
    WAKEUP_PLAYER=""
    log "WARN: no video player found (install mpv, ffplay, or vlc)"
  fi
}

# The video to play: WAKEUP_VIDEO if set, otherwise a random pick from the pool.
# Pool = local media/ files + API-cached videos (media/.cache/).
# API fetches happen in background to keep cache warm = zero latency at alarm time.
resolve_video() {
  if [ -n "$WAKEUP_VIDEO" ]; then
    if [ -f "$WAKEUP_VIDEO" ]; then
      printf '%s\n' "$WAKEUP_VIDEO"
      return 0
    else
      return 1
    fi
  fi

  local -a pool=()
  local f

  # 1. Gather local user-uploaded videos (media/*.mp4, *.webm, *.mov)
  for f in "$WAKEUP_MEME_DIR"/*.mp4 "$WAKEUP_MEME_DIR"/*.mov "$WAKEUP_MEME_DIR"/*.webm; do
    [ -f "$f" ] && pool+=("$f")
  done

  # 2. Gather API-cached videos (media/.cache/*.mp4, *.webm, *.mov)
  local cache_dir="$WAKEUP_MEME_DIR/.cache"
  if [ -d "$cache_dir" ]; then
    for f in "$cache_dir"/*.mp4 "$cache_dir"/*.webm "$cache_dir"/*.mov; do
      [ -f "$f" ] && pool+=("$f")
    done
  fi

  # 3. If API is configured and cache is empty, fetch one now (blocking, only on cold start)
  if [ ${#pool[@]} -eq 0 ] && [ -n "$WAKEUP_MEME_API" ]; then
    local fetched
    fetched="$("$WAKEUP_HOME/lib/meme-fetch.sh" 2>/dev/null)"
    if [ -n "$fetched" ] && [ -f "$fetched" ]; then
      pool+=("$fetched")
    fi
  fi

  # 4. Pick randomly from the combined pool
  if [ ${#pool[@]} -gt 0 ]; then
    printf '%s\n' "${pool[RANDOM % ${#pool[@]}]}"
    return 0
  fi

  return 1
}

# True if an alarm is already armed or playing.
lock_held() {
  [ -d "$WAKEUP_LOCK" ] || return 1
  local pid
  pid="$(cat "$WAKEUP_LOCK/pid" 2>/dev/null)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}
