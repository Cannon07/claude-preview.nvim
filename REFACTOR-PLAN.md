# Refactor Plan: Rename + Restructure (Issue #13)

**Goal:** Rename `claude-preview` to `code-preview` and restructure the codebase
to separate backend-specific code from shared/core code.

**PR:** Single PR covering both rename and restructure.

---

## Current Structure

```
lua/claude-preview/
├── init.lua            -- setup, config, commands (mixed backends)
├── hooks.lua           -- Claude + OpenCode install/uninstall (mixed)
├── diff.lua            -- diff view (shared)
├── changes.lua         -- change tracking (shared)
├── neo_tree.lua        -- neo-tree integration (shared)
└── health.lua          -- healthcheck (mixed backends)

bin/
├── core-pre-tool.sh         -- unified PreToolUse logic (shared core)
├── core-post-tool.sh        -- unified PostToolUse logic (shared core)
├── claude-preview-diff.sh   -- Claude Code adapter (thin, execs core-pre-tool.sh)
├── claude-close-diff.sh     -- Claude Code adapter (thin, execs core-post-tool.sh)
├── nvim-send.sh             -- shared RPC helper
├── nvim-socket.sh           -- shared socket discovery
├── apply-edit.lua           -- shared edit transformer
└── apply-multi-edit.lua     -- shared edit transformer

opencode-plugin/
├── index.ts            -- OpenCode adapter (translates format, calls core scripts)
├── package.json
└── tsconfig.json
```

## Target Structure

```
lua/code-preview/
├── init.lua            -- setup, config, shared commands
├── diff.lua            -- diff view (shared)
├── changes.lua         -- change tracking (shared)
├── neo_tree.lua        -- neo-tree integration (shared)
├── health.lua          -- healthcheck (checks all backends)
└── backends/
    ├── claudecode.lua  -- Claude Code hook install/uninstall
    └── opencode.lua    -- OpenCode plugin install/uninstall

bin/
├── core-pre-tool.sh         -- unified PreToolUse logic (shared core)
├── core-post-tool.sh        -- unified PostToolUse logic (shared core)
├── nvim-send.sh             -- shared RPC helper
├── nvim-socket.sh           -- shared socket discovery
├── apply-edit.lua           -- shared edit transformer
└── apply-multi-edit.lua     -- shared edit transformer

backends/
├── claudecode/
│   ├── code-preview-diff.sh     -- Claude Code adapter (thin, execs ../../bin/core-pre-tool.sh)
│   └── code-close-diff.sh       -- Claude Code adapter (thin, execs ../../bin/core-post-tool.sh)
└── opencode/
    ├── index.ts         -- OpenCode adapter (translates format, calls core scripts)
    ├── package.json
    └── tsconfig.json
```

## Naming Mappings

### Module requires
| Old | New |
|-----|-----|
| `require("claude-preview")` | `require("code-preview")` |
| `require("claude-preview.diff")` | `require("code-preview.diff")` |
| `require("claude-preview.hooks")` | `require("code-preview.backends.claudecode")` / `require("code-preview.backends.opencode")` |
| `require("claude-preview.changes")` | `require("code-preview.changes")` |
| `require("claude-preview.neo_tree")` | `require("code-preview.neo_tree")` |
| `require("claude-preview.health")` | `require("code-preview.health")` |

### User commands
| Old | New |
|-----|-----|
| `:ClaudePreviewInstallHooks` | `:CodePreviewInstallClaudeCodeHooks` |
| `:ClaudePreviewUninstallHooks` | `:CodePreviewUninstallClaudeCodeHooks` |
| `:ClaudePreviewCloseDiff` | `:CodePreviewCloseDiff` |
| `:ClaudePreviewStatus` | `:CodePreviewStatus` |
| `:ClaudePreviewToggleVisibleOnly` | `:CodePreviewToggleVisibleOnly` |
| `:CodePreviewInstallOpenCodeHooks` | `:CodePreviewInstallOpenCodeHooks` (unchanged) |
| `:CodePreviewUninstallOpenCodeHooks` | `:CodePreviewUninstallOpenCodeHooks` (unchanged) |

