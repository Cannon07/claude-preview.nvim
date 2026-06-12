# Contributing to code-preview.nvim

Thanks for helping out! This document covers how the plugin is built and how to run the tests.

Before diving in, two pointers to the canonical sources of truth:

- **[CONTEXT.md](CONTEXT.md)** — the glossary. The vocabulary the codebase is written in (*agent*, *proposal*, *preview*, *integration*, *hook entry*, *core handler*, *change*, …). Prefer these terms over synonyms in commits, issues, tests, and code.
- **[docs/adr/](docs/adr/)** — Architecture Decision Records. The *why* behind the structure below (in-process core handler, one hook entry per OS, forced review gate, origin-prefixed statuses, …). When this doc and an ADR disagree, the ADR wins — and please update this doc.

---

## How it works (internals)

An **agent** is an external AI coding CLI (Claude Code, OpenCode, Codex CLI, GitHub Copilot CLI) that proposes file edits and asks for permission before applying them. Each agent fires a hook on every **proposal** (one pre-tool firing — an Edit / Write / MultiEdit / ApplyPatch / Bash). code-preview intercepts that hook, renders a **preview** (the per-file diff you open and review), and tears it down once the agent reports the proposal is done.

The pipeline, end to end:

1. **Hook entry** — `bin/hook-entry.{sh,ps1}`. One generic shim *per OS*, shared by every agent, invoked as `hook-entry <agent> <pre|post>` (`.sh` on Unix, `.ps1` on Windows — see [ADR-0008](docs/adr/0008-one-hook-entry-per-os.md)). It takes the agent's native payload, optionally fast-path-filters noisy tools, performs **socket discovery** to find the running Neovim, and makes a single RPC call into the core handler.

2. **RPC transport** — `bin/nvim-call.{sh,ps1}` (caller) and `lua/code-preview/rpc.lua` (dispatcher). Args are written to a JSON tempfile, then `luaeval` invokes the named module function with the decoded args. The dispatcher is the *only* place user-controlled data crosses the shell→Lua boundary, and it never enters a Lua source string.

3. **Core handler** — `lua/code-preview/pre_tool/init.lua` and `lua/code-preview/post_tool.lua`. The agent-neutral pipeline that runs **in-process** inside the user's Neovim ([ADR-0005](docs/adr/0005-core-handler-runs-in-process.md)). It normalises the proposal, decides whether to show a preview (`visible_only` gating, shell-write detection), computes original/proposed content, and drives the diff. This is where everything that *doesn't* depend on which agent fired lives — including `permissionDecision` emission for Claude Code's [review gate](CONTEXT.md#review-gate).

4. **Preview rendering** — `lua/code-preview/diff.lua`. `show_diff()` / `close_diff()`, plus layout resolution (`tab` / `vsplit` share the side-by-side renderer; `inline` is the unified-diff renderer that's the strategic direction, see [ADR-0003](docs/adr/0003-inline-renderer-as-future-default.md)).

An **integration** is the per-agent adapter: an **installer** (`lua/code-preview/backends/<agent>.lua`) that wires the agent's config files to point at the hook entry, plus — for agents that need in-agent glue — adapter code. Only **OpenCode** needs the latter: a TypeScript plugin under `backends/opencode/` that bridges OpenCode's `tool.execute.before/after` API to the shared hook entry. Claude Code, Copilot CLI, and Codex have no `backends/<agent>/` directory — their installers point the agent's native shell-hook config straight at `bin/hook-entry`.

> **Note:** the directory `backends/` and the env var `CODE_PREVIEW_BACKEND` are historical names for what CONTEXT.md now calls an *agent*. Don't rename them, but say "agent" in new code and docs.

---

## Architecture

```
lua/code-preview/
├── init.lua             setup(), config, user commands
├── diff.lua             preview rendering: show_diff(), close_diff(), layouts
├── rpc.lua              RPC dispatcher — the shell→Lua boundary
├── pidfile.lua          per-Neovim pidfile for socket discovery
├── platform.lua         per-OS hook-command construction
├── changes.lua          change-status registry (modified/created/deleted/bash_*)
├── neo_tree.lua         neo-tree integration (indicators, virtual nodes, reveal)
├── health.lua           :checkhealth code-preview
├── log.lua              opt-in debug logging
├── pre_tool/            in-process core handler (pre-tool side)
│   ├── init.lua           orchestration: normalise proposal → decide preview
│   ├── normalisers.lua    per-agent tool payload → canonical proposal
│   ├── emitters.lua       build the RPC/permission responses
│   └── shell_detect.lua   Tier-1 Bash write detection (redirects, mv, sed -i, …)
├── post_tool.lua        in-process core handler (post-tool side): close previews
├── apply/               in-process edit transformers (edit / multi_edit / patch)
└── backends/            per-agent installers (claudecode, opencode, copilot, codex)

bin/                     scripts the agent invokes + headless workers
├── hook-entry.{sh,ps1}  generic per-OS hook entry: hook-entry <agent> <pre|post>
├── nvim-socket.{sh,ps1}  socket discovery (pidfile + per-OS fallbacks)
├── nvim-call.{sh,ps1}    RPC caller (JSON args tempfile → luaeval into dispatcher)
├── apply-edit.lua        headless worker: Edit proposal → proposed content
├── apply-multi-edit.lua  headless worker: MultiEdit
└── apply-patch.lua       headless worker: ApplyPatch (custom patch format)

backends/
└── opencode/            OpenCode TS plugin — the only agent needing in-agent glue
    ├── index.ts           tool.execute.before/after → hook-entry
    ├── package.json
    └── tsconfig.json
```

A **headless worker** is a short-lived `nvim --headless -l <script>.lua` that transforms data *outside* the user's Neovim — no UI, no access to `M.config` or open buffers. The `bin/apply-*.lua` scripts are the canonical examples; the orchestration around them lives in the in-process core handler ([ADR-0005](docs/adr/0005-core-handler-runs-in-process.md)).

---

## Testing

Tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim) for the core plugin and shell scripts for per-agent integration. CI runs on Ubuntu and macOS.

```bash
./tests/run.sh                     # all tests (plugin + backends)
./tests/run.sh plugin              # core plugin tests only (plenary busted)
./tests/run.sh backends            # all per-agent integration tests
./tests/run.sh backends/claudecode # one agent (claudecode|opencode|copilot|codex)
```

**Dependencies:** Neovim >= 0.10, jq, bun (for OpenCode tests). Plenary auto-installs to `deps/` on first run.

> **Dogfooding note:** this repo installs code-preview's own hooks (`.claude/settings.local.json`), so edits made by an agent inside this project trigger live previews. After changing plugin code, restart Neovim before testing — the running instance won't pick up the new code otherwise (see `CLAUDE.md`).
