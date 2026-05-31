# Glossary

The vocabulary code-preview.nvim is written in. When naming things in commits, issues, tests, docs, or code, prefer the terms defined here over synonyms.

---

## Agent

An external AI coding CLI that proposes file edits and asks the user for permission before applying them. The plugin's reason for existing: previewing those proposals inside Neovim before the agent acts.

Supported agents today: **Claude Code**, **OpenCode**, **Codex CLI**, **GitHub Copilot CLI**. Each one fires hooks (or the agent's equivalent) on every proposed edit, which the plugin intercepts.

The directory `backends/` and the env var `CODE_PREVIEW_BACKEND` are historical names for what we now call an agent. Don't rename them — the cost outweighs the benefit — but in conversation, design docs, and new code, say "agent."

## Integration

The per-agent adapter that translates that agent's hook format into the plugin's normalised core. One integration per agent. Each integration has two parts:

- **Installer** (`lua/code-preview/backends/<agent>.lua`) — wires the agent's config files (e.g. `.claude/settings.local.json`, `.opencode/plugins/index.ts`) to point at the plugin's hook scripts.
- **Hook entry** (`backends/<agent>/code-{preview,close}-diff.sh`) — see [Hook entry](#hook-entry).

When a doc or issue says "the Codex integration," it means the installer + adapter scripts for Codex — never the running Codex CLI itself.

## Proposal

One agent action that wants to touch the filesystem — a single firing of the agent's pre-tool hook. Corresponds 1:1 with an Edit / Write / MultiEdit / Bash / ApplyPatch invocation by the agent.

A proposal can produce zero, one, or many [previews](#preview):

- Edit / Write / MultiEdit — one preview per call (single file).
- ApplyPatch — one preview per file in the patch.
- Bash — zero previews; the plugin only updates change indicators (no content diff is rendered).

Do not say "tool use" or "tool call" in plugin-side docs — those are agent-side terms. The plugin sees proposals.

## Preview

The per-file unit of pending review. One open diff tab (or vsplit, or inline buffer) keyed by absolute file path in `active_diffs`. A preview *contains* a diff; "diff" is the content (added/removed lines), "preview" is the thing the user opens, scrolls, and closes.

Lifecycle: a [proposal](#proposal) creates one or more previews → the user reviews them → the agent's post-tool hook closes the matching previews (whether the user accepted or rejected on the agent's side).

Prefer "preview" over "diff" when naming the unit: `close_for_file` closes a preview; the buffer inside it displays a diff.

## RPC

The transport that lets an [integration](#integration)'s shell scripts call into the running Neovim. Implemented by `bin/nvim-call.sh` (caller side) and `lua/code-preview/rpc.lua` (dispatcher side): a JSON args array is written to a tempfile, then `luaeval` invokes the named module function with those args decoded.

A single request → response invocation is an **RPC call**. We do not yet need a more specific name for the call shape; #47 may still reshape it.

## Socket discovery

The act of finding which running Neovim instance to address an RPC call at. Resolution order (see `bin/nvim-socket.sh`):

1. `$NVIM_LISTEN_ADDRESS` env var, if its socket is responsive.
2. **Pidfile** lookup — preferred path since #47 phase 1.
3. Glob `/var/folders/*/T/nvim.*/0` (macOS default tempdir).
4. Glob `/tmp/${NVIM_APPNAME}.*/0` (Linux + some macOS setups).
5. Glob `$XDG_RUNTIME_DIR/${NVIM_APPNAME}.*.0` (NixOS, systemd-based distros).

If multiple instances match, prefer the one whose cwd matches (or is a parent of) the project cwd passed in by the calling hook.

On **Windows** (issue #46) the addressable target is a named pipe (`\\.\pipe\nvim.<pid>.0`) rather than a Unix socket. The [pidfile](#pidfile) is the primary path; the Unix glob fallbacks (steps 3–5) are replaced by a single **pipe-enumeration fallback** — list `\\.\pipe\`, keep names matching `nvim.*`, probe each for responsiveness. Pipe enumeration cannot run the cwd tiebreak (Windows has no `/proc` or `lsof` to read a process's cwd, and a pipe found this way has no pidfile cwd line), so it degrades to "first responsive pipe," mirroring how the Unix glob path degrades when the cwd lookup fails. The stale-pipe responsiveness probe (`nvim --server <pipe> --remote-expr "1"`) is unchanged in shape; only the is-socket precheck is dropped (named pipes have no reliable existence test).

## Pidfile

One file per running Neovim that has called `code-preview.setup()`. Path: `${XDG_STATE_HOME:-$HOME/.local/state}/code-preview/sockets/<pid>`. Contents: line 1 is the RPC socket path, line 2 is the Neovim's cwd.

Pidfiles self-register on `setup()`, refresh on `DirChanged`, and are removed on `VimLeavePre`. Crashed Neovims leave stale pidfiles behind; `socket discovery` self-heals by probing each socket with `--remote-expr "1"` before using it.

The pidfile *directory* is computed independently — and must agree byte-for-byte — on both the Lua writer (`pidfile.lua`) and the shim reader, so it can only use values both sides can derive without an RPC. On **Windows** (issue #46) that base is `%LOCALAPPDATA%\code-preview\sockets` (not the Unix `$XDG_STATE_HOME`/`$HOME` formula, which yields a driveless garbage path on Windows); line 1 of the file is the named-pipe path instead of a socket path.

The pidfile is *one of several* socket discovery paths, not a synonym for socket discovery.

## Hook entry

The per-agent script the agent invokes directly when it's about to (or has just) used an editing tool. One pair per [integration](#integration): `code-preview-diff.sh` for pre-tool, `code-close-diff.sh` for post-tool. Lives in `backends/<agent>/`.

Job: take the agent's native hook payload, normalise it into the shape the [core handler](#core-handler) expects (`{tool_name, cwd, tool_input}`), then hand off. The hook entry is **per-OS**: a `.sh` shim on Unix, a PowerShell `.ps1` shim on Windows (issue #46). PowerShell is the single Windows logic language across all agents — it is the only stock-Windows-11 tool that parses JSON natively, enumerates named pipes, and probes the RPC socket. The installer writes the interpreter explicitly into the agent's `command` field (`powershell -NoProfile -ExecutionPolicy Bypass -File <path>.ps1`); a thin `.cmd` trampoline is added only for an agent that raw-execs a bare path and rejects a multi-token command. Windows PowerShell 5.1 (`powershell.exe`) is the floor, not pwsh 7.

## Core handler

The agent-neutral pipeline that, given a normalised proposal, decides whether to show a preview, computes the original and proposed file content, and makes the [RPC](#rpc) call into the running Neovim. Lives in-process at `lua/code-preview/pre_tool/init.lua` and `lua/code-preview/post_tool.lua`, invoked through a single RPC call from the per-agent [hook entry](#hook-entry). The historical out-of-process bash implementation (`bin/core-pre-tool.sh`, `bin/core-post-tool.sh`) was removed when issue #47 phase 3 finished for all backends; see [ADR-0005](docs/adr/0005-core-handler-runs-in-process.md) for the canonical history.

The core handler is where shell-write detection, `visible_only` gating, and `permissionDecision` emission live — everything that doesn't depend on which agent fired the hook.

## Dispatcher

The in-process Lua entry point that receives an RPC call and invokes the target function. Exported as `M.dispatch(mod, fn, args_file)` in `lua/code-preview/rpc.lua`. Reads the JSON args file written by `nvim-call.sh`, decodes it, looks up `require(mod)[fn]`, and calls it.

The dispatcher is the *only* place user-controlled data crosses the bash/Lua boundary, and it never enters a Lua source string — that property is the whole reason the dispatcher exists (see issue #47 phase 2).

## Change

One entry in the changes registry (`lua/code-preview/changes.lua`): `{absolute_path → status}`. A change records that the agent has recently touched the file; it does not imply a [preview](#preview) is open. Bash writes set changes without ever producing a preview.

A change is set by the [core handler](#core-handler) before the [proposal](#proposal) is shown, and cleared by the post-tool handler once the agent reports the proposal is done (accepted or rejected).

## Status

The value side of a change. The five recognised statuses:

- `modified` — Edit / Write / MultiEdit / ApplyPatch on an existing file.
- `created` — same tools, on a path that didn't exist beforehand.
- `deleted` — explicit deletion (`*** Delete File:` in a patch, or `rm` detected in a Bash command).
- `bash_modified` — Bash write detected against an existing file.
- `bash_created` — Bash write detected against a path that didn't exist.

The `bash_` prefix is an **origin prefix** — see [Origin prefix](#origin-prefix).

## Origin prefix

A convention on [status](#status) values that records which kind of agent action produced the change. Today only `bash_*` is prefixed; un-prefixed statuses (`modified`, `created`, `deleted`) come from structured editing tools (Edit/Write/MultiEdit/ApplyPatch) or from explicit `rm` detection.

Origin prefixes exist because some agents (observed with GPT-class models in Codex) route file edits through `Bash`, which the plugin can't safely preview. Those proposals degrade to indicator-only ([Tier 1](#tier-1--tier-2)), and the prefix lets the Bash post-tool clear its own markers without clobbering markers from a concurrent structured proposal. See [ADR-0001](docs/adr/0001-origin-prefixed-status-values.md).

## Tier 1 / Tier 2

Two levels of fidelity for handling `Bash` proposals.

- **Tier 1** — *implemented today.* Static regex parsing of the shell command for redirections (`>`, `>>`), atomic-replace (`mv X.tmp X`), `cp`, `tee`, and `sed -i` targets. Sets a [change](#change) with a `bash_*` [origin prefix](#origin-prefix); does **not** open a [preview](#preview). The user sees the file was touched via the neo-tree [indicator](#indicator) but reviews the actual content via their normal diff workflow after the fact.
- **Tier 2** — *not implemented.* Would compute and display real content diffs for shell-writes. Open design question; sandboxing was rejected (see [ADR-0001](docs/adr/0001-origin-prefixed-status-values.md)). The name exists so deferred work has a label, not a commitment.

## Source path / File path / Display path

Three distinct path concepts used together in the [preview](#preview) pipeline. They are *not* interchangeable; the current code muddles them (see [issue #55](https://github.com/Cannon07/code-preview.nvim/issues/55)).

- **Source path** — a temp file holding pre-rendered content (`/tmp/code-preview-diff-{original,proposed}-<id>`). One pair per preview: `original_source_path` and `proposed_source_path`. Scratch files, not the real file.
- **File path** — the absolute canonical path of the real file being edited. The *identity*: used as the key in `active_diffs`, passed to the [changes](#change) registry, used by neo-tree reveal.
- **Display path** — what's rendered in the winbar. Usually cwd-relative for readability; never used as an identity.

When in doubt: identity = file path; content = source path; UI label = display path.

## Visible-only mode

Opt-in restriction (`diff.visible_only` config, default `false`) that suppresses [previews](#preview) for files not currently visible in any Neovim window. The [core handler](#core-handler) asks the running Neovim via `hook_context()` whether the target file is in any window's visible buffer; if `visible_only` is on and the file isn't visible, the preview is skipped entirely (no diff tab, no inline buffer). [Change indicators](#indicator) in neo-tree still fire — visible-only mode is about avoiding *modal* interruption, not about hiding that the edit happened.

Toggled at runtime via `:CodePreviewToggleVisibleOnly`.

## Review gate

The pause window between an agent firing the pre-tool hook and the agent actually writing the file — the moment during which the [preview](#preview) is on screen and the user can accept or reject. Every supported agent has a review gate; the *mechanism* differs per [integration](#integration):

- **Claude Code** — the plugin emits `permissionDecision: "ask"` in the pre-tool hook output, which forces Claude Code to prompt. Suppressible with `diff.defer_claude_permissions = true`, which delegates to Claude Code's own permission settings (bypass, ask, allowlist). See [ADR-0002](docs/adr/0002-default-force-review-gate.md) for why the default forces the gate.
- **OpenCode** — gated through OpenCode's plugin API.
- **Codex / Copilot CLI** — relies on the agent's native ask-before-write loop.

The plugin doesn't *implement* the gate; it lives inside the agent. The plugin's job is to make sure the gate fires (Claude Code's case) and to render a useful preview *during* the gate.

## Layout

The user-facing config value (`diff.layout`) that selects how a [preview](#preview) is rendered. Three values: `"tab"`, `"vsplit"`, `"inline"`. The first two share one [renderer](#renderer); `"inline"` uses the other.

## Renderer

The internal rendering path. Two of them:

- **Side-by-side renderer** — opens a CURRENT and a PROPOSED buffer in two windows, uses Neovim's built-in `:diffthis`. Used by both `tab` and `vsplit` layouts (the only difference is whether the windows live in a new tab or a vsplit of the current one). The legacy default.
- **Inline renderer** — single buffer showing a unified-diff view, with character-level highlights, `]c` / `[c` navigation, and a custom statuscolumn displaying old|new line numbers. Implemented in `build_inline_diff` + `inline_statuscolumn` in `lua/code-preview/diff.lua`.

The inline renderer is the strategic direction — see [ADR-0003](docs/adr/0003-inline-renderer-as-future-default.md). The side-by-side renderer is kept available but is no longer where new rendering features land.

## Reveal

The behaviour that scrolls neo-tree to the file touched by a [proposal](#proposal), so the user can see the [change indicator](#indicator) in context. Config: `neo_tree.reveal` (boolean, default on), `neo_tree.reveal_root` (`"cwd"` or `"git"` — which root neo-tree opens from).

Implementation lives in `lua/code-preview/neo_tree.lua`; the [core handler](#core-handler) and `diff.show_diff` call `reveal` / `reveal_deferred` after marking the [change](#change). The deferred variant exists because neo-tree needs a moment to settle after window changes.

**Reveal target** — the path neo-tree is asked to scroll to. For `modified`/`deleted` [statuses](#status) it's the file itself. For `created`, the file doesn't yet exist on disk, so the target falls back to the nearest existing ancestor directory (or a sibling within it) — neo-tree can't highlight a path that isn't in its tree.

Precedence rule: when a Bash command both deletes and writes (`rm a && echo x > b`), the `rm`-driven reveal wins.

## Hook context query

An [RPC](#rpc) call the [core handler](#core-handler) issues to the running Neovim early in every hook invocation, to read config + transient state in a single hop. Two main call sites:

- `code-preview.log.state` — returns `{debug, log_file}`. The shell handler uses this to decide whether to emit debug log lines and where.
- `code-preview.hook_context(file_path)` — returns `{neo_tree_reveal, reveal_root, visible_only, file_visible, defer_claude_permissions, debug, log_file}`. The transient bit is `file_visible`: whether `file_path` is currently shown in any visible window (only computed when [visible-only mode](#visible-only-mode) is on).

The pattern exists because the bash layer holds no config of its own — see [ADR-0004](docs/adr/0004-config-lives-only-in-neovim.md). If Neovim is unreachable, the hook degrades safely (no logging, no [review gate](#review-gate), no visibility filter).

After issue #47 phase 3, the hook context query collapses into a local function call inside the in-process [core handler](#core-handler); the RPC form survives only for callers that still live outside the user's Neovim (e.g. a backend that hasn't yet flipped to the Lua entry point).

## Headless worker

A short-lived Neovim spawned with `nvim --headless -l <script>.lua` to do work *outside* the user's running Neovim. Headless workers have no UI, no access to the user's `M.config` or open buffers, and communicate via stdin / stdout / exit code or via [RPC](#rpc) back to the user's instance.

Today's headless workers:

- `bin/apply-edit.lua` — computes the proposed content for an `Edit` proposal.
- `bin/apply-multi-edit.lua` — same for `MultiEdit`.
- `bin/apply-patch.lua` — parses the custom patch format and emits per-file orig/prop tempfiles for `ApplyPatch`.

Issue #47 phases 3 and 4 do **not** add the core handler to this list. After an early design pass we chose to fold the handler into in-process Lua instead of a new headless worker, to eliminate the per-proposal cold-start and the chain of small RPC calls back into the user's Neovim. See [ADR-0005](docs/adr/0005-core-handler-runs-in-process.md). After phases 3/4 land, "bash core handler" goes away and the apply-* scripts remain the canonical examples of headless workers.

## In-process Lua vs headless Lua

The plugin has two Lua code categories with different rules.

- **In-process Lua** — runs inside the user's running Neovim. Has access to `M.config`, open buffers, windows, autocmds, neo-tree, the [changes](#change) registry. Lives under `lua/code-preview/`. Examples: `init.lua`, `diff.lua`, `rpc.lua`'s `dispatch`, `pidfile.lua`'s `setup`.
- **Headless Lua** — runs in a [headless worker](#headless-worker). No access to the user's session. Must communicate findings back via stdout, tempfiles, or RPC. Lives under `bin/`. Examples: `apply-edit.lua`, `apply-patch.lua`.

When deciding where new code belongs: anything that needs to *see or change the user's Neovim state* is in-process; anything that just transforms data is a candidate for a headless worker, and after #47 phases 3/4 the orchestration around it lives in a headless worker too.

## Indicator

The rendered icon and highlight in the neo-tree filesystem source for a file that has a [change](#change). One indicator per change. The mapping from status → glyph + highlight is configured under `neo_tree.symbols` and `neo_tree.highlights`. The indicator is *the visual*; the change is *the data*.