### Deprecated aliases (keep for one release)
Old commands should still work but print a deprecation warning pointing to the new name.
- `:ClaudePreviewInstallHooks` -> warns, calls `:CodePreviewInstallClaudeCodeHooks`
- `:ClaudePreviewUninstallHooks` -> warns, calls `:CodePreviewUninstallClaudeCodeHooks`
- `:ClaudePreviewCloseDiff` -> warns, calls `:CodePreviewCloseDiff`
- `:ClaudePreviewStatus` -> warns, calls `:CodePreviewStatus`
- `:ClaudePreviewToggleVisibleOnly` -> warns, calls `:CodePreviewToggleVisibleOnly`

### Highlight groups
| Old | New |
|-----|-----|
| `ClaudePreviewTreeModified` | `CodePreviewTreeModified` |
| `ClaudePreviewTreeCreated` | `CodePreviewTreeCreated` |
| `ClaudePreviewTreeDeleted` | `CodePreviewTreeDeleted` |
| `ClaudePreviewTreeVirtual` | `CodePreviewTreeVirtual` |
| `ClaudePreviewDiffResize` (augroup) | `CodePreviewDiffResize` |

### Shell scripts
| Old | New |
|-----|-----|
| `bin/claude-preview-diff.sh` | `backends/claudecode/code-preview-diff.sh` |
| `bin/claude-close-diff.sh` | `backends/claudecode/code-close-diff.sh` |
| `bin/core-pre-tool.sh` | `bin/core-pre-tool.sh` (stays, shared) |
| `bin/core-post-tool.sh` | `bin/core-post-tool.sh` (stays, shared) |

### Shell script internal references
| Old | New |
|-----|-----|
| `require('claude-preview.changes')` | `require('code-preview.changes')` |
| `require('claude-preview.diff')` | `require('code-preview.diff')` |
| `require('claude-preview.neo_tree')` | `require('code-preview.neo_tree')` |
| `require('claude-preview')` | `require('code-preview')` |

These references exist in `core-pre-tool.sh` and `core-post-tool.sh` (the core scripts).
The Claude adapters have no `require()` calls — they only `exec` the core scripts.

### Hook marker
| Old | New |
|-----|-----|
| `HOOK_MARKER = "claude-preview"` | `HOOK_MARKER = "code-preview"` |

### Notification prefix
| Old | New |
|-----|-----|
| `[claude-preview]` | `[code-preview]` |

### OpenCode package
| Old | New |
|-----|-----|
| `"name": "claude-preview-opencode"` | `"name": "code-preview-opencode"` |
| `opencode-plugin/` directory | `backends/opencode/` directory |

---

## Steps

### Step 1: Rename Lua module directory

Move `lua/claude-preview/` to `lua/code-preview/`.

**Files affected:**
- Directory rename: `lua/claude-preview/` -> `lua/code-preview/`

**Manual test:**
```vim
" Restart Neovim with the plugin loaded
nvim --cmd "set rtp+=/Users/jayshitre/Projects/claude-preview.nvim"

" Verify module loads from new path
:lua print(vim.inspect(require("code-preview")))
" Expected: table with setup function (may error on internal requires -- that's OK at this step)
```

---

### Step 2: Update all internal `require()` calls in Lua files

Replace every `require("claude-preview` with `require("code-preview` across all Lua files.

**Files affected:**
- `lua/code-preview/init.lua` -- requires for hooks, diff, neo_tree
- `lua/code-preview/diff.lua` -- `require("claude-preview").config` (line 365), `require("claude-preview.changes").clear_all()` (line 516), `require("claude-preview.neo_tree").refresh()` (line 517)
- `lua/code-preview/health.lua` -- `require("claude-preview")` for config (line 24)
- `lua/code-preview/neo_tree.lua` -- `require("claude-preview.changes")` (line 3), `require("claude-preview")` for config (line 354)

**Manual test:**
```vim
nvim --cmd "set rtp+=/Users/jayshitre/Projects/claude-preview.nvim"

" Full setup should work without errors
:lua require("code-preview").setup()

" Verify submodules load
:lua print(require("code-preview.diff").is_open())
:lua print(vim.inspect(require("code-preview.changes").get_all()))
```

