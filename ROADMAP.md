# code-preview.nvim — Roadmap

Planned work items, roughly in priority order.

---

## Configurable Logging

**Status:** Next up (PR 2)

Add opt-in debug logging following Neovim plugin conventions.

- Create `lua/code-preview/log.lua` — thin logging module, no external dependencies
- Add `debug = false` config option to enable/disable
- Log file location: `vim.fn.stdpath("log") .. "/code-preview.log"`
- Use `vim.notify()` for WARN/ERROR (user-facing), file logging for DEBUG/INFO
- Wire into `diff.lua` (replace the ad-hoc logging removed in v2.0.0)
- Wire into `neo_tree.lua` — setup, virtual node injection, reveal
- Shell scripts read debug flag from `hook_context()` RPC, skip logging when disabled

## diff.lua Refactoring

**Status:** Planned (after logging PR)

`diff.lua` has grown too large after the multi-tab rewrite. Break it into smaller modules:

- Inline layout logic (build_inline_diff, show_inline_diff, statuscolumn)
- Tab/vsplit layout logic
- Active diff management (active_diffs table, close_for_file, close_diff_and_clear)
- Neo-tree bridge (mark_change_and_reveal)

## Neo-tree Test Harness

**Status:** Planned

Add neo-tree + nui.nvim to the test environment for proper unit testing of neo-tree interactions.

- Clone neo-tree and nui.nvim into `deps/`
- Add to rtp in `tests/minimal_init.lua`
- Enables tests for: indicator lifecycle, virtual node injection, reveal, stale tabpage regression
- Currently neo-tree interactions are only tested via E2E shell tests, not Plenary unit tests

## Inline Apply (v3)

**Status:** Design phase — see [PRD-inline-apply.md](PRD-inline-apply.md)

Apply proposed changes directly to real buffers instead of temp files. Original content is backed up for revert on reject. Includes a neo-tree "Proposed Changes" view.

## New Backends

### Copilot CLI

**Status:** In progress — hook system is similar to existing backends, should be straightforward

### Pi Coding Harness (pi.dev)

**Status:** Evaluating — need to investigate hook system

---

## Completed (v2.0.0)

- Multi-tab simultaneous diffs (#37)
- Unified backend architecture — Claude Code + OpenCode (#33)
- Rename claude-preview -> code-preview (#34, #35)
- `visible_only` mode (#24)
- Configurable neo-tree reveal (#21)
- E2E test suite with CI (#19)
- Stale socket recovery (#17)
