# code-preview.nvim — Developer Notes

### Testing

```bash
nvim --cmd "set rtp+=/Users/jayshitre/Projects/claude-preview.nvim"
nvim --headless -l bin/apply-edit.lua <args>
```

**Important:** After making code changes, do NOT immediately edit a file to
trigger a test. The user must restart Neovim first to pick up the new code.
Wait for the user to confirm they have restarted and ask you to make a test
edit before suggesting any changes.

---

## Neo-tree Integration (v1.1.0)

See `PRD-neo-tree.md` for full design document including v2/v3 roadmap.

### Tasks

- [ ] Task 8: Changes registry module (`lua/code-preview/changes.lua`)
  - Key-value store: `{ [abs_path] = "modified" | "created" }`
  - API: `set()`, `clear()`, `clear_all()`, `get()`, `get_all()`
  - Pure Lua, no dependencies
  - **Test:** `:lua` calls to set/get/clear, verify state

- [ ] Task 9: Neo-tree integration module (`lua/code-preview/neo_tree.lua`)
  - All neo-tree interaction behind `pcall` guard (soft dependency)
  - Subscribe to `BEFORE_RENDER` event to inject `state.code_preview_status_lookup`
  - Register `code_preview_status` component (reads lookup, returns icon + highlight)
  - `refresh()` helper to trigger neo-tree filesystem re-render
  - Define highlight groups: `CodePreviewTreeModified`, `CodePreviewTreeCreated`
  - **Test:** Set a change via `changes.set()`, verify icon appears in neo-tree

- [ ] Task 10: Wire up `setup()` and config
  - Add `neo_tree` section to default config (enabled, symbols, highlights)
  - Call `neo_tree.setup()` from `init.lua setup()` when neo-tree is available
  - **Test:** `:CodePreviewStatus` reflects neo-tree integration state

- [ ] Task 11: Shell hook changes
  - `code-preview-diff.sh`: call `changes.set(path, status)` + `neo_tree.refresh()`
  - `code-close-diff.sh`: call `changes.clear_all()` + `neo_tree.refresh()`
  - Detect `"created"` vs `"modified"` based on whether original file is empty
  - **Test:** End-to-end — Claude proposes edit, icon appears in tree, clears on accept/reject

- [ ] Task 12: Documentation
  - Update README with neo-tree setup instructions (renderer config snippet)
  - Document config options for neo-tree section
  - Update CLAUDE.md key files table

### Design Decisions

- **Soft dependency** — neo-tree is optional; all interaction guarded by `pcall`
- **No separate tree** — decorates the existing filesystem source
- **Same pattern as git_status** — inject lookup into state via `BEFORE_RENDER`, component reads it
- **User adds component to renderer** — explicit opt-in, no surprise side effects

---

## Key Notes

- Backend modules (`backends/claudecode.lua`, `backends/opencode.lua`) use `debug.getinfo(1, "S").source` to locate `bin/`
- Highlights are lazy-initialized inside `show_diff()`, not at module load
- `apply-edit.lua` / `apply-multi-edit.lua` run via `nvim --headless -l` (no Python)

---

## Agent skills

### Issue tracker

Issues live in the `Cannon07/claude-preview` GitHub repo; skills use the `gh` CLI. See `docs/agents/issue-tracker.md`.

### Triage labels

Default canonical label vocabulary (`needs-triage`, `needs-info`, `ready-for-agent`, `ready-for-human`, `wontfix`). See `docs/agents/triage-labels.md`.

### Domain docs

Single-context layout — `CONTEXT.md` and `docs/adr/` at the repo root. See `docs/agents/domain.md`.
