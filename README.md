# claude-code-wakeup-alarm

You give your coding agent a long task. You pick up your phone. Twenty minutes later you look
back at your laptop and it's been sitting on a permission prompt for nineteen of them.

This fixes that. When your agent needs you, it plays a video at you — fullscreen, with
sound — and stops the moment you touch the keyboard.

**Works with:** Claude Code, OpenAI Codex, Hermes, Goose, Aider — any agent that supports hooks.

**Works on:** macOS, Linux (X11/Wayland), Windows (Git Bash/MSYS2/WSL).

```
Agent needs permission  →  wait 10s  →  still not back?  →  🔊 VIDEO
                                   ↘  you're typing?   →  stays quiet
```

## Install

```bash
git clone https://github.com/rafcopy/claude-code-wakeup-alarm.git
cd claude-code-wakeup-alarm
./install.sh          # auto-detects agents, installs deps
```

Options:
```bash
./install.sh --project              # this repo only
./install.sh --agent claude         # specific agent only
./install.sh --agent claude --agent codex  # multiple agents
```

The installer:
- **Auto-detects** which coding agents are installed (Claude Code, Codex, Hermes, Goose, Aider)
- **Auto-installs** dependencies (`jq`, `ffmpeg`, `xprintidle`) via your system package manager (brew, apt, dnf, yum, pacman, choco, winget, scoop, etc.)
- **Auto-detects** the best media player (ffplay > mpv > vlc > platform default)
- Backs up your settings before modifying them
- Is safe to run repeatedly (idempotent)

Then restart your agent — hooks are read when a session starts.

Undo it any time with `./uninstall.sh`.

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
| `WAKEUP_PLAYER` | `auto` | `auto`, `ffplay`, `mpv`, `vlc`, `quicktime`, `xdg-open`, `wmplayer` |
| `WAKEUP_VOLUME` | *(empty)* | Force system volume 0–100 while playing, then restore it |
| `WAKEUP_LOOP` | `0` | `1` replays until you come back |
| `WAKEUP_MAX_SECS` | `120` | Hard cap on playback |
| `WAKEUP_RETURN_SECS` | `2` | Idle below this means you're back, so cut the alarm |
| `WAKEUP_LOG` | `~/.claude/wakeup.log` | Where decisions get logged |

### Your own videos

Drop any `.mp4`, `.mov`, `.avi`, `.mkv`, or `.webm` into `media/`. With more than one in
there, each alarm picks one at random.

**⚠️ Video only.** GIFs, images (png/jpg/webp), and other non-video files are ignored.
The alarm plays fullscreen video with sound — that's what gets your attention.

## Supported Agents

| Agent | Config Location | Hook Format |
|---|---|---|
| Claude Code | `~/.claude/settings.json` | JSON hooks (Notification, Stop) |
| OpenAI Codex | `~/.codex/config.toml` | TOML hooks |
| Hermes | `~/.hermes/config.toml` | TOML hooks |
| Goose | `~/.goose/config.yaml` | YAML hooks |
| Aider | `~/.aider.conf.yml` | YAML hooks |

## Supported Platforms

| OS | Idle Detection | Players |
|---|---|---|
| macOS | `IOHIDSystem` (ioreg) | ffplay, mpv, QuickTime |
| Linux (X11) | `xprintidle` / `xssstate` | ffplay, mpv, vlc, xdg-open |
| Linux (Wayland) | `/proc` input events | ffplay, mpv, vlc |
| Windows | `GetLastInputInfo` (P/Invoke) | ffplay, mpv, Windows Media Player |

## How it works

`wakeup.sh` is the hook the agent calls. It reads the event JSON on stdin, normalizes
it across different agent formats, decides whether it's one you care about, spawns a
detached worker, and exits — in about 45ms. It never blocks your session and never exits
non-zero.

`lib/play.sh` is the worker. It takes an atomic lock, waits out the grace period, checks
how long you've really been idle, plays, then watches idle time once a second so it can
kill the player the instant you're back.

`lib/platform.sh` handles cross-platform idle detection (macOS/Linux/Windows).

`lib/player.sh` auto-detects and abstracts media players across platforms.

`lib/agents.sh` handles multi-agent config injection (JSON/TOML/YAML).

`lib/deps.sh` auto-installs system dependencies via the detected package manager.

## Tests

```bash
./tests/run-tests.sh      # logic only — fakes idle time, plays nothing, safe any time
./tests/live-test.sh      # really plays the video, then proves it stops when you return
./tests/live-test.sh --real   # no faking: walk away and see if it catches you
```

## Troubleshooting

**Nothing happens.** Check `~/.claude/wakeup.log` — it records every decision. If the
log is empty, the hooks aren't installed: run `./install.sh` and restart your agent.

**Wrong agent detected.** Use `./install.sh --agent claude` to target a specific agent.

**No player found.** Install `ffmpeg` (includes ffplay) or `mpv`. The installer tries
to do this automatically.

**Linux idle detection not working.** Install `xprintidle` (for X11). The installer
tries this automatically. On Wayland, detection uses `/proc` input events as a fallback.