---

### Step 3: Split `hooks.lua` into `backends/claudecode.lua` and `backends/opencode.lua`

Split the monolithic hooks module into two backend-specific modules.

**`lua/code-preview/backends/claudecode.lua`** gets:
- `scripts_dir()` -- resolves to `backends/claudecode/` (adapter script paths for settings.json)
- `bin_dir()` -- resolves to `bin/` (shared utilities, used for script existence checks)
- `HOOK_MARKER` -- changed to `"code-preview"`
- `LEGACY_HOOK_MARKER` -- `"claude-preview"` (used by `remove_ours()` during transition)
- `settings_path()`, `read_settings()`, `write_settings()`
- `M.install()`, `M.uninstall()`
- **Dual-marker uninstall:** `remove_ours()` must match entries containing either
  `"code-preview"` OR `"claude-preview"` so users who installed with the old name
  can uninstall after upgrading. Remove the legacy check after one release cycle.

**`lua/code-preview/backends/opencode.lua`** gets:
- `plugin_source_dir()` -- resolves to `backends/opencode/`
- `opencode_target_dir()`
- `M.install()`, `M.uninstall()`
- `bin_dir()` -- needed to write `bin-path.txt` during install

**Delete:** `lua/code-preview/hooks.lua` (after splitting)

**Update `init.lua`:** Change requires from `require("code-preview.hooks")` to
`require("code-preview.backends.claudecode")` and `require("code-preview.backends.opencode")`.

**Manual test:**
```vim
nvim --cmd "set rtp+=/Users/jayshitre/Projects/claude-preview.nvim"
:lua require("code-preview").setup()

" Verify backend modules load
:lua print(vim.inspect(require("code-preview.backends.claudecode")))
:lua print(vim.inspect(require("code-preview.backends.opencode")))

" Verify install commands exist
:CodePreviewInstallClaudeCodeHooks
" Expected: hooks written to .claude/settings.local.json (or error if no project)

:CodePreviewInstallOpenCodeHooks
" Expected: plugin files copied to .opencode/plugins/
```

---

### Step 4: Rename user commands and add deprecated aliases

Rename commands in `init.lua` and add deprecated aliases for the old names.

**Files affected:**
- `lua/code-preview/init.lua`

**Manual test:**
```vim
nvim --cmd "set rtp+=/Users/jayshitre/Projects/claude-preview.nvim"
:lua require("code-preview").setup()

" New commands should work
:CodePreviewStatus
:CodePreviewCloseDiff

" Old commands should work but show deprecation warning
:ClaudePreviewStatus
" Expected: status output + "[code-preview] :ClaudePreviewStatus is deprecated, use :CodePreviewStatus" warning

:ClaudePreviewCloseDiff
" Expected: closes diff + deprecation warning

:ClaudePreviewToggleVisibleOnly
" Expected: toggles + deprecation warning
```

---

### Step 5: Move Claude adapters and update core script references

- Move `bin/claude-preview-diff.sh` -> `backends/claudecode/code-preview-diff.sh`
- Move `bin/claude-close-diff.sh` -> `backends/claudecode/code-close-diff.sh`
- Update adapters to reference core scripts at `../../bin/core-pre-tool.sh`
- Update `require('claude-preview.` to `require('code-preview.` in `core-pre-tool.sh` and `core-post-tool.sh`
- Update `bin_dir()` in `backends/claudecode.lua` to resolve to `backends/claudecode/`

**Claude adapter example after move:**
```bash
#!/usr/bin/env bash
# code-preview-diff.sh — PreToolUse hook adapter for Claude Code
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"
export CODE_PREVIEW_BACKEND="claudecode"
exec "$BIN_DIR/core-pre-tool.sh"
```

**Files affected:**
- `backends/claudecode/code-preview-diff.sh` (moved + updated path)
- `backends/claudecode/code-close-diff.sh` (moved + updated path)
- `bin/core-pre-tool.sh` -- rename all `require('claude-preview.` to `require('code-preview.`
- `bin/core-post-tool.sh` -- rename all `require('claude-preview.` to `require('code-preview.`
- `lua/code-preview/backends/claudecode.lua` -- bin_dir() path, script name references

