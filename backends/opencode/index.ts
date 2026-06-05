// index.ts — OpenCode plugin entry point.
//
// Thin transport layer: collects OpenCode's {tool, args, directory} per hook
// firing, JSON-encodes it, and pipes it into the shared generic hook entry
// (bin/hook-entry.{sh,ps1}), invoked as `opencode pre|post`, which performs
// socket discovery and RPCs the in-process orchestrator. Tool-name and
// camelCase→snake_case mapping live Lua-side (pre_tool.normalisers.opencode).
//
// See docs/adr/0008-one-hook-entry-per-os.md — OpenCode shares the same
// per-OS shim as the other agents rather than owning its own.

import type { Plugin } from "@opencode-ai/plugin"
import { execSync } from "child_process"
import { existsSync, readFileSync } from "fs"
import { resolve, dirname } from "path"
import { fileURLToPath } from "url"

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

const IS_WIN = process.platform === "win32"

// ── Hook-entry resolution ────────────────────────────────────────
// bin-path.txt (written by the installer) points at the plugin root; the shim
// lives at <root>/bin/hook-entry.{sh,ps1}. Re-run :CodePreviewInstallOpenCodeHooks
// after upgrading so bin-path.txt is refreshed.

function resolveHookEntry(): string | null {
  const root = readBinPath()
  if (!root) return null
  const name = IS_WIN ? "hook-entry.ps1" : "hook-entry.sh"
  const p = resolve(root, "bin", name)
  return existsSync(p) ? p : null
}

function readBinPath(): string | null {
  try {
    return readFileSync(resolve(__dirname, "bin-path.txt"), "utf-8").trim()
  } catch {
    // Development fallback: index.ts lives at <root>/backends/opencode/.
    return resolve(__dirname, "../..")
  }
}

// ── Tool allowlist ───────────────────────────────────────────────
// OpenCode tools as of 2026-05-19 the plugin previews: edit, write,
// multiedit, bash, apply_patch. Tools we deliberately ignore (fire-and-
// forget reads): read, glob, grep, list, todoread, todowrite, webfetch,
// websearch, task. Short-circuiting these here saves a bash fork + RPC per
// firing — OpenCode reads/greps prolifically.
//
// Symptom of forgetting to add a new structured-edit tool: no diff appears
// for it. Update this set and pre_tool.normalisers.opencode's tool map
// together.
const PREVIEW_TOOLS = new Set(["edit", "write", "multiedit", "bash", "apply_patch"])

// ── Shim invocation ──────────────────────────────────────────────

function runHook(event: "pre" | "post", payload: object): void {
  const shim = resolveHookEntry()
  if (!shim) {
    // Surface enough breadcrumb that a misconfigured bin-path.txt isn't a
    // silently-broken plugin.
    // eslint-disable-next-line no-console
    console.debug(`[code-preview] could not resolve hook-entry shim`)
    return
  }
  // On Windows the .ps1 runs through PowerShell; on Unix the .sh runs directly.
  const cmd = IS_WIN
    ? `powershell -NoProfile -ExecutionPolicy Bypass -File "${shim}" opencode ${event}`
    : `"${shim}" opencode ${event}`
  try {
    execSync(cmd, {
      input: JSON.stringify(payload),
      env: { ...process.env, CODE_PREVIEW_BACKEND: "opencode" },
      timeout: 15000,
      stdio: ["pipe", "pipe", "pipe"],
    })
  } catch (err: any) {
    // Abstain on any failure. Log timeouts at debug-equivalent because
    // a silent 15s hang is otherwise hard to diagnose; everything else
    // is treated as best-effort and swallowed.
    if (err && (err.code === "ETIMEDOUT" || err.signal === "SIGTERM")) {
      // eslint-disable-next-line no-console
      console.debug(`[code-preview] hook-entry ${event} timed out after 15s`)
    }
  }
}

// ── Hook serialisation ───────────────────────────────────────────
// TS→nvim send-order preservation: OpenCode fires before(A) and after(B)
// concurrently; without this, RPCs can reorder during socket discovery and a
// post-tool close can land before its matching pre-tool open. The in-process
// Lua orchestrator serialises *within* nvim's main thread, but cannot fix
// out-of-order arrivals from the TS side.

let hookQueue: Promise<void> = Promise.resolve()

function enqueueHook(fn: () => void): Promise<void> {
  hookQueue = hookQueue.then(() => {
    try { fn() } catch { /* non-fatal */ }
  })
  return hookQueue
}

// ── Plugin entry point ───────────────────────────────────────────

const plugin: Plugin = async ({ directory }) => {
  return {
    "tool.execute.before": async (input, output) => {
      if (!PREVIEW_TOOLS.has(input.tool)) return
      const args = (output.args as Record<string, any>) ?? {}
      const payload = { tool: input.tool, args, cwd: directory }
      await enqueueHook(() => runHook("pre", payload))
    },

    "tool.execute.after": async (input, _output) => {
      if (!PREVIEW_TOOLS.has(input.tool)) return
      const args = ((input as any).args as Record<string, any>) ?? {}
      const payload = { tool: input.tool, args, cwd: directory }
      await enqueueHook(() => runHook("post", payload))
    },
  }
}

export default plugin
