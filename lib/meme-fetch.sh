#!/usr/bin/env bash
# Fetch a random dev MEME VIDEO from an API and cache it locally.
# Called by resolve_video() — always picks from cache first (zero latency).
#
# Supported sources:
#   reddit    - r/ProgrammerHumor .mp4/.webm posts (optional OAuth)
#   imgflip   - imgflip.com (images only, no video — falls back gracefully)
#   giphy     - giphy.com .mp4 GIFs (API key required)
#   tenor     - tenor.com .mp4 (API key required)
#   custom    - any URL that returns a list of video URLs or raw .mp4
#
# Strategy: pre-fetch into cache, always pick from cache at alarm time = zero latency.

set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CACHE_DIR="${WAKEUP_MEME_DIR:-$WAKEUP_HOME/media}/.cache"
mkdir -p "$CACHE_DIR" 2>/dev/null

API="${WAKEUP_MEME_API:-}"
[ -n "$API" ] || { log "meme-fetch: no API configured"; exit 1; }

# How many cached videos to keep ready
CACHE_TARGET="${WAKEUP_MEME_CACHE_SIZE:-5}"

# Curl with sane defaults
fetch_url() {
  curl -fsSL --max-time 10 --retry 1 -o "$1" "$2" 2>/dev/null
}

# Verify file is actually a video (not an HTML error page)
is_video() {
  local f="$1"
  [ -f "$f" ] && [ "$(wc -c < "$f")" -gt 10000 ] || return 1
  # Check magic bytes or extension
  case "$f" in
    *.mp4|*.webm|*.mov) return 0 ;;
  esac
  # Check first bytes for video container signatures
  local header
  header="$(xxd -l 12 -p "$f" 2>/dev/null)"
  case "$header" in
    000000*66747970*) return 0 ;;  # MP4/moov
    1a45dfa3*)       return 0 ;;  # WebM/MKV
    *)               return 1 ;;
  esac
}

# --- Reddit OAuth (optional) ---
REDDIT_ACCESS_TOKEN=""

reddit_auth() {
  [ -n "$WAKEUP_REDDIT_CLIENT_ID" ] && [ -n "$WAKEUP_REDDIT_CLIENT_SECRET" ] || return 1
  [ -n "$WAKEUP_REDDIT_USERNAME" ] && [ -n "$WAKEUP_REDDIT_PASSWORD" ] || return 1

  local resp
  resp="$(curl -fsSL --max-time 8 \
    -u "${WAKEUP_REDDIT_CLIENT_ID}:${WAKEUP_REDDIT_CLIENT_SECRET}" \
    -d "grant_type=password&username=${WAKEUP_REDDIT_USERNAME}&password=${WAKE…ORD}" \
    -H "User-Agent: dev-meme-notifier/1.0" \
    "https://www.reddit.com/api/v1/access_token" 2>/dev/null)"

  REDDIT_ACCESS_TOKEN="$(printf '%s' "$resp" | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)"
  [ -n "$REDDIT_ACCESS_TOKEN" ]
}

