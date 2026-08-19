#!/usr/bin/env bash
# Auto-install dependencies. Shameless — just does what it needs to do.
# Detects package manager and installs: jq, ffmpeg (ffplay), xprintidle (Linux/X11).

DEPS_INSTALLED=()

# Check and install all required dependencies.
install_deps() {
  echo "checking dependencies..."
  echo

  _install_jq
  _install_ffmpeg
  _install_xprintidle
  _install_xdg_utils

  if [ ${#DEPS_INSTALLED[@]} -gt 0 ]; then
    echo
    echo "installed: ${DEPS_INSTALLED[*]}"
  fi
  echo
}

# Detect the system package manager.
_detect_pkg_manager() {
  if command -v brew >/dev/null 2>&1; then
    echo "brew"
  elif command -v apt-get >/dev/null 2>&1; then
    echo "apt"
  elif command -v dnf >/dev/null 2>&1; then
    echo "dnf"
  elif command -v yum >/dev/null 2>&1; then
    echo "yum"
  elif command -v pacman >/dev/null 2>&1; then
    echo "pacman"
  elif command -v zypper >/dev/null 2>&1; then
    echo "zypper"
  elif command -v apk >/dev/null 2>&1; then
    echo "apk"
  elif command -v choco >/dev/null 2>&1; then
    echo "choco"
  elif command -v winget >/dev/null 2>&1; then
    echo "winget"
  elif command -v scoop >/dev/null 2>&1; then
    echo "scoop"
  elif command -v pkg >/dev/null 2>&1; then
    echo "pkg"
  else
    echo "unknown"
  fi
}

# Install a package using the detected package manager.
_pkg_install() {
  local pkg="$1"
  local mgr
  mgr="$(_detect_pkg_manager)"

  echo "  installing $pkg (via $mgr)..."

  case "$mgr" in
    brew)    brew install "$pkg" ;;
    apt)     sudo apt-get update -qq && sudo apt-get install -y -qq "$pkg" ;;
    dnf)     sudo dnf install -y "$pkg" ;;
    yum)     sudo yum install -y "$pkg" ;;
    pacman)  sudo pacman -S --noconfirm "$pkg" ;;
    zypper)  sudo zypper install -y "$pkg" ;;
    apk)     sudo apk add "$pkg" ;;
    choco)   choco install "$pkg" -y ;;
    winget)  winget install "$pkg" --accept-package-agreements --accept-source-agreements ;;
    scoop)   scoop install "$pkg" ;;
    pkg)     pkg install "$pkg" ;;
    *)
      echo "  ✗ unknown package manager — please install '$pkg' manually"
      return 1
      ;;
  esac
}

# Map generic package names to distro-specific names.
_pkg_name_for_distro() {
  local generic="$1"
  local mgr
  mgr="$(_detect_pkg_manager)"

  case "$generic:$mgr" in
    ffmpeg:apt)     echo "ffmpeg" ;;
    ffmpeg:brew)    echo "ffmpeg" ;;
    ffmpeg:pacman)  echo "ffmpeg" ;;
    ffmpeg:dnf)     echo "ffmpeg" ;;
    ffmpeg:choco)   echo "ffmpeg" ;;
    ffmpeg:winget)  echo "FFmpeg" ;;
    xprintidle:apt) echo "xprintidle" ;;
    xprintidle:*)   echo "xprintidle" ;;
    xdg-utils:apt)  echo "xdg-utils" ;;
    xdg-utils:*)    echo "xdg-utils" ;;
    *)              echo "$generic" ;;
  esac
}

_install_jq() {
  if command -v jq >/dev/null 2>&1; then
    echo "  ✓ jq $(jq --version 2>/dev/null | head -1)"
    return
  fi

  local pkg
  pkg="$(_pkg_name_for_distro jq)"
  if _pkg_install "$pkg"; then
    DEPS_INSTALLED+=("jq")
    echo "  ✓ jq installed"
  else
    echo "  ✗ jq — REQUIRED, install manually"
  fi
}

_install_ffmpeg() {
  if command -v ffplay >/dev/null 2>&1; then
    echo "  ✓ ffplay available"
    return
  fi
  if command -v ffplay.exe >/dev/null 2>&1; then
    echo "  ✓ ffplay.exe available"
    return
  fi
  # Not a hard requirement — player.sh falls back to mpv, vlc, etc.
  if [ "$WAKEUP_OS" = "macos" ]; then
    echo "  ⚠ ffplay not found (optional — QuickTime fallback available)"
    return
  fi

  local pkg
  pkg="$(_pkg_name_for_distro ffmpeg)"
  echo "  ⚠ ffplay not found — installing ffmpeg (includes ffplay)..."
  if _pkg_install "$pkg"; then
    DEPS_INSTALLED+=("ffmpeg")
    echo "  ✓ ffmpeg installed"
  else
    echo "  ⚠ ffmpeg install failed — will try other players (mpv, vlc)"
  fi
}

_install_xprintidle() {
  # Only needed on Linux with X11 (or XWayland)
  if [ "$WAKEUP_OS" != "linux" ]; then
    return
  fi

  if command -v xprintidle >/dev/null 2>&1; then
    echo "  ✓ xprintidle available"
    return
  fi

  # Check if we have an X11 display (including XWayland on Wayland)
  if [ -z "${DISPLAY:-}" ]; then
    echo "  ⚠ no X11 display — skipping xprintidle (Wayland idle uses fallback)"
    return
  fi

  local pkg
  pkg="$(_pkg_name_for_distro xprintidle)"
  echo "  ⚠ xprintidle not found — installing for idle detection..."
  if _pkg_install "$pkg"; then
    DEPS_INSTALLED+=("xprintidle")
    echo "  ✓ xprintidle installed"
  else
    echo "  ⚠ xprintidle install failed — idle detection will use fallback"
  fi
}

_install_xdg_utils() {
  if [ "$WAKEUP_OS" != "linux" ]; then
    return
  fi

  if command -v xdg-open >/dev/null 2>&1; then
    echo "  ✓ xdg-utils available"
    return
  fi

  local pkg
  pkg="$(_pkg_name_for_distro xdg-utils)"
  if _pkg_install "$pkg" 2>/dev/null; then
    DEPS_INSTALLED+=("xdg-utils")
    echo "  ✓ xdg-utils installed"
  fi
}
