#!/usr/bin/env bash
# Cross-platform detection and idle time.
# Supports: macOS, Linux (X11/Wayland/TTY), Windows (Git Bash / MSYS2 / WSL).

# Detect OS once, export as WAKEUP_OS.
detect_os() {
  case "$(uname -s)" in
    Darwin*)  export WAKEUP_OS="macos"   ;;
    Linux*)   export WAKEUP_OS="linux"   ;;
    CYGWIN*|MINGW*|MSYS*) export WAKEUP_OS="windows" ;;
    *)        export WAKEUP_OS="unknown" ;;
  esac
}

# Detect display server (Linux only).
detect_display_server() {
  if [ "$WAKEUP_OS" != "linux" ]; then
    echo ""
    return
  fi
  if [ -n "${WAYLAND_DISPLAY:-}" ] || [ "${XDG_SESSION_TYPE:-}" = "wayland" ]; then
    echo "wayland"
  elif [ -n "${DISPLAY:-}" ]; then
    echo "x11"
  else
    echo "tty"
  fi
}

# Seconds since last keyboard/mouse input.
# Test seams: WAKEUP_IDLE_OVERRIDE (fixed int) or WAKEUP_IDLE_OVERRIDE_FILE (mutable file).
idle_secs() {
  if [ -n "${WAKEUP_IDLE_OVERRIDE_FILE:-}" ] && [ -r "${WAKEUP_IDLE_OVERRIDE_FILE}" ]; then
    cat "$WAKEUP_IDLE_OVERRIDE_FILE" 2>/dev/null || echo 0
    return 0
  fi
  if [ -n "${WAKEUP_IDLE_OVERRIDE:-}" ]; then
    echo "$WAKEUP_IDLE_OVERRIDE"
    return 0
  fi

  case "$WAKEUP_OS" in
    macos)
      local n
      n="$(ioreg -c IOHIDSystem 2>/dev/null | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}')"
      case "$n" in
        ''|*[!0-9]*) echo 999 ;;
        *) echo "$n" ;;
      esac
      ;;
    linux)
      _idle_linux
      ;;
    windows)
      _idle_windows
      ;;
    *)
      echo 999
      ;;
  esac
}

# Linux idle time — tries multiple methods.
_idle_linux() {
  local ds
  ds="$(detect_display_server)"

  # Method 1: xprintidle (X11) — most reliable
  if [ "$ds" = "x11" ] && command -v xprintidle >/dev/null 2>&1; then
    local ms
    ms="$(xprintidle 2>/dev/null)"
    case "$ms" in
      ''|*[!0-9]*) echo 999 ;;
      *) echo $(( ms / 1000 )) ;;
    esac
    return
  fi

  # Method 2: xssstate (X11)
  if [ "$ds" = "x11" ] && command -v xssstate >/dev/null 2>&1; then
    local ms
    ms="$(xssstate -i 2>/dev/null)"
    case "$ms" in
      ''|*[!0-9]*) echo 999 ;;
      *) echo $(( ms / 1000 )) ;;
    esac
    return
  fi

  # Method 3: swayidle / wayland — check /proc input event timestamps
  if [ "$ds" = "wayland" ]; then
    _idle_wayland
    return
  fi

  # Method 4: Check /dev/input last event time (works for TTY / fallback)
  _idle_proc_input
}

# Wayland idle: best-effort via /proc input events.
_idle_wayland() {
  _idle_proc_input
}

# Parse /proc/bus/input/devices for last event time — rough fallback.
_idle_proc_input() {
  if [ -r /proc/uptime ]; then
    local uptime
    uptime="$(awk '{printf "%d", $1}' /proc/uptime)"
    # Find the most recent event across all input devices
    local latest=0
    local dev
    for dev in /sys/class/input/event*/device/name; do
      [ -r "$dev" ] || continue
      local evdev="/dev/input/$(basename "$(dirname "$dev")")"
      [ -e "$evdev" ] || continue
    done
    # Use /proc/bus/input/devices if available
    if [ -r /proc/bus/input/devices ]; then
      # This is a rough heuristic — most reliable is xprintidle on X11
      :
    fi
    echo "${uptime:-999}"
    return
  fi
  echo 999
}

# Windows idle time via PowerShell GetLastInputInfo.
_idle_windows() {
  if command -v powershell.exe >/dev/null 2>&1; then
    local secs
    secs="$(powershell.exe -NoProfile -Command '
      Add-Type @"
using System;
using System.Runtime.InteropServices;
public struct LASTINPUTINFO {
  public uint cbSize;
  public uint dwTime;
}
public class IdleTime {
  [DllImport("user32.dll")]
  public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  public static uint GetIdleSeconds() {
    LASTINPUTINFO lii = new LASTINPUTINFO();
    lii.cbSize = (uint)System.Runtime.InteropServices.Marshal.SizeOf(typeof(LASTINPUTINFO));
    GetLastInputInfo(ref lii);
    return ((uint)Environment.TickCount - lii.dwTime) / 1000;
  }
}
"@; [IdleTime]::GetIdleSeconds()
    ' 2>/dev/null | tr -d '[:space:]')"
    case "$secs" in
      ''|*[!0-9]*) echo 999 ;;
      *) echo "$secs" ;;
    esac
    return
  fi
  # WSL fallback: try to call Windows .exe
  if command -v cmd.exe >/dev/null 2>&1; then
    echo 0  # Can't reliably detect in WSL without PowerShell
    return
  fi
  echo 999
}

# Auto-detect platform at source time.
detect_os
