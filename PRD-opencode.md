# OpenCode Integration — Product Requirements Document

## Overview

Add support for [OpenCode](https://github.com/anomalyco/opencode) as an
alternative backend alongside Claude Code. Users running OpenCode instead of
(or alongside) Claude Code should get the same Neovim diff preview and
neo-tree indicators without any changes to the core Lua modules.

**GitHub issue:** [#7](https://github.com/Cannon07/claude-preview.nvim/issues/7)

## Motivation

OpenCode is a popular open-source AI coding agent (130K+ stars) that is
provider-agnostic (Anthropic, OpenAI, Gemini, local models). Multiple users
have requested support. Since the core value of this plugin is the **Neovim
diff preview experience**, supporting multiple CLI backends significantly
expands the user base.

## How OpenCode Hooks Work

OpenCode has a TypeScript/JavaScript plugin system with hooks analogous to
Claude Code's shell hooks:

| Claude Code | OpenCode | Description |
|---|---|---|
| `PreToolUse` shell script | `tool.execute.before` JS/TS plugin | Called before any tool executes |
| `PostToolUse` shell script | `tool.execute.after` JS/TS plugin | Called after tool executes |
| `.claude/settings.local.json` | `.opencode/plugins/` directory | Where hooks are configured |

### Key differences from Claude Code

1. **Plugin format** — OpenCode plugins are TS/JS modules (not shell scripts)
2. **Plugin location** — loaded from `.opencode/plugins/` (project) or
   `~/.config/opencode/plugins/` (global)
3. **Edit tools** — OpenCode has `edit` (find/replace), `multiedit`
   (sequential edits), and `apply_patch` (unified diff across files)
4. **Hook signature** — `(input, output) => Promise<void>` where `input`
   contains tool name and args, `output` is mutable
5. **Shell access** — plugins receive a `$` (Bun shell) utility for running
   shell commands

### OpenCode plugin structure

```typescript
import type { Plugin } from "@opencode-ai/plugin"

export default: Plugin = async ({ client, project, directory, worktree, $ }) => {
  return {
    "tool.execute.before": async (input, output) => {
      // input.tool = "edit" | "multiedit" | "apply_patch" | "write" | "bash"
      // input.sessionID, input.callID
      // output.args = { filePath, oldString, newString, ... }
    },
    "tool.execute.after": async (input, output) => {
      // input.args = original args
      // output.metadata = { diff, filediff: { before, after, additions, deletions } }
    },
  }
}
```

## Architecture

The core principle: **the Lua side is backend-agnostic**. Both Claude Code
and OpenCode ultimately call the same Lua functions (`show_diff()`,
`close_diff()`, `changes.set()`, etc.) via Neovim RPC. Only the hook/plugin
layer differs.

```
Claude Code (tmux)                 Neovim                    OpenCode (tmux)
      │                               │                           │
 PreToolUse hook fires                │              tool.execute.before fires
      │                               │                           │
 claude-preview-diff.sh ──RPC──→ show_diff()  ←──RPC── opencode-plugin.ts
      │                               │                           │
 CLI: "Accept? (y/n)"           User reviews diff       CLI: permission prompt
      │                               │                           │
 PostToolUse hook fires               │              tool.execute.after fires
      │                               │                           │
 claude-close-diff.sh ──RPC───→ close_diff() ←──RPC── opencode-plugin.ts
```

## What stays the same

These modules are backend-agnostic and require **no changes**:

| Module | Reason |
|---|---|
| `lua/claude-preview/diff.lua` | Receives temp file paths, doesn't care who created them |
| `lua/claude-preview/changes.lua` | Pure key-value store, no backend coupling |
| `lua/claude-preview/neo_tree.lua` | Reads from changes registry, no backend coupling |
| `lua/claude-preview/health.lua` | Will be extended (not modified) for OpenCode checks |
| `bin/nvim-socket.sh` | Socket discovery is backend-agnostic |
| `bin/nvim-send.sh` | RPC helper is backend-agnostic |

## What's new

### New files

| File | Purpose |
|---|---|
| `opencode-plugin/index.ts` | OpenCode plugin — intercepts tool events, computes diffs, sends to Neovim via RPC |
| `opencode-plugin/package.json` | Plugin package metadata |
| `opencode-plugin/tsconfig.json` | TypeScript config |

### Modified files

| File | Change |
|---|---|
| `lua/claude-preview/hooks.lua` | Add `install_opencode()` / `uninstall_opencode()` functions |
| `lua/claude-preview/init.lua` | Add `:CodePreviewInstallOpenCodeHooks` / `:CodePreviewUninstallOpenCodeHooks` commands |
| `lua/claude-preview/health.lua` | Add OpenCode-specific health checks |

---

## Implementation Tasks

### Task 1: OpenCode plugin — core structure

Create the TypeScript plugin that OpenCode will load from `.opencode/plugins/`.

**Files to create:**
```
opencode-plugin/
├── index.ts          # Plugin entry point
├── package.json      # Package metadata
└── tsconfig.json     # TypeScript config
```

**`index.ts` should:**
- Export a default plugin function matching OpenCode's `Plugin` type
- Register `tool.execute.before` and `tool.execute.after` hooks
- Discover the Neovim socket (reuse `nvim-socket.sh` via `$` shell utility)
- Provide helpers for sending Lua commands to Neovim via RPC

**How to test:**
- Place plugin in `.opencode/plugins/`, run OpenCode, verify it loads without errors

---

### Task 2: OpenCode plugin — edit interception (`tool.execute.before`)

Implement the `tool.execute.before` hook to intercept file edits and show
diffs in Neovim.

**Handle these OpenCode tools:**

| Tool | Args | How to compute proposed content |
|---|---|---|
| `edit` | `filePath`, `oldString`, `newString` | Find-and-replace (same as Claude Code's Edit) |
| `multiedit` | `filePath`, `edits[]` | Sequential find-and-replace |
| `apply_patch` | `patch` (unified diff string) | Apply patch to get proposed content |
| `write` | `filePath`, `content` | Content is the proposed file |
| `bash` | `command` | Detect `rm` commands (same as Claude Code) |

**For each edit tool:**
1. Read the original file content
2. Compute the proposed content by applying the edit
3. Write original and proposed to temp files
4. Send RPC to Neovim: `changes.set()`, `neo_tree.refresh()`, `show_diff()`

**Key decision:** The edit computation (find-and-replace) should be done
in TypeScript directly, rather than shelling out to `apply-edit.lua`. This
avoids the `nvim --headless` dependency for OpenCode users and keeps the
plugin self-contained.

**How to test:**
- Run OpenCode, ask it to edit a file
- Verify diff preview appears in Neovim before the edit is applied

---

### Task 3: OpenCode plugin — cleanup (`tool.execute.after`)

Implement the `tool.execute.after` hook to clean up after the user
accepts/rejects.

**Should:**
1. Send RPC to Neovim: `changes.clear_all()`, `close_diff()`, `neo_tree.refresh()`
2. Clean up temp files
3. Handle the `bash` tool (rm detection) — only clear deletion markers

**How to test:**
- Accept/reject an edit in OpenCode
- Verify diff closes and neo-tree indicators clear in Neovim

---

### Task 4: Hook installer for OpenCode

Add Lua functions to copy the plugin into the project's `.opencode/plugins/`
directory.

**Modify `lua/claude-preview/hooks.lua`:**

```lua
function M.install_opencode()
  -- 1. Resolve plugin source: <plugin-root>/opencode-plugin/
  -- 2. Resolve target: <cwd>/.opencode/plugins/claude-preview/
  -- 3. Copy index.ts (and package.json if needed) to target
  -- 4. Notify user
end

function M.uninstall_opencode()
  -- 1. Remove <cwd>/.opencode/plugins/claude-preview/
  -- 2. Notify user
end
```

**Modify `lua/claude-preview/init.lua`:**
- Register `:CodePreviewInstallOpenCodeHooks` → `hooks.install_opencode()`
- Register `:CodePreviewUninstallOpenCodeHooks` → `hooks.uninstall_opencode()`

**How to test:**
- `:CodePreviewInstallOpenCodeHooks` — verify plugin files copied to `.opencode/plugins/claude-preview/`
- `:CodePreviewUninstallOpenCodeHooks` — verify plugin directory removed
- Restart OpenCode, verify plugin loads

---

### Task 5: Health check updates

Extend `:checkhealth claude-preview` to report OpenCode integration status.

**Add checks for:**
- OpenCode installed and in PATH (`opencode` executable)
- OpenCode plugin installed (`.opencode/plugins/claude-preview/` exists)
- Node.js/Bun available (required by OpenCode plugins)

**How to test:**
- `:checkhealth claude-preview` — verify OpenCode section appears

---

### Task 6: Documentation

Update README with OpenCode setup instructions.

**Add sections for:**
- OpenCode installation
- `:CodePreviewInstallOpenCodeHooks` usage
- Configuration differences (if any)
- Troubleshooting OpenCode-specific issues

---

## File structure (after implementation)

```
claude-preview.nvim/
├── lua/
│   └── claude-preview/
│       ├── init.lua              # setup(), commands (Claude + OpenCode)
│       ├── diff.lua              # show_diff(), close_diff() (unchanged)
│       ├── changes.lua           # change registry (unchanged)
│       ├── neo_tree.lua          # neo-tree integration (unchanged)
│       ├── hooks.lua             # install/uninstall for both backends
│       └── health.lua            # health checks for both backends
├── bin/                          # Claude Code hook scripts (unchanged)
│   ├── claude-preview-diff.sh
│   ├── claude-close-diff.sh
│   ├── nvim-socket.sh
│   ├── nvim-send.sh
│   ├── apply-edit.lua
│   └── apply-multi-edit.lua
├── opencode-plugin/              # OpenCode plugin (NEW)
│   ├── index.ts
│   ├── package.json
│   └── tsconfig.json
├── README.md
├── LICENSE
├── PRD.md
├── PRD-neo-tree.md
└── PRD-opencode.md               # This document
```

## Resolved decisions

1. **Plugin format** — Ship as raw TypeScript. OpenCode uses Bun internally,
   so TS is natively supported. No pre-compilation step needed.

2. **apply_patch handling** — For V1, show one diff at a time (last file),
   consistent with Claude Code's MultiEdit behavior. Multi-file simultaneous
   diff view is a V2 candidate.

3. **Permission hook** — V2 candidate. The `permission.ask` hook could enable
   accepting/rejecting edits from within Neovim (instead of switching to the
   CLI pane), but this changes the UX model and adds complexity. V1 keeps the
   same "review in Neovim, accept in CLI" flow as Claude Code.

## Out of scope (V1)

- **`permission.ask` hook integration** — blocking until Neovim review is
  complete (V2 candidate)
- **SDK event subscription** — connecting to OpenCode's HTTP server for
  real-time events (alternative to plugin approach)
- **Multi-file diff view** — showing all files affected by `apply_patch`
  simultaneously
- **Auto-detection** — automatically detecting whether Claude Code or OpenCode
  is running and loading the appropriate hooks
