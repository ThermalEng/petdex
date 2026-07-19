/**
 * `petdex bubble <event>` — invoked from agent hooks on every tool
 * lifecycle event. Reads the agent's hook payload from stdin, formats
 * a human bubble via templates, POSTs to the sidecar.
 *
 * Hot path: this runs 20-50× per active session. We:
 *   - exit fast on killswitch (no token read, no fetch, no parse)
 *   - swallow ALL errors silently (a noisy hook stains the agent UI)
 *   - cap stdin reads at 64KB (hooks don't need bigger payloads, and
 *     a runaway upstream shouldn't OOM us)
 *   - use a 300ms fetch timeout (matches /state hook timing)
 *
 * Events:
 *   pre <tool|user-prompt|notification>   — sidecar receives "running"-phase bubble
 *   post <tool>                           — sidecar receives "done"-phase bubble
 *   stop                                  — session.end bubble
 */

import {
  existsSync,
  mkdirSync,
  readFileSync,
  writeFileSync,
} from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

import { type BubbleEvent, formatBubble } from "./bubble-templates";

const RUNTIME_DIR = join(homedir(), ".petdex", "runtime");
const TOKEN_PATH = join(RUNTIME_DIR, "update-token");
const KILLSWITCH_PATH = join(RUNTIME_DIR, "hooks-disabled");
const SIDECAR_BASE = "http://127.0.0.1:7777";
const SIDECAR_BUBBLE_URL = `${SIDECAR_BASE}/bubble`;
const SIDECAR_STATE_URL = `${SIDECAR_BASE}/state`;
const STDIN_CAP = 64 * 1024;
const SESSIONS_DIR = join(RUNTIME_DIR, "sessions");
const TITLE_MAX = 60;

/**
 * Session titles: UserPromptSubmit carries the user's prompt, so we
 * clip it and persist it per session_id; every later hook event in the
 * same session attaches it as the bubble's title. Plain files instead
 * of a daemon: hooks are independent short-lived processes.
 */
export function rememberSessionTitle(
  dir: string,
  sessionId: string,
  prompt: string,
): void {
  try {
    const title = clipTitle(prompt);
    if (!title) return;
    mkdirSync(dir, { recursive: true });
    writeFileSync(
      join(dir, `${sessionId}.json`),
      JSON.stringify({ title, at: Date.now() }),
    );
  } catch {
    // Hot path: a failed title write must never stain the agent.
  }
}

export function sessionTitle(dir: string, sessionId: string): string | null {
  try {
    const raw = readFileSync(join(dir, `${sessionId}.json`), "utf8");
    const parsed = JSON.parse(raw) as { title?: unknown };
    return typeof parsed.title === "string" && parsed.title.length > 0
      ? parsed.title
      : null;
  } catch {
    return null;
  }
}

export function clipTitle(prompt: string): string {
  const flat = prompt.replace(/\s+/g, " ").trim();
  if (flat.length <= TITLE_MAX) return flat;
  return `${flat.slice(0, TITLE_MAX - 1)}…`;
}

/** session_id must stay filename-safe: agent payloads are untrusted. */
function safeSessionId(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  return /^[a-zA-Z0-9_-]{1,64}$/.test(raw) ? raw : null;
}

/**
 * Map a hook phase + tool to the sprite state we want.
 * Mirrors the matchers in agents.ts so the hook command is a single
 * `petdex bubble` invocation that sets BOTH state AND bubble.
 */
export function stateForEvent(
  args: string[],
  toolName: string | null,
): string | null {
  const phase = args[0];
  if (phase === "pre") {
    if (toolName) {
      const lower = toolName.toLowerCase();
      // Read-only tools → review state. Matches the Claude Code
      // matcher in agents.ts (Read|Grep|Glob → review).
      if (lower === "read" || lower === "grep" || lower === "glob") {
        return "review";
      }
    }
    return "running";
  }
  if (phase === "post") return "idle";
  if (phase === "stop" || phase === "session-end") return "waving";
  if (phase === "user-prompt" || phase === "session-start") return "jumping";
  if (phase === "waiting" || phase === "notification") return "waiting";
  return null;
}

async function readStdin(): Promise<string> {
  // Drain stdin up to STDIN_CAP. Hooks pipe a single JSON payload, so
  // we don't need streaming semantics — we just need a bounded read.
  if (process.stdin.isTTY) return "";
  return await new Promise((resolve) => {
    let buf = "";
    let truncated = false;
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", (chunk) => {
      if (truncated) return;
      if (buf.length + chunk.length > STDIN_CAP) {
        buf += chunk.slice(0, STDIN_CAP - buf.length);
        truncated = true;
        return;
      }
      buf += chunk;
    });
    process.stdin.on("end", () => resolve(buf));
    process.stdin.on("error", () => resolve(buf));
  });
}