fetch_reddit() {
  local subreddits=("ProgrammerHumor" "programmingmemes" "ProgrammerAnimemes")
  local sub="${subreddits[RANDOM % ${#subreddits[@]}]}"
  local json

  if reddit_auth; then
    json="$(curl -fsSL --max-time 10 \
      -H "Authorization: Bearer $REDDIT_ACCESS_TOKEN" \
      -H "User-Agent: dev-meme-notifier/1.0" \
      "https://oauth.reddit.com/r/${sub}/hot?limit=100" 2>/dev/null)"
  else
    json="$(curl -fsSL --max-time 10 \
      -A "dev-meme-notifier/1.0" \
      "https://www.reddit.com/r/${sub}/hot.json?limit=100" 2>/dev/null)"
  fi

  [ -n "$json" ] || { log "meme-fetch: reddit request failed"; return 1; }

  # Extract VIDEO URLs only (.mp4, .webm)
  local -a urls=()
  while IFS= read -r line; do
    urls+=("$line")
  done < <(printf '%s' "$json" | grep -oE '"url":\s*"https?://[^"]+\.(mp4|webm)"' \
    | grep -oE 'https?://[^"]+' | head -30)

  # Also grab Reddit's pre-rendered video (v.redd.it links have mp4)
  while IFS= read -r line; do
    urls+=("$line")
  done < <(printf '%s' "$json" | grep -oE '"fallback_url":"https?://v\.redd\.it/[^"]+\.mp4"' \
    | grep -oE 'https?://[^"]+' | head -20)

  [ ${#urls[@]} -gt 0 ] || { log "meme-fetch: no video URLs in reddit response"; return 1; }

  local pick="${urls[RANDOM % ${#urls[@]}]}"
  local out="$CACHE_DIR/reddit-$(date +%s)-${RANDOM}.mp4"

  if fetch_url "$out" "$pick" && is_video "$out"; then
    log "meme-fetch: downloaded video from r/$sub → $out"
    printf '%s\n' "$out"
    return 0
  fi
  rm -f "$out"
  log "meme-fetch: download/verify failed for $pick"
  return 1
}

# Fetch from Giphy (mp4 format, API key required)
fetch_giphy() {
  [ -n "$WAKEUP_GIPHY_API_KEY" ] || { log "meme-fetch: GIPHY_API_KEY not set"; return 1; }

  local endpoints=(
    "https://api.giphy.com/v1/gifs/trending?api_key=${WAKE…KEY}&limit=50&rating=pg-13"
    "https://api.giphy.com/v1/gifs/random?api_key=${WAKE…KEY}&rating=pg-13"
  )

  for url in "${endpoints[@]}"; do
    local json
    json="$(curl -fsSL --max-time 10 "$url" 2>/dev/null)"
    [ -n "$json" ] || continue

    # Giphy returns mp4 URLs in the images.downsized_medium or images.mp4 fields
    local -a mp4s=()
    while IFS= read -r line; do
      mp4s+=("$line")
    done < <(printf '%s' "$json" | grep -oE '"mp4":"https?://[^"]+"' | grep -oE 'https?://[^"]+' | shuf)

    [ ${#mp4s[@]} -gt 0 ] || continue

    for pick in "${mp4s[@]}"; do
      local out="$CACHE_DIR/giphy-$(date +%s)-${RANDOM}.mp4"
      if fetch_url "$out" "$pick" && is_video "$out"; then
        log "meme-fetch: downloaded video from giphy → $out"
        printf '%s\n' "$out"
        return 0
      fi
      rm -f "$out"
    done
  done

  log "meme-fetch: giphy fetch failed"
  return 1
}

# Fetch from Tenor (mp4 format, API key required)
fetch_tenor() {
  [ -n "$WAKEUP_TENOR_API_KEY" ] || { log "meme-fetch: TENOR_API_KEY not set"; return 1; }

  local json
  json="$(curl -fsSL --max-time 10 \
    "https://tenor.googleapis.com/v2/featured?key=${WAKE…KEY}&limit=50&media_filter=mp4&contentfilter=medium" 2>/dev/null)"
  [ -n "$json" ] || { log "meme-fetch: tenor request failed"; return 1; }

  local -a mp4s=()
  while IFS= read -r line; do
    mp4s+=("$line")
  done < <(printf '%s' "$json" | grep -oE '"url":"[^"]+\.mp4"' | grep -oE 'https?://[^"]+' | shuf)

  [ ${#mp4s[@]} -gt 0 ] || { log "meme-fetch: no mp4 in tenor response"; return 1; }

  for pick in "${mp4s[@]}"; do
    local out="$CACHE_DIR/tenor-$(date +%s)-${RANDOM}.mp4"
    if fetch_url "$out" "$pick" && is_video "$out"; then
      log "meme-fetch: downloaded video from tenor → $out"
      printf '%s\n' "$out"
      return 0
    fi
    rm -f "$out"
  done

  log "meme-fetch: tenor download failed"
  return 1
}

# Fetch from imgflip (NOTE: imgflip is images-only, no video)
# Returns empty — will be skipped in favor of video sources
fetch_imgflip() {
  log "meme-fetch: imgflip is image-only, skipping (need video for alarm)"
  return 1
}

# Fetch from custom URL
# Expected: endpoint returns one video URL per line, or redirects to .mp4
fetch_custom() {
  local url="${API#custom|}"
  [ -n "$url" ] || { log "meme-fetch: custom URL missing"; return 1; }

  local response
  response="$(curl -fsSL --max-time 10 "$url" 2>/dev/null)"

  # If response is a direct video URL
  if printf '%s' "$response" | grep -qE '^https?://.+\.(mp4|webm|mov)'; then
    local media_url="$(printf '%s' "$response" | head -1)"
    local out="$CACHE_DIR/custom-$(date +%s)-${RANDOM}.mp4"
    if fetch_url "$out" "$media_url" && is_video "$out"; then
      log "meme-fetch: downloaded video from custom API → $out"
      printf '%s\n' "$out"
      return 0
    fi
    rm -f "$out"
  fi

  # If response is raw video data (Content-Type: video/*)
  if [ -n "$response" ] && [ "$(printf '%s' "$response" | wc -c)" -gt 10000 ]; then
    local out="$CACHE_DIR/custom-$(date +%s)-${RANDOM}.mp4"
    printf '%s' "$response" > "$out"
    if is_video "$out"; then
      log "meme-fetch: saved raw video from custom API → $out"
      printf '%s\n' "$out"
      return 0
    fi
    rm -f "$out"
  fi

  log "meme-fetch: custom API returned no video"
  return 1
}

# Clean up old cached videos (keep last CACHE_TARGET * 2)
cleanup_cache() {
  local count
  count="$(find "$CACHE_DIR" -maxdepth 1 -type f -name '*.mp4' -o -name '*.webm' -o -name '*.mov' 2>/dev/null | wc -l)"
  local max=$((CACHE_TARGET * 2))
  if [ "$count" -gt "$max" ]; then
    find "$CACHE_DIR" -maxdepth 1 \( -name '*.mp4' -o -name '*.webm' -o -name '*.mov' \) -type f -printf '%T+ %p\n' 2>/dev/null \
      | sort | head -n "$((count - max))" | awk '{print $2}' | xargs rm -f 2>/dev/null
  fi
}

# Pre-fetch: fill cache up to CACHE_TARGET videos
prefetch() {
  local current
  current="$(find "$CACHE_DIR" -maxdepth 1 \( -name '*.mp4' -o -name '*.webm' -o -name '*.mov' \) -type f 2>/dev/null | wc -l)"

  while [ "$current" -lt "$CACHE_TARGET" ]; do
    log "meme-fetch: pre-fetching ($current/$CACHE_TARGET cached)"
    case "$API" in
      reddit)   fetch_reddit  >/dev/null 2>&1 ;;
      imgflip)  fetch_imgflip >/dev/null 2>&1 ;;
      giphy)    fetch_giphy   >/dev/null 2>&1 ;;
      tenor)    fetch_tenor   >/dev/null 2>&1 ;;
      custom|*) fetch_custom  >/dev/null 2>&1 ;;
    esac
    current="$(find "$CACHE_DIR" -maxdepth 1 \( -name '*.mp4' -o -name '*.webm' -o -name '*.mov' \) -type f 2>/dev/null | wc -l)"
    # Safety: break if fetch keeps failing
    [ "$current" -gt 0 ] || break
  done
}

# Pick one random video from cache (zero latency)
pick_from_cache() {
  local -a cached=()
  local f
  for f in "$CACHE_DIR"/*.mp4 "$CACHE_DIR"/*.webm "$CACHE_DIR"/*.mov; do
    [ -f "$f" ] && cached+=("$f")
  done
  [ ${#cached[@]} -gt 0 ] || return 1
  printf '%s\n' "${cached[RANDOM % ${#cached[@]}]}"
}

# --- main ---
# 1. Try cache first (zero latency)
if result="$(pick_from_cache)"; then
  printf '%s\n' "$result"
  # Background: refill cache for next time
  ( prefetch >/dev/null 2>&1 & ) >/dev/null 2>&1
  exit 0
fi

# 2. Cache empty — fetch one now, then prefill
case "$API" in
  reddit)   result="$(fetch_reddit)" ;;
  imgflip)  result="$(fetch_imgflip)" ;;
  giphy)    result="$(fetch_giphy)" ;;
  tenor)    result="$(fetch_tenor)" ;;
  custom|*) result="$(fetch_custom)" ;;
  *)        log "meme-fetch: unknown API '$API'"; exit 1 ;;
esac

if [ -n "$result" ] && [ -f "$result" ]; then
  printf '%s\n' "$result"
  # Background: prefill cache
  ( prefetch >/dev/null 2>&1 & ) >/dev/null 2>&1
  exit 0
fi

# 3. Nothing fetched
cleanup_cache
exit 1