**Manual test:**
```bash
# Verify scripts are executable
ls -la backends/claudecode/
# Expected: code-preview-diff.sh and code-close-diff.sh with +x

# Verify old locations are gone
ls bin/claude-preview-diff.sh bin/claude-close-diff.sh
# Expected: No such file or directory
```
```vim
nvim --cmd "set rtp+=/Users/jayshitre/Projects/claude-preview.nvim"
:lua require("code-preview").setup()

" Reinstall hooks (they should point to new script paths)
:CodePreviewInstallClaudeCodeHooks

" Verify hooks point to new paths
:!cat .claude/settings.local.json | jq .
" Expected: commands point to backends/claudecode/code-preview-diff.sh and backends/claudecode/code-close-diff.sh
```

---

### Step 6: Move OpenCode plugin to `backends/opencode/`

- Move `opencode-plugin/index.ts` -> `backends/opencode/index.ts`
- Move `opencode-plugin/package.json` -> `backends/opencode/package.json`
- Move `opencode-plugin/tsconfig.json` -> `backends/opencode/tsconfig.json`
- Update `require('claude-preview.` strings in core scripts (already done in Step 5)
- Update `package.json` name and description
- Update `backends/opencode.lua` path resolution for `plugin_source_dir()`
- The `bin-path.txt` mechanism remains the same — `install()` writes the absolute `bin/` path

**Files affected:**
- `backends/opencode/index.ts` (moved + rename `CLAUDE_PREVIEW_BACKEND` to `CODE_PREVIEW_BACKEND`)
- `backends/opencode/package.json` (moved + updated name)
- `backends/opencode/tsconfig.json` (moved)
- `lua/code-preview/backends/opencode.lua` -- source dir path

**Manual test:**
```vim
nvim --cmd "set rtp+=/Users/jayshitre/Projects/claude-preview.nvim"
:lua require("code-preview").setup()

:CodePreviewInstallOpenCodeHooks
" Expected: plugin files copied from backends/opencode/ to .opencode/plugins/

:CodePreviewUninstallOpenCodeHooks
" Expected: plugin files removed from .opencode/plugins/
```

---

### Step 7: Rename highlight groups and augroup

Update all `ClaudePreview*` highlight groups and augroup names to `CodePreview*`.

**Files affected:**
- `lua/code-preview/neo_tree.lua` -- highlight group definitions and references (`ClaudePreviewTreeModified`, `ClaudePreviewTreeCreated`, `ClaudePreviewTreeDeleted`, `ClaudePreviewTreeVirtual`)
- `lua/code-preview/diff.lua` -- augroup name `ClaudePreviewDiffResize` (line 437)

**Manual test:**
```vim
nvim --cmd "set rtp+=/Users/jayshitre/Projects/claude-preview.nvim"
:lua require("code-preview").setup()

" Check highlight groups exist
:hi CodePreviewTreeModified
:hi CodePreviewTreeCreated
:hi CodePreviewTreeDeleted
" Expected: each shows the configured colors

" Verify old names don't exist
:hi ClaudePreviewTreeModified
" Expected: "E411: highlight group not found"
```

---

### Step 8: Update notification prefixes and status text

Replace `[claude-preview]` with `[code-preview]` in all `vim.notify()` calls,
status output, and error messages.

**Files affected:**
- `lua/code-preview/init.lua` -- status function title, notify calls
- `lua/code-preview/backends/claudecode.lua` -- all notify messages
- `lua/code-preview/backends/opencode.lua` -- all notify messages

**Manual test:**
```vim
:CodePreviewStatus
" Expected: header says "code-preview.nvim status"
```

---

### Step 9: Update `health.lua`

- Update `start()` text to `"code-preview.nvim"`
- Update script name references (`code-preview-diff.sh`)
- Update hook detection: check for BOTH `"code-preview"` and `"claude-preview"` markers
  in settings.local.json (line 80), so health reports correctly for users who haven't
  re-installed hooks yet. Show a warning if only the old marker is found.
