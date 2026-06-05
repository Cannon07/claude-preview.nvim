# claude-preview.nvim — Product Requirements Document

## What is this?

A Neovim plugin that bridges Claude Code CLI (running in an external tmux pane) with Neovim's diff view. When Claude proposes a file change, a side-by-side diff appears in Neovim **before** the file is written — letting you review exactly what's changing before accepting.

## Why does this exist?

Claude Code has first-class IDE integration for VS Code (diff preview, accept/reject UI). For Neovim, the official `claudecode.nvim` plugin works — but only when Claude runs inside Neovim's built-in terminal via WebSocket/MCP.

Many developers prefer running Claude Code CLI in a separate tmux pane alongside Neovim. In this setup, there's no way to preview proposed changes in the editor before accepting. This plugin solves that gap.

## How it works (high level)

```
Claude CLI (tmux pane)              Neovim (tmux pane)
        │                                  │
   Proposes an Edit                        │
        │                                  │
   PreToolUse hook fires ──→ hook script ──→ RPC → show_diff()
        │                                  │      (new tab, side-by-side)
   CLI: "Accept? (y/n)"                   │
        │                         User reviews diff
   User accepts/rejects                    │
        │                                  │
   PostToolUse hook fires ─→ hook script ──→ RPC → close_diff()
```

Three mechanisms working together:
1. **Claude Code Hooks** — `PreToolUse` intercepts edits before they happen, `PostToolUse` cleans up after
2. **Neovim RPC** — hook scripts send Lua commands to Neovim via its Unix socket (`nvim --server <socket> --remote-send`)
3. **Neovim diff mode** — native side-by-side diff in a dedicated tab

## User experience

### Installation

```lua
-- lazy.nvim
{
  "jayshitre/claude-preview.nvim",
  config = function()
    require("claude-preview").setup()
  end,
}
```

### Setup (one-time)

After installing, run inside Neovim:
```
:ClaudePreviewInstallHooks
```

This writes the hook configuration to `.claude/settings.local.json` in the current project. The user never manually edits hook files or scripts.

### Daily workflow

1. Open tmux, split into two panes
2. Left pane: `nvim .`
3. Right pane: `claude`
4. Ask Claude to make changes
5. Diff tab auto-opens in Neovim with CURRENT (left) vs PROPOSED (right)
6. Review in Neovim, switch to CLI pane, accept or reject
7. Diff tab auto-closes

### Uninstall hooks

```
:ClaudePreviewUninstallHooks
```

Removes the hooks from `.claude/settings.local.json`.

---

## Implementation Tasks

### Task 1: Plugin scaffold and entry point

Create the basic plugin structure and the `setup()` function.

**Files to create:**
```
claude-preview.nvim/
├── lua/
│   └── claude-preview/
│       └── init.lua          # setup(), config merging, health check
├── LICENSE
└── README.md
```

**`setup()` should:**
- Accept an optional config table with defaults
- Store the merged config in a module-level variable
- Register user commands (`:ClaudePreviewInstallHooks`, `:ClaudePreviewUninstallHooks`, `:ClaudePreviewStatus`)
- NOT auto-install hooks (explicit user action via command)

**Default config:**
```lua
{
  diff = {
    layout = "tab",             -- "tab" (new tab) or "vsplit" (in current tab)
    labels = { current = "CURRENT", proposed = "PROPOSED" },
    auto_close = true,          -- close diff after accept/reject
    equalize = true,            -- 50/50 split widths
    full_file = true,           -- show full file, not just hunks
  },
  highlights = {
    current = {
      DiffAdd    = { bg = "#4c2e2e" },
      DiffDelete = { bg = "#2e4c2e" },
      DiffChange = { bg = "#4c3a2e" },
      DiffText   = { bg = "#5c3030" },
    },
    proposed = {
      DiffAdd    = { bg = "#2e4c2e" },
      DiffDelete = { bg = "#4c2e2e" },
      DiffChange = { bg = "#2e3c4c" },
      DiffText   = { bg = "#3e5c3e" },
    },
  },
}
```

**How to test:**
- `:lua require("claude-preview").setup()` — should not error
- `:ClaudePreviewStatus` — should show "Hooks: not installed, Neovim RPC: <socket path>"

---

### Task 2: Diff module

Port `claude-diff.lua` into the plugin as `lua/claude-preview/diff.lua`.

**Files to create:**
```
lua/claude-preview/
    └── diff.lua              # show_diff(), close_diff()
```

**What it does:**
- `show_diff(original_path, proposed_path, display_name)` — opens diff view using config from `setup()`
- `close_diff()` — closes diff view and cleans up
- Reads highlight config from the merged setup config (not hardcoded)
- Respects `config.diff.layout` ("tab" or "vsplit")
- Respects `config.diff.full_file`, `config.diff.equalize`
- Handles `VimResized` for re-equalizing

**How to test:**
- Create two temp files with different content
- `:lua require("claude-preview.diff").show_diff("/tmp/a.lua", "/tmp/b.lua", "test.lua")`
- Verify diff appears with correct layout, highlights, labels
- `:lua require("claude-preview.diff").close_diff()`

---

### Task 3: Hook scripts

