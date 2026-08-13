# dev-meme-notifier

When any AI coding agent (Claude Code, Codex, OpenClaw, Cursor, Hermes) completes your task — a funny meme/video pops up on screen so you know your work is done.

```
Agent task complete  →  wait 10s  →  still not back?  →  🎬 VIDEO/MEME
                                              ↘  you're typing?   →  stays quiet
```

## Features

- 🎬 Fullscreen video/meme popup with sound
- ⏱️ 10 sec grace period — if you're at the desk, it stays quiet
- ⌨️ Keyboard touch = instant close
- 🎲 Random video selection from media/ folder
- 🌐 **Cross-platform** — macOS + Linux (X11/Wayland)
- 🎮 **Multiple players** — mpv, ffplay, VLC, QuickTime (auto-detected)
- 🖼️ **Meme API integration** — auto-fetch dev memes from Reddit/imgflip when media/ is empty
- 🔌 **MCP server** — universal integration for any agent that supports MCP
- 🔊 Volume control (macOS + Linux via PulseAudio/ALSA)

## Quick Start

```bash
git clone https://github.com/unknownsorcerer007/dev-meme-notifier.git
cd dev-meme-notifier
./install.sh              # global: every agent session
./install.sh --project    # just this repo
./install.sh --mcp        # also set up MCP server
./install.sh --project --mcp  # both
```

Then restart your agent — hooks are read when a session starts.

### Dependencies

| Dependency | Required | Install |
|---|---|---|
| `jq` | ✅ yes | `brew install jq` / `apt install jq` |
| Video player | ✅ yes | `brew install mpv` / `apt install mpv` |
| Node.js ≥ 18 | MCP only | https://nodejs.org/ |

Undo it any time with `./uninstall.sh`. Both scripts back up your `settings.json` first
and leave every other setting and hook alone.

## When it wakes you

| Event | What happened |
|---|---|
| `permission_prompt` | Agent is blocked waiting for you to approve a tool |
| `idle_prompt` | Agent's own "still there?" nudge |
| `agent_needs_input` | Agent is asking you a question mid-task |
| `agent_completed` | A background agent finished |
| `stop` | Agent finished responding |

Every one of them goes through the same gate: **wait a bit, and only shout if you're
actually gone.** If you're sitting there typing, nothing happens.

## Configuration

Everything lives in [`config.env`](config.env). Edit it, save, restart your agent.

| Setting | Default | What it does |
|---|---|---|
| `WAKEUP_DELAY_SECS` | `10` | Grace period after agent asks for you |
| `WAKEUP_IDLE_SECS` | `10` | Only fire if you've been away at least this long |
| `WAKEUP_EVENTS` | all five | Which moments arm the alarm |
| `WAKEUP_VIDEO` | *(empty)* | A specific clip; empty picks a random one from `media/` |
| `WAKEUP_PLAYER` | `auto` | `auto`, `mpv`, `ffplay`, `vlc`, or `quicktime` |
| `WAKEUP_VOLUME` | *(empty)* | Force system volume 0–100 while playing, then restore it |
| `WAKEUP_LOOP` | `0` | `1` replays until you come back |
| `WAKEUP_MAX_SECS` | `120` | Hard cap on playback |
| `WAKEUP_RETURN_SECS` | `2` | Idle below this means you're back, so cut the alarm |
| `WAKEUP_LOG` | `~/.claude/wakeup.log` | Where decisions get logged |
| `WAKEUP_MEME_API` | *(empty)* | Meme source: `reddit`, `imgflip`, or `custom\|URL` |
| `WAKEUP_MEME_DIR` | `media/` | Where to find/store media files |

### Your own videos

Drop any `.mp4`, `.mov`, `.webm`, or `.gif` into `media/`. With more than one in there,
each alarm picks one at random. Your custom media is never deleted — meme API downloads
are cleaned up separately.

### Meme API

When `media/` has no files (or only API-cached files), the system can fetch fresh dev
memes automatically:

```bash
# In config.env:
WAKEUP_MEME_API="reddit"       # r/ProgrammerHumor, r/programmingmemes
WAKEUP_MEME_API="imgflip"      # imgflip.com top 100 memes
WAKEUP_MEME_API="custom|https://your-meme-api.com/random"
```

Fetched memes are cached in `media/` (max 10, oldest auto-deleted).

## Cross-Platform Support

### Idle Detection

| Platform | Method | Notes |
|---|---|---|
| macOS | `ioreg` (IOHIDSystem) | Built-in, no setup needed |
| Linux X11 | `xprintidle` | `apt install xprintidle` |
| Linux Wayland | `gdbus` (Mutter) | Works on GNOME; KDE uses `qdbus` |
| Linux fallback | `/dev/input` timestamps | Always available, less precise |

### Video Players

| Player | Platforms | Install |
|---|---|---|
| `mpv` | macOS, Linux | `brew install mpv` / `apt install mpv` |
| `ffplay` | macOS, Linux | Comes with ffmpeg |
| `vlc` | macOS, Linux | Install VLC, ensure `vlc` is in PATH |
| `quicktime` | macOS only | Built-in, no install needed |

Set `WAKEUP_PLAYER=auto` (default) to pick the best available, or choose one explicitly.

### Volume Control

| Platform | Method |
|---|---|
| macOS | `osascript` (built-in) |
| Linux | `pactl` (PulseAudio/PipeWire) or `amixer` (ALSA) |

## MCP Server (Universal Agent Support)

The MCP server lets **any** agent trigger alarms, list media, fetch memes, and manage
configuration — not just Claude Code.

### Setup

```bash
./install.sh --mcp     # installs Node.js dependencies

# Add to your agent's MCP config:
{
  "dev-meme-notifier": {
    "command": "node",
    "args": ["./mcp-server/server.js"]
  }
}
```

### Available Tools

| Tool | Description |
|---|---|
| `trigger_alarm` | Trigger a video/meme popup (any event type) |
| `trigger_alarm_dry` | Test what would happen without playing video |
| `list_media` | List available media files |
| `fetch_meme` | Fetch a fresh meme from Reddit/imgflip |
| `get_status` | Show current config, platform, player, media count |
| `set_config` | Update any config.env setting |
| `add_media` | Add a local file to the media library |

### SSE Mode (Remote Agents)

```bash
node mcp-server/server.js --port 3000
# MCP endpoint: http://localhost:3000/sse
```

## How it works

`wakeup.sh` is the hook your agent calls. It reads the event JSON on stdin, decides
whether it's one you care about, spawns a detached worker, and exits — in about 45ms.
It never blocks your session and never exits non-zero, so a broken config or a missing
video can't get in the way of your work.

`lib/play.sh` is the worker. It takes an atomic lock, waits out the grace period, checks
how long you've really been idle, plays, then watches idle time once a second so it can
kill the player the instant you're back.

`lib/meme-fetch.sh` handles API integration. When there's no local media, it fetches a
random dev meme from the configured source and caches it locally.

`mcp-server/server.js` exposes the whole system as an MCP server with 7 tools, usable
by any agent that speaks the Model Context Protocol.

## Tests

```bash
./tests/run-tests.sh      # logic only — fakes idle time, plays nothing, safe any time
./tests/live-test.sh      # really plays the video, then proves it stops when you return
./tests/live-test.sh --real   # no faking: walk away and see if it catches you
```

## License

MIT
