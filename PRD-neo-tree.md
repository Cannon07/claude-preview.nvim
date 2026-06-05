# Neo-tree Integration — Product Requirements Document

## Overview

Add optional neo-tree integration to code-preview.nvim so that proposed file
changes from Claude Code are visually indicated in the existing file tree.
When Claude proposes an edit, the affected file gets a status icon/highlight
in neo-tree — similar to how git status markers work today.

## Motivation

The diff tab already answers "what changed in this file?" but when Claude
touches multiple files (common for refactors), users have no overview of
*which* files are affected. A tree-level indicator solves this at a glance,
without leaving the editor or opening each diff individually.

## Phased Approach

### V1 — Highlight existing files (this PR)

Decorate files in the **existing** neo-tree filesystem tree with a status
icon when Claude proposes a change. No separate tree, no new source.

**What the user sees:**

```
 lua/
   claude-preview/
     init.lua          󰏫    <-- modified by Claude
   new-module.lua       <-- new file proposed by Claude
   utils.lua
```

**Design decisions:**

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Dependency on neo-tree | Soft/optional (`pcall` guard) | Plugin works without neo-tree |
| Separate tree? | No — decorates existing filesystem tree | Less UI clutter, familiar location |
| Pattern to follow | Same as `git_status` component | Proven, documented, minimal code |
| User opt-in | User adds `claude_status` to renderer config | Explicit, no surprise side effects |

---

### V2 — Ghost nodes for new files (future)

Show proposed new files/directories as virtual nodes in the tree, even
before they exist on disk. These would appear dimmed or with a distinct
icon to indicate they are proposed, not yet created.

**Challenges:**
- Neo-tree's filesystem source scans the disk; virtual nodes require
  injecting items into the tree data before render
- Need to handle the case where the file is accepted (becomes real) or
  rejected (node disappears)
- Directory creation proposals need parent directories expanded/created
  as virtual nodes too

**Likely approach:**
- Use neo-tree's `BEFORE_RENDER` event to inject synthetic nodes into
  `state.tree` for paths that don't exist on disk yet
- Mark them with a flag so the component can render them distinctly

---

### V3 — Clickable tree nodes open diff (future)

Clicking a file with a `claude_status` indicator opens the diff preview
for that specific file. This connects the tree overview with the detailed
diff view.

**Requirements:**
- Store proposed content (or temp file paths) per file in the changes
  registry, not just the status string
- Add a custom neo-tree command/action that calls `show_diff()` with
  the stored paths
- Handle the case where the diff is already open for a different file

---

## V1 Implementation Detail

### Architecture

```
Claude CLI (tmux)                  Neovim
      |                               |
  PreToolUse hook fires                |
      |                               |
  claude-preview-diff.sh ----RPC----> changes.set(path, "modified"|"created")
      |                               |  --> neo-tree refresh (tree re-renders)
      |                               |  --> show_diff() (existing behavior)
      |                               |
  PostToolUse hook fires               |
      |                               |
  claude-close-diff.sh ---RPC------> changes.clear(path)
      |                               |  --> neo-tree refresh
      |                               |  --> close_diff() (existing behavior)
```

### New files

| File | Purpose |
|------|---------|
| `lua/claude-preview/changes.lua` | Registry: tracks `{ [abs_path] = status }` |
| `lua/claude-preview/neo_tree.lua` | Neo-tree integration: event subscription, component registration |

### Modified files

| File | Change |
|------|--------|
| `lua/claude-preview/init.lua` | Call `neo_tree.setup()` from `setup()` if neo-tree available |
| `bin/claude-preview-diff.sh` | Add RPC call to `changes.set()` with file status |
| `bin/claude-close-diff.sh` | Add RPC call to `changes.clear()` |

### Module: `changes.lua`

Simple key-value registry mapping absolute file paths to their proposed
change status.

```
API:
  changes.set(filepath, status)     -- status: "modified" | "created"
  changes.clear(filepath)           -- remove single entry
  changes.clear_all()               -- reset everything
  changes.get(filepath)             -- returns status or nil
  changes.get_all()                 -- returns full table
```

### Module: `neo_tree.lua`

Handles all neo-tree interaction behind a `pcall` guard.

**Responsibilities:**
1. Subscribe to neo-tree's `BEFORE_RENDER` event to inject
   `state.claude_status_lookup` from the changes registry
2. Register a `claude_status` component that reads the lookup and
   returns `{ text, highlight }` for affected nodes
3. Provide a `refresh()` helper that triggers neo-tree filesystem refresh
4. Define highlight groups: `ClaudePreviewTreeModified`, `ClaudePreviewTreeCreated`

**Component behavior:**
- Reads `state.claude_status_lookup[node.path]`
- `"modified"` -> icon `󰏫` with modified highlight
- `"created"` -> icon `` with added highlight
- `nil` -> returns `{}` (no decoration)

### Shell hook changes

**`claude-preview-diff.sh`** — after computing the diff, before sending
`show_diff()`:

```bash
# Determine status
if [[ -s "$ORIG_FILE" ]]; then
  STATUS="modified"
else
  STATUS="created"
fi

nvim_send "require('claude-preview.changes').set('$FILE_PATH_ESC', '$STATUS')"
```

Then after `show_diff()`, trigger a neo-tree refresh:

```bash
nvim_send "pcall(function() require('claude-preview.neo_tree').refresh() end)"
```

**`claude-close-diff.sh`** — before `close_diff()`:

```bash
nvim_send "require('claude-preview.changes').clear_all()"
nvim_send "pcall(function() require('claude-preview.neo_tree').refresh() end)"
```

### User configuration

User adds the component to their neo-tree renderer config:

```lua
require("neo-tree").setup({
  filesystem = {
    renderers = {
      file = {
        { "indent" },
        { "icon" },
        { "name" },
        { "claude_status" },  -- add this line
        { "git_status" },
      },
    },
  },
})
```

### Config additions to `setup()`

```lua
neo_tree = {
  enabled = true,           -- set false to disable even if neo-tree is installed
  refresh_on_change = true, -- auto-refresh tree when changes are set/cleared
  symbols = {
    modified = "󰏫",
    created  = "",
  },
  highlights = {
    modified = "NeoTreeGitModified",  -- reuse familiar colors
    created  = "NeoTreeGitAdded",
  },
},
```

### Testing

1. Open Neovim with neo-tree and claude-preview loaded
2. Run `:lua require("claude-preview.changes").set(vim.fn.expand("%:p"), "modified")`
3. Verify the current file gets the `󰏫` icon in neo-tree
4. Run `:lua require("claude-preview.changes").clear_all()`
5. Verify the icon disappears
6. End-to-end: ask Claude to edit a file, verify icon appears in tree
   alongside the diff tab