Port the shell/Python scripts into the plugin's `bin/` directory. These get bundled with the plugin and referenced by absolute path when hooks are installed.

**Files to create:**
```
bin/
├── claude-preview-diff.sh    # PreToolUse hook entry point
├── claude-close-diff.sh      # PostToolUse hook entry point
├── nvim-socket.sh            # Socket discovery helper
├── nvim-send.sh              # RPC send helper
├── apply-edit.py             # Single Edit string replacement
└── apply-multi-edit.py       # MultiEdit sequential replacement
```

**Key change from prototype:** The preview script needs to call `require("claude-preview.diff").show_diff(...)` instead of `require("custom.claude-diff").show_diff(...)`.

**How to test:**
- Simulate a PreToolUse call by piping JSON into the script
- Verify diff opens in Neovim and script outputs correct JSON
- Simulate a PostToolUse call, verify diff closes

---

### Task 4: Hook installer commands

Implement `:ClaudePreviewInstallHooks` and `:ClaudePreviewUninstallHooks`.

**Files to modify:**
```
lua/claude-preview/
    ├── init.lua              # Register commands
    └── hooks.lua             # NEW: install/uninstall logic
```

**`:ClaudePreviewInstallHooks` should:**
1. Determine the plugin's `bin/` directory path (where the hook scripts live)
2. Read existing `.claude/settings.local.json` (or create it)
3. Add/update the PreToolUse and PostToolUse hook entries
4. Write the file back
5. Print confirmation message

**`:ClaudePreviewUninstallHooks` should:**
1. Read `.claude/settings.local.json`
2. Remove the claude-preview hook entries (leave other hooks intact)
3. Write the file back
4. Print confirmation message

**Hook paths must be absolute** — the plugin resolves its own `bin/` directory at install time using `debug.getinfo` or Neovim's `runtimepath`.

**How to test:**
- Run `:ClaudePreviewInstallHooks` — verify `.claude/settings.local.json` is created with correct paths
- Run `:ClaudePreviewUninstallHooks` — verify hooks are removed
- Restart Claude CLI, make an edit — verify hooks fire

---

### Task 5: Status command and health check

Implement `:ClaudePreviewStatus` and `:checkhealth claude-preview`.

**Files to create/modify:**
```
lua/claude-preview/
    ├── init.lua              # :ClaudePreviewStatus command
    ├── health.lua            # NEW: checkhealth integration
    └── socket.lua            # NEW: Lua-native socket discovery (optional)
```

**`:ClaudePreviewStatus` should display:**
- Hooks installed: yes/no (check `.claude/settings.local.json`)
- Neovim RPC socket: path or "not found"
- Dependencies: jq (found/missing), python3 (found/missing)
- Diff tab: open/closed

**`:checkhealth claude-preview` should verify:**
- `jq` is available in PATH
- `python3` is available in PATH
- Hook scripts are executable
- `.claude/settings.local.json` exists and has valid hooks
- Neovim RPC socket is accessible

**How to test:**
- `:ClaudePreviewStatus` — verify output is accurate
- `:checkhealth claude-preview` — verify all checks pass

---

### Task 6: README and documentation

**Files to create:**
```
README.md                     # Installation, usage, configuration, troubleshooting
LICENSE                       # MIT
```

**README sections:**
- What it does (with a GIF/screenshot if possible)
- Requirements (Neovim 0.9+, tmux, jq, python3, Claude Code CLI)
- Installation (lazy.nvim, packer, manual)
- Quick start (setup + install hooks)
- Configuration reference (all options with defaults)
- Commands reference
- How it works (brief architecture)
- Troubleshooting (common issues)
- Differences from claudecode.nvim and nvim-claude

---

### Task 7: Testing and polish

- Test all tool types: Edit, Write, MultiEdit
- Test edge cases: new file, Neovim closed, rapid sequential edits
- Test with different Neovim versions (0.9, 0.10, nightly)
- Test on macOS and Linux (socket paths differ)
- Clean up temp files properly
- Ensure no side effects on Neovim startup (lazy loading)

---

## File structure (final)

```
claude-preview.nvim/
├── lua/
│   └── claude-preview/
│       ├── init.lua          # setup(), commands, config
│       ├── diff.lua          # show_diff(), close_diff()
│       ├── hooks.lua         # install/uninstall hooks
│       ├── health.lua        # :checkhealth integration
│       └── socket.lua        # Lua-native socket discovery (optional)
├── bin/
│   ├── claude-preview-diff.sh
│   ├── claude-close-diff.sh
│   ├── nvim-socket.sh
│   ├── nvim-send.sh
│   ├── apply-edit.py
│   └── apply-multi-edit.py
├── README.md
├── LICENSE
└── PRD.md
```

## Out of scope (for now)

- **Inline diff** (like nvim-claude) — we use a tab-based approach for simplicity
- **Accept/reject from Neovim** — acceptance happens in the CLI; Neovim is read-only preview
- **MCP/WebSocket server** — we use hooks + RPC, not the MCP protocol
- **Non-tmux setups** — the plugin works in any terminal setup, but the naming and docs target tmux users
- **Auto-installing hooks on setup()** — explicit user action required for transparency
