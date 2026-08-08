# dev-meme-notifier

When any AI coding agent (Claude Code, Codex, OpenClaw, Hermes) completes your task — a funny meme/video pops up on screen so you know your work is done.

```
Agent task complete  →  wait 10s  →  still not back?  →  🎬 VIDEO/MEME
                                              ↘  you're typing?   →  stays quiet
```

## Features

- 🎬 Fullscreen video/meme popup with sound
- ⏱️ 10 sec grace period — if you're at the desk, it stays quiet
- ⌨️ Keyboard touch = instant close
- 🎲 Random video selection from media/ folder
- 🔧 MCP support (planned) — universal for all agents
- 🌐 Free meme API integration (planned)

## Install

```bash
git clone https://github.com/unknownsorcerer007/dev-meme-notifier.git
cd dev-meme-notifier
./install.sh          # or ./install.sh --project for this repo only
```

Then restart your agent — hooks are read when a session starts.

Needs `jq` and `ffplay` (`brew install jq ffmpeg`). Without `ffplay` it falls back to
QuickTime Player, which works fine and needs nothing installed.

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
| `WAKEUP_PLAYER` | `ffplay` | `ffplay` or `quicktime` |
| `WAKEUP_VOLUME` | *(empty)* | Force system volume 0–100 while playing, then restore it |
| `WAKEUP_LOOP` | `0` | `1` replays until you come back |
| `WAKEUP_MAX_SECS` | `120` | Hard cap on playback |
| `WAKEUP_RETURN_SECS` | `2` | Idle below this means you're back, so cut the alarm |
| `WAKEUP_LOG` | `~/.claude/wakeup.log` | Where decisions get logged |

### Your own videos

Drop any `.mp4` or `.mov` into `media/`. With more than one in there, each alarm picks
one at random.

## How it works

`wakeup.sh` is the hook your agent calls. It reads the event JSON on stdin, decides
whether it's one you care about, spawns a detached worker, and exits — in about 45ms.
It never blocks your session and never exits non-zero, so a broken config or a missing
video can't get in the way of your work.

`lib/play.sh` is the worker. It takes an atomic lock, waits out the grace period, checks
how long you've really been idle, plays, then watches idle time once a second so it can
kill the player the instant you're back.

## Tests

```bash
./tests/run-tests.sh      # logic only — fakes idle time, plays nothing, safe any time
./tests/live-test.sh      # really plays the video, then proves it stops when you return
./tests/live-test.sh --real   # no faking: walk away and see if it catches you
```

## License

MIT