function parseStdin(text: string): {
  toolName: string | null;
  toolInput: unknown;
  agentSource: string | null;
  sessionId: string | null;
  prompt: string | null;
} {
  if (!text.trim()) {
    return {
      toolName: null,
      toolInput: undefined,
      agentSource: null,
      sessionId: null,
      prompt: null,
    };
  }
  try {
    const parsed = JSON.parse(text) as Record<string, unknown>;
    const toolName =
      typeof parsed.tool_name === "string" ? parsed.tool_name : null;
    const toolInput = parsed.tool_input;
    const agentSource =
      typeof parsed.agent_source === "string" ? parsed.agent_source : null;
    const sessionId = safeSessionId(parsed.session_id);
    const prompt = typeof parsed.prompt === "string" ? parsed.prompt : null;
    return { toolName, toolInput, agentSource, sessionId, prompt };
  } catch {
    return {
      toolName: null,
      toolInput: undefined,
      agentSource: null,
      sessionId: null,
      prompt: null,
    };
  }
}

export function eventFromArgs(
  args: string[],
  stdin: string,
): BubbleEvent | null {
  const phase = args[0];
  if (!phase) return null;

  // Session-level events don't need stdin parsing — they're pure
  // signals. Run them first so we don't bother parsing JSON for
  // events that don't carry a tool payload.
  if (phase === "stop" || phase === "session-end")
    return { kind: "session.end" };
  if (phase === "user-prompt" || phase === "session-start")
    return { kind: "session.start" };
  if (phase === "waiting" || phase === "notification")
    return { kind: "session.waiting" };

  // Tool events: "pre" → running, "post" → done
  const toolPhase: "running" | "done" | null =
    phase === "pre" ? "running" : phase === "post" ? "done" : null;
  if (!toolPhase) return null;

  const { toolName, toolInput } = parseStdin(stdin);
  if (!toolName) {
    // Without a tool name we can't render a useful bubble. The hook
    // may have been wired wrong or the agent didn't pass tool_name.
    // Fall back to a generic so we don't lose the signal entirely.
    return {
      kind: "tool",
      phase: toolPhase,
      toolName: "tool",
      toolInput: undefined,
    };
  }

  return { kind: "tool", phase: toolPhase, toolName, toolInput };
}

function readToken(): string | null {
  try {
    const raw = readFileSync(TOKEN_PATH, "utf8").trim();
    return raw.length > 0 ? raw : null;
  } catch {
    return null;
  }
}

async function postJson(
  url: string,
  body: object,
  token: string,
): Promise<void> {
  // 300ms timeout: well above any localhost roundtrip, well below the
  // threshold an agent user would notice as latency.
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 300);
  try {
    await fetch(url, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Petdex-Update-Token": token,
      },
      body: JSON.stringify(body),
      signal: controller.signal,
    });
  } catch {
    // Sidecar offline / aborted: stay silent. The agent must never
    // see this fail.
  } finally {
    clearTimeout(timer);
  }
}

export async function runBubble(args: string[]): Promise<void> {
  // Killswitch check FIRST — even before stdin drain — so a disabled
  // state has minimal cost. existsSync is one stat call.
  if (existsSync(KILLSWITCH_PATH)) return;

  // The agentSource is also passed as the second arg
  // (`petdex bubble pre claude-code`) so we know it without parsing
  // stdin if stdin is empty (e.g. session.end events from Stop).
  const argSource = args[1] ?? null;

  const stdin = await readStdin();
  const event = eventFromArgs(args, stdin);
  if (!event) return;

  const phase = args[0];
  const { toolName, agentSource: stdinSource, sessionId, prompt } =
    parseStdin(stdin);
  const agentSource = stdinSource ?? argSource;
  if (
    sessionId &&
    prompt &&
    (phase === "user-prompt" || phase === "session-start")
  ) {
    rememberSessionTitle(SESSIONS_DIR, sessionId, prompt);
  }
  const title = sessionId ? sessionTitle(SESSIONS_DIR, sessionId) : null;
  const text = formatBubble(event);
  const state = stateForEvent(args, toolName);

  const token = readToken();
  if (!token) return;

  // Fire both POSTs in parallel — they hit the same sidecar via
  // localhost, the rate limiter shares a budget, and we don't want
  // bubble latency to dominate state latency or vice versa.
  const tasks: Promise<unknown>[] = [];
  if (text) {
    tasks.push(
      postJson(
        SIDECAR_BUBBLE_URL,
        title
          ? { text, title, agent_source: agentSource }
          : { text, agent_source: agentSource },
        token,
      ),
    );
  }
  if (state) {
    tasks.push(
      postJson(SIDECAR_STATE_URL, { state, agent_source: agentSource }, token),
    );
  }
  await Promise.all(tasks);
}
