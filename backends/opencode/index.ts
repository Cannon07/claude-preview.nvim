// index.ts — OpenCode plugin entry point.
//
// After issue #47 phase 3, this plugin is a thin transport layer. It collects
// OpenCode's {tool, args, directory} from each hook firing, JSON-encodes it,
// and pipes it into the shell shim under backends/opencode/, which performs
// socket discovery and RPCs the in-process orchestrator. Tool-name and
// camelCase→snake_case mapping live Lua-side (pre_tool.normalisers.opencode).
//
// See docs/adr/0006-opencode-defers-os-independence-to-46.md for why this
// keeps the bash shim instead of speaking nvim RPC directly from TS.

import type { Plugin } from "@opencode-ai/plugin"
import { execSync } from "child_process"
import { existsSync, readFileSync } from "fs"
import { resolve, dirname } from "path"
import { fileURLToPath } from "url"

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)

// ── Shim path resolution ─────────────────────────────────────────
// bin-path.txt was historically written by the installer pointing at the
// plugin's bin/ directory. Phase 3 changes its meaning to the plugin root
// (so we can locate backends/opencode/ alongside bin/). For users who
// upgrade without re-running :CodePreviewInstallOpenCodeHooks, fall back to
// the legacy interpretation by stepping up one directory.
//
// Transitional for v2.3; remove the legacy fallback in v3.0.

function resolveShim(name: string): string | null {
  const root = readBinPath()
  if (!root) return null
  const primary = resolve(root, "backends/opencode", name)
  if (existsSync(primary)) return primary
  const legacy = resolve(root, "..", "backends/opencode", name)
  if (existsSync(legacy)) return legacy
  return null
}

function readBinPath(): string | null {
  try {
    return readFileSync(resolve(__dirname, "bin-path.txt"), "utf-8").trim()
  } catch {
    // Development fallback: plugin source lives at <root>/backends/opencode/.
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

function runShim(scriptName: string, payload: object): void {
  const shim = resolveShim(scriptName)
  if (!shim) {
    // Symmetric with the timeout branch below: surface enough breadcrumb
    // that a misconfigured bin-path.txt isn't a silently-broken plugin.
    // eslint-disable-next-line no-console
    console.debug(`[code-preview] could not resolve shim ${scriptName}`)
    return
  }
  try {
    execSync(`"${shim}"`, {
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
      console.debug(`[code-preview] ${scriptName} timed out after 15s`)
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
      await enqueueHook(() => runShim("code-preview-diff.sh", payload))
    },

    "tool.execute.after": async (input, _output) => {
      if (!PREVIEW_TOOLS.has(input.tool)) return
      const args = ((input as any).args as Record<string, any>) ?? {}
      const payload = { tool: input.tool, args, cwd: directory }
      await enqueueHook(() => runShim("code-close-diff.sh", payload))
    },
  }
}

export default plugin