- Update command references in warnings (`:CodePreviewInstallClaudeCodeHooks`)
- Update paths: health.lua needs to find scripts in `backends/claudecode/` now

**Files affected:**
- `lua/code-preview/health.lua`

**Manual test:**
```vim
nvim --cmd "set rtp+=/Users/jayshitre/Projects/claude-preview.nvim"
:lua require("code-preview").setup()

:checkhealth code-preview
" Expected: all checks pass, correct script paths, correct command names in warnings
```

---

### Step 10: Update shell script comments

Update comments in core scripts and shared utilities:
- `bin/core-pre-tool.sh` -- header comment
- `bin/core-post-tool.sh` -- header comment
- `bin/nvim-send.sh` -- example `require('code-preview.diff')` in comment

**Files affected:**
- `bin/core-pre-tool.sh`, `bin/core-post-tool.sh`, `bin/nvim-send.sh`

**Manual test:** N/A (comments only)

---

### Step 11: Update keymap description

Update `<leader>dq` description from `"Close claude-preview diff"` to `"Close code-preview diff"`.

**Files affected:**
- `lua/code-preview/init.lua`

**Manual test:**
```vim
:map <leader>dq
" Expected: description says "Close code-preview diff"
```

---

### Step 12: Update tests

- Rename test directory: `tests/backends/claude/` -> `tests/backends/claudecode/`
- Update all `require('claude-preview.` references in test specs to `require('code-preview.`
- Update test file paths if test helpers reference `bin/claude-preview-diff.sh`
- Update install test assertions (script paths, file lists)
- Rename `CLAUDE_PREVIEW_BACKEND` to `CODE_PREVIEW_BACKEND` in core scripts, adapters, and tests

**Files affected:**
- Directory rename: `tests/backends/claude/` -> `tests/backends/claudecode/`
- `tests/plugin/changes_registry_spec.lua` -- `require("claude-preview.changes")`
- `tests/plugin/diff_lifecycle_spec.lua` -- `require("claude-preview.diff")`, `require("claude-preview.changes")`
- `tests/minimal_init.lua` -- `require("claude-preview").setup()`
- `tests/helpers.sh` -- hook script paths (`claude-preview-diff.sh`), `require('claude-preview')` in nvim setup, temp path prefixes (`claude-preview-test-*`, `claude-diff-*`)
- `tests/run.sh` -- title string `"claude-preview.nvim E2E Test Suite"`, comment header
- `tests/backends/claudecode/test_edit.sh` -- comment header, all `require('claude-preview.*')` in nvim_eval calls
- `tests/backends/claudecode/test_install.sh` -- `require('claude-preview.hooks')`, assertions for script names (`claude-preview-diff.sh`, `claude-close-diff.sh`)
- `tests/backends/claudecode/test_stale_socket.sh` -- `require('claude-preview.diff')`, `claude-preview-diff.sh` reference
- `tests/backends/opencode/test_edit.sh` -- all `require('claude-preview.*')` in nvim_eval calls
- `tests/backends/opencode/test_install.sh` -- `require('claude-preview.hooks')`
- `tests/backends/opencode/harness.ts` -- import path to `opencode-plugin/index.ts` → `backends/opencode/index.ts`
- `bin/core-pre-tool.sh` -- rename env var `CLAUDE_PREVIEW_BACKEND` to `CODE_PREVIEW_BACKEND`
- `bin/core-post-tool.sh` -- rename env var (comment only, not used in logic yet)
- `backends/claudecode/code-preview-diff.sh` -- rename env var
- `backends/claudecode/code-close-diff.sh` -- rename env var
- `backends/opencode/index.ts` -- rename env var (already called out in Step 6)

**Manual test:**
```bash
bash tests/run.sh
# Expected: all tests pass
```

---

### Step 13: Update documentation

- `README.md` -- all references, setup examples, command names, directory structure
- `CLAUDE.md` -- developer notes, file paths, task references
- `PRD.md` -- requirements doc references
- `PRD-neo-tree.md` -- neo-tree design doc references
- `PRD-opencode.md` -- opencode design doc references

