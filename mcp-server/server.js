#!/usr/bin/env node
/**
 * dev-meme-notifier MCP Server
 *
 * Exposes the alarm system as MCP tools so ANY agent (Claude Code, Codex, OpenClaw,
 * Cursor, Hermes, etc.) can trigger notifications, list media, and manage config.
 *
 * Usage:
 *   node server.js              # stdio transport (default for MCP)
 *   node server.js --port 3000  # SSE transport (for remote agents)
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { SSEServerTransport } from "@modelcontextprotocol/sdk/server/sse.js";
import { z } from "zod";
import { execSync, spawn } from "child_process";
import { readdir, stat, access } from "fs/promises";
import { copyFileSync, existsSync } from "fs";
import { join, resolve, dirname, extname } from "path";
import { fileURLToPath } from "url";
import { createServer } from "http";
import { readFileSync, writeFileSync } from "fs";

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = resolve(__dirname, "..");
const CONFIG_PATH = join(PROJECT_ROOT, "config.env");
const MEDIA_DIR = join(PROJECT_ROOT, "media");
const WAKEUP_SCRIPT = join(PROJECT_ROOT, "wakeup.sh");

const VIDEO_EXTENSIONS = [".mp4", ".mov", ".avi", ".mkv", ".webm"];

// --- Helpers ---

function runScript(script, args = [], env = {}) {
  try {
    return execSync(`bash "${script}" ${args.join(" ")}`, {
      env: { ...process.env, ...env },
      cwd: PROJECT_ROOT,
      timeout: 30000,
      encoding: "utf-8",
    }).trim();
  } catch (err) {
    return err.stdout?.trim() || err.message;
  }
}

function readConfig() {
  try {
    const content = readFileSync(CONFIG_PATH, "utf-8");
    const config = {};
    for (const line of content.split("\n")) {
      const match = line.match(/^([A-Z_]+)=["']?(.*?)["']?\s*$/);
      if (match) config[match[1]] = match[2];
    }
    return config;
  } catch {
    return {};
  }
}

function updateConfig(key, value) {
  try {
    let content = readFileSync(CONFIG_PATH, "utf-8");
    const regex = new RegExp(`^${key}=.*$`, "m");
    const newLine = `${key}="${value}"`;
    if (regex.test(content)) {
      content = content.replace(regex, newLine);
    } else {
      content += `\n${newLine}\n`;
    }
    writeFileSync(CONFIG_PATH, content);
    return true;
  } catch {
    return false;
  }
}

function isVideoFile(filename) {
  return VIDEO_EXTENSIONS.includes(extname(filename).toLowerCase());
}

// --- MCP Server ---

const server = new McpServer({
  name: "dev-meme-notifier",
  version: "1.0.0",
});

// Tool: trigger_alarm — Manually trigger an alarm notification
server.tool(
  "trigger_alarm",
  "Trigger a fullscreen video alarm popup. Use this to notify the user that their task is complete or that you need their attention. Only plays video files (mp4/mov/avi/mkv/webm).",
  {
    event: z
      .enum([
        "stop",
        "permission_prompt",
        "idle_prompt",
        "agent_needs_input",
        "agent_completed",
      ])
      .default("agent_completed")
      .describe("The event type that triggered the alarm"),
    message: z
      .string()
      .optional()
      .describe("Optional message to include in the notification"),
  },
  async ({ event, message }) => {
    const payload = JSON.stringify({
      session_id: `mcp-${Date.now()}`,
      cwd: process.cwd(),
      hook_event_name: event === "stop" ? "Stop" : "Notification",
      notification_type: event === "stop" ? undefined : event,
      message: message || `Agent notification: ${event}`,
      ...(event === "stop" ? { stop_hook_active: false } : {}),
    });

    try {
      const child = spawn("bash", [WAKEUP_SCRIPT], {
        stdio: ["pipe", "pipe", "pipe"],
        env: { ...process.env, WAKEUP_DRY_RUN: "0" },
        detached: true,
      });
      child.stdin.write(payload);
      child.stdin.end();
      child.unref();

      return {
        content: [
          {
            type: "text",
            text: `✅ Alarm triggered (event: ${event}). The video popup will appear after the grace period if you're away from the keyboard.`,
          },
        ],
      };
    } catch (err) {
      return {
        content: [
          { type: "text", text: `❌ Failed to trigger alarm: ${err.message}` },
        ],
      };
    }
  }
);

// Tool: trigger_alarm_dry — Test alarm without actually playing video
server.tool(
  "trigger_alarm_dry",
  "Test the alarm system without actually playing any video. Returns what WOULD happen.",
  {
    event: z
      .enum([
        "stop",
        "permission_prompt",
        "idle_prompt",
        "agent_needs_input",
        "agent_completed",
      ])
      .default("agent_completed")
      .describe("The event type to simulate"),
  },
  async ({ event }) => {
    const payload = JSON.stringify({
      session_id: `mcp-dry-${Date.now()}`,
      cwd: process.cwd(),
      hook_event_name: event === "stop" ? "Stop" : "Notification",
      notification_type: event === "stop" ? undefined : event,
      message: `Dry run: ${event}`,
      ...(event === "stop" ? { stop_hook_active: false } : {}),
    });

    const result = runScript(WAKEUP_SCRIPT, [], {
      WAKEUP_DRY_RUN: "1",
    });

    return {
      content: [
        {
          type: "text",
          text: `🧪 Dry run result for "${event}":\n\nStdout: ${result || "(empty)"}\n\nNo video was played. Check logs for details.`,
        },
      ],
    };
  }
);

// Tool: list_media — List all available video files
server.tool(
  "list_media",
  "List all video files available in the media/ folder. Only video formats (mp4/mov/avi/mkv/webm) are supported — no images or gifs.",
  {},
  async () => {
    try {
      const files = await readdir(MEDIA_DIR);
      const mediaFiles = files.filter((f) => isVideoFile(f));

      const details = await Promise.all(
        mediaFiles.map(async (f) => {
          const s = await stat(join(MEDIA_DIR, f));
          return `  • ${f} (${(s.size / 1024 / 1024).toFixed(1)} MB)`;
        })
      );

      return {
        content: [
          {
            type: "text",
            text:
              mediaFiles.length > 0
                ? `🎬 Available video files (${mediaFiles.length}):\n\n${details.join("\n")}`
                : "📂 No video files found in media/. Drop .mp4/.mov/.webm files into media/ for custom alarms.",
          },
        ],
      };
    } catch (err) {
      return {
        content: [
          { type: "text", text: `❌ Error listing media: ${err.message}` },
        ],
      };
    }
  }
);

// Tool: get_status — Get current alarm system status
server.tool(
  "get_status",
  "Get the current status of the alarm system, including configuration, available media, platform, and lock state.",
  {},
  async () => {
    const config = readConfig();

    let mediaCount = 0;
    try {
      const files = await readdir(MEDIA_DIR);
      mediaCount = files.filter((f) => isVideoFile(f)).length;
    } catch {}

    const lockDir = config.WAKEUP_LOCK || "/tmp/claude-wakeup.lock";
    let lockStatus = "inactive";
    try {
      await access(lockDir);
      lockStatus = "ACTIVE (alarm in progress)";
    } catch {
      lockStatus = "inactive (no alarm playing)";
    }

    // Detect available players
    const players = [];
    for (const p of ["mpv", "ffplay", "vlc"]) {
      try {
        execSync(`command -v ${p}`, { encoding: "utf-8" });
        players.push(p);
      } catch {}
    }
    if (process.platform === "darwin") players.push("quicktime (macOS)");

    // Detect idle method
    let idleMethod = "unknown";
    try {
      execSync("command -v xprintidle", { encoding: "utf-8" });
      idleMethod = "xprintidle (X11)";
    } catch {
      if (process.platform === "darwin") idleMethod = "ioreg (macOS HID)";
      else if (process.platform === "win32") idleMethod = "GetLastInputInfo (Windows)";
      else idleMethod = "fallback (/dev/input)";
    }

    return {
      content: [
        {
          type: "text",
          text: [
            "📊 dev-meme-notifier Status",
            "",
            "⚙️  Configuration:",
            `  Delay: ${config.WAKEUP_DELAY_SECS || 10}s`,
            `  Idle threshold: ${config.WAKEUP_IDLE_SECS || 10}s`,
            `  Max play time: ${config.WAKEUP_MAX_SECS || 120}s`,
            `  Loop mode: ${config.WAKEUP_LOOP || "0"}`,
            `  Player: ${config.WAKEUP_PLAYER || "auto"}`,
            `  Volume: ${config.WAKEUP_VOLUME || "(not set)"}`,
            "",
            "🎬 Media:",
            `  Video files available: ${mediaCount}`,
            `  Location: ${MEDIA_DIR}`,
            "  Format: video only (mp4/mov/avi/mkv/webm)",
            "",
            "🔒 Lock state:",
            `  ${lockStatus}`,
            "",
            `🖥️  Platform: ${process.platform} (${process.arch})`,
            `🎮 Available players: ${players.join(", ") || "none"}`,
            `⌨️  Idle detection: ${idleMethod}`,
            "",
            `📝 Events: ${config.WAKEUP_EVENTS || "all"}`,
          ].join("\n"),
        },
      ],
    };
  }
);

// Tool: set_config — Update a configuration value
server.tool(
  "set_config",
  "Update a configuration setting. Changes take effect on next alarm.",
  {
    key: z
      .string()
      .describe(
        "Config key to update (e.g., WAKEUP_DELAY_SECS, WAKEUP_PLAYER, WAKEUP_EVENTS)"
      ),
    value: z.string().describe("New value for the config key"),
  },
  async ({ key, value }) => {
    const validKeys = [
      "WAKEUP_DELAY_SECS",
      "WAKEUP_IDLE_SECS",
      "WAKEUP_EVENTS",
      "WAKEUP_VIDEO",
      "WAKEUP_PLAYER",
      "WAKEUP_VOLUME",
      "WAKEUP_LOOP",
      "WAKEUP_MAX_SECS",
      "WAKEUP_RETURN_SECS",
      "WAKEUP_LOG",
    ];

    if (!validKeys.includes(key)) {
      return {
        content: [
          {
            type: "text",
            text: `❌ Invalid config key: "${key}"\n\nValid keys:\n${validKeys.map((k) => `  • ${k}`).join("\n")}`,
          },
        ],
      };
    }

    if (updateConfig(key, value)) {
      return {
        content: [
          {
            type: "text",
            text: `✅ Updated ${key} = "${value}"\n\nChange takes effect on the next alarm trigger.`,
          },
        ],
      };
    } else {
      return {
        content: [
          { type: "text", text: `❌ Failed to update ${key}. Check file permissions.` },
        ],
      };
    }
  }
);

// Tool: add_media — Add a local video file to the media directory
server.tool(
  "add_media",
  "Add a local video file to the alarm media directory. Only video formats supported: mp4, mov, avi, mkv, webm.",
  {
    filepath: z
      .string()
      .describe("Absolute path to the video file to add"),
  },
  async ({ filepath }) => {
    try {
      if (!existsSync(filepath)) {
        return {
          content: [{ type: "text", text: `❌ File not found: ${filepath}` }],
        };
      }

      const ext = extname(filepath).toLowerCase();
      if (!VIDEO_EXTENSIONS.includes(ext)) {
        return {
          content: [
            {
              type: "text",
              text: `❌ Unsupported file type: ${ext}\n\nOnly video formats are supported: ${VIDEO_EXTENSIONS.join(", ")}`,
            },
          ],
        };
      }

      const filename = `custom-${Date.now()}${ext}`;
      const dest = join(MEDIA_DIR, filename);
      copyFileSync(filepath, dest);

      return {
        content: [
          {
            type: "text",
            text: `✅ Video file added!\n\nSource: ${filepath}\nSaved as: ${filename}\nLocation: ${dest}\n\nIt will be included in random alarm selection.`,
          },
        ],
      };
    } catch (err) {
      return {
        content: [
          { type: "text", text: `❌ Error adding media: ${err.message}` },
        ],
      };
    }
  }
);

// --- Start server ---

async function main() {
  const args = process.argv.slice(2);
  const portIdx = args.indexOf("--port");

  if (portIdx !== -1 && args[portIdx + 1]) {
    // SSE transport for remote agents
    const port = parseInt(args[portIdx + 1], 10);
    const httpServer = createServer(async (req, res) => {
      if (req.url === "/sse") {
        const transport = new SSEServerTransport("/messages", res);
        await server.connect(transport);
      } else if (req.url?.startsWith("/messages")) {
        // handled by SSE transport
      } else {
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(
          JSON.stringify({
            name: "dev-meme-notifier-mcp",
            version: "1.0.0",
            tools: [
              "trigger_alarm",
              "trigger_alarm_dry",
              "list_media",
              "get_status",
              "set_config",
              "add_media",
            ],
          })
        );
      }
    });
    httpServer.listen(port, () => {
      console.error(`dev-meme-notifier MCP server on http://localhost:${port}/sse`);
    });
  } else {
    // stdio transport (default for local MCP clients)
    const transport = new StdioServerTransport();
    await server.connect(transport);
    console.error("dev-meme-notifier MCP server started (stdio)");
  }
}

main().catch(console.error);
