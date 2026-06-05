# PRD: Inline Apply — Direct Buffer Changes with Review Queue

## Problem

Current diff preview uses temporary files. This causes:
- Navigating away from a diff tab loses the preview
- Temp file collisions during rapid multi-file edits
- No persistent view of all pending changes across files

## Core Idea

Apply proposed changes directly to the actual file/buffer instead of showing them in temp files. The original content is backed up so changes can be reverted on reject.

## High-Level Flow

1. **Pre-hook** — Apply proposed changes to the real buffer, store original content for revert, mark file as "pending review" in neo-tree
2. **Review** — User navigates freely via neo-tree; any marked file shows the applied changes with diff highlights (similar to git gutter)
3. **Accept (post-hook)** — Keep the changes, clear the marker
4. **Reject / manual close** — Revert buffer to original content, clear the marker

## Neo-tree "Proposed Changes" View

- New source or filter (like git status tab) showing only files with pending changes
- User can cycle through pending files to review
- Markers clear as files are accepted via CLI post-hook
- When all files are accepted/rejected, the view empties

## Key Design Questions (for later)

- Revert mechanism: buffer-only undo vs stored original content?
- What happens if the user manually edits a file with pending changes?
- Should the buffer be read-only while changes are pending?
- How to handle accept/reject for individual hunks vs whole file?
- Interaction with undo history (`u` in nvim)

## Related

- GitHub issue: navigating away loses diff preview
- Current neo-tree integration: `PRD-neo-tree.md`