**Manual test:** Read through each doc and verify no stale `claude-preview` references remain.

```bash
# Final grep to catch any stragglers (excluding git history)
grep -r "claude-preview" --include="*.lua" --include="*.sh" --include="*.ts" --include="*.md" --include="*.json" .
grep -r "ClaudePreview" --include="*.lua" --include="*.sh" --include="*.ts" --include="*.md" .
# Expected: zero results (or only intentional references like migration notes)
```

---

### Step 14: End-to-end test

Full integration test with Claude Code backend:

1. Restart Neovim: `nvim --cmd "set rtp+=/Users/jayshitre/Projects/claude-preview.nvim"`
2. Run `:lua require("code-preview").setup()`
3. Run `:CodePreviewInstallClaudeCodeHooks`
4. Verify `.claude/settings.local.json` has correct paths (`backends/claudecode/code-preview-diff.sh`)
5. Open Claude Code in a tmux pane, ask it to edit a file
6. Verify diff preview appears in Neovim
7. Accept/reject and verify diff closes
8. Run `:CodePreviewStatus` -- should show hooks installed
9. Run `:checkhealth code-preview` -- all green

Full integration test with OpenCode backend:

1. Run `:CodePreviewInstallOpenCodeHooks`
2. Verify files copied to `.opencode/plugins/`
3. Open OpenCode, trigger an edit
4. Verify diff preview appears
5. Run `:CodePreviewUninstallOpenCodeHooks` -- files removed

---

## Notes

- **Hook marker change:** Users who have existing hooks installed will need to
  re-run the install command. The old `"claude-preview"` marker won't match
  the new `"code-preview"` marker, so `uninstall` won't find old entries.
  **Decision:** `remove_ours()` in `backends/claudecode.lua` checks for BOTH
  `"code-preview"` and `"claude-preview"` markers. `health.lua` also detects
  both, warning if only the old marker is found. Remove legacy checks after
  one release cycle.
- **Deprecated aliases:** Remove after one release cycle.
- **User migration:** Users must update `require("claude-preview")` to
  `require("code-preview")` in their Neovim config and re-run hook install.
- **Core scripts stay in `bin/`:** The unified `core-pre-tool.sh` and
  `core-post-tool.sh` are backend-agnostic and shared. They stay in `bin/`
  alongside other shared utilities. Only the thin backend adapters move to
  `backends/<name>/`.
- **Adapter file count differs by design:** Claude needs 2 adapter scripts
  (hook API requires separate commands per event), OpenCode needs 1 file
  (plugin API exports both hooks from one entry point). Both follow the same
  pattern: translate format and delegate to core scripts.
- **`bin-path.txt` for OpenCode:** During `install_opencode()`, the absolute
  path to `bin/` is written to `bin-path.txt` alongside the installed plugin.
  This lets the OpenCode adapter find the core scripts at runtime.
- **Claude Code adapter path resolution:** After moving to `backends/claudecode/`,
  adapters use `$SCRIPT_DIR/../../bin/core-pre-tool.sh` to reach core scripts.
  `backends/claudecode.lua` needs two resolvers: `scripts_dir()` for adapter
  paths written to settings.json (`backends/claudecode/`), and `bin_dir()` for
  shared utilities (`bin/`).
- **Env var rename:** `CLAUDE_PREVIEW_BACKEND` → `CODE_PREVIEW_BACKEND` with
  values `"claudecode"` or `"opencode"`. Must update core scripts, adapters,
  and test harnesses.
- **Temp file names:** `claude-diff-original` and `claude-diff-proposed` in
  `core-pre-tool.sh` / `core-post-tool.sh` / `tests/helpers.sh` are internal
  temp files with no user visibility. **Decision:** Keep as-is to avoid
  unnecessary churn — they don't leak into user-facing names or configs.
- **Test temp path prefixes:** `claude-preview-test-*` prefixes in
  `tests/helpers.sh` (socket path, mktemp templates) are also internal.
  **Decision:** Rename to `code-preview-test-*` for consistency since we're
  touching these files anyway in Step 12.
