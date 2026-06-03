# Handoff — Windows shell write/delete detection (issue #46 follow-up)

**For: Claude Code on the Windows machine.** You can run PowerShell, named pipes,
and Windows nvim — which is exactly why this task is yours. The prior work was
done on macOS and could not see what Claude Code actually emits on Windows.

This is a **follow-up to the merged claudecode Windows slice** (`#73`, squash
commit `ead0c2c` on `main`). Branch: `feat/shell-detect-windows`.

## The bug

On Windows, deleting a file (and other shell writes) does **not** mark neo-tree.
Claude Code's `Bash` tool emits **PowerShell** (`Remove-Item …`) instead of `rm`,
and our detector only understands Unix commands + Unix paths, so it finds nothing.

The preview path (Edit/Write/MultiEdit) already works on Windows — this is the
**Tier-1 change-indicator** path for shell proposals only (see CONTEXT.md
[Tier 1 / Tier 2], [Status], [Origin prefix]).

## Read first

- `lua/code-preview/pre_tool/bash_detect.lua` — the whole detector. Unix-only on
  two axes: **command vocabulary** (`rm`, `>`/`>>`, `mv`, `cp`, `tee`, `sed -i`)
  and **path resolution** (`resolve()`/`looks_like_path()` only handle `/`-absolute
  and `~/`; no `C:\`, backslashes, or `%USERPROFILE%`).
- `lua/code-preview/pre_tool/normalisers.lua` — confirms routing: `tool_name="Bash"`
  → `handle_bash` → `bash_detect`. Routing is fine; the detector is the gap.
- `tests/plugin/pre_tool_bash_detect_spec.lua` (CI-excluded on Windows) and the
  `bash_modified` case in `pre_tool_handle_spec.lua` (marked `pending` on Windows)
  — both are this task's to re-enable with Windows-path awareness.
- `docs/adr/0007-...` and `CONTEXT.md` for the cross-OS principles.

## STEP 0 — gather ground truth (only you can do this)

With `debug = true` (tail `%LOCALAPPDATA%\nvim-data\code-preview.log`), capture the
exact `tool_name` and raw command string Claude Code emits on Windows for:
- a **delete** (expect `Remove-Item …`?),
- a **file write/redirect** (`Set-Content`? `Out-File`? `Add-Content`? `>`?),
- a **move** and a **copy** if the agent uses them.

Confirm the `tool_name` is still `"Bash"` (if not, the normaliser tool-map needs a
Windows entry too). **Paste these samples into the PR** — they are the spec inputs.

## Design — split two independent axes (decided; per the architecture review)

The detector entangles two axes, and they are **not** the same as "OS" — a
git-bash shell on Windows has POSIX grammar with Windows-ish paths. So do **not**
add a blanket "Windows branch" and do **not** cut the module by OS:

1. **Path conventions** — `resolve()` / `looks_like_path()` / `is_transient()`:
   today only `/`-absolute, `~/`, `$HOME`, `/dev/`. Windows needs `C:\` / `C:/`,
   UNC `\\…`, backslash or forward slash, `%TEMP%` / `%USERPROFILE%`.
2. **Command grammar** — which verbs/operators write or delete: POSIX
   (`rm`, `>`/`>>`, `mv`, `cp`, `tee`, `sed -i`) vs PowerShell.

**The shape to build (this is decided — but keep it all behind the current
`M.detect(cmd, cwd)` signature; callers must not change):**

- **Rename `bash_detect` → `shell_detect`** so the interface stops lying. Update
  the require site (`pre_tool/init.lua`), the spec filename, and the CI Windows
  exclusion name.
- **Extract a path-convention seam** (`resolve`/`looks_like_path`/`is_transient`
  → a small adapter): a Unix impl (as today) + a Windows impl. This is the
  highest-value, lowest-risk extraction and is needed *regardless* of which shell
  the agent uses.
- **Make the command matchers table-shaped** (verb / redirect / mv-cp-tee-sed) so
  a grammar slots in as data, not as scattered `if` branches. Keep the POSIX
  grammar **byte-identical** in behaviour (its edge cases come from real bugs).
- **Add a PowerShell grammar adapter — but only after STEP 0 confirms** the
  Windows Bash tool emits PowerShell (your `Remove-Item` observation says it
  does; STEP 0 nails the exact cmdlets/aliases/params). Starting vocabulary to
  confirm/expand from real samples, case-insensitive:
  - Delete → `deleted`: `Remove-Item`/`ri`/`rm`/`del`/`erase`/`rd`/`rmdir`
    (+ `-Path`, `-Recurse`, `-Force`, positional).
  - Write → `bash_created`/`bash_modified`: `Set-Content`/`sc`, `Out-File`,
    `Add-Content`/`ac`, `Tee-Object`/`tee`, and `>`/`>>`.
  - Move/Copy → write target: `Move-Item`/`mi`/`move`/`ren`, `Copy-Item`/`cpi`/`copy`/`cp`.
  - Separators: `;`, `|`, newlines; `&&`/`||` are PS7-only (the hook runs under
    **5.1**). `-Path` may take a comma-list / wildcards.
  - Keep `bash_*` origin-prefix semantics from [Status]/[Origin prefix] unchanged.

**Out of bounds for this PR:** do **not** introduce a per-OS file split, an
integration registry, or an install engine. The architecture review **deferred**
all of that as uncoupled cleanup; your scope is the rename + the two seams + the
confirmed grammar, nothing wider.

## Also in this PR (small, decided)

`lua/code-preview/diff.lua` (~line 60): the `reveal_root = "git"` path runs a
string shell command with `2>/dev/null` (POSIX-only; misbehaves under Windows
cmd). Fix to list-form, no redirect:
`vim.fn.systemlist({"git","-C",parent,"rev-parse","--show-toplevel"})` + the
existing `shell_error` check. Verify on both OSes.

## Testing bar

- Re-enable the excluded/pending bash specs with **portable** paths (no hardcoded
  `/tmp`, no `os.getenv("HOME")` assumptions — guard or branch per OS).
- Add Windows-grammar specs from your STEP 0 samples.
- macOS/Linux specs must stay green (the detector must remain correct on Unix).
- The CI `windows-test` job (now on `main`) excludes `pre_tool_bash_detect_spec.lua`
  by filename. After the rename, update that exclusion to the new spec name, then
  drop it entirely once the spec passes on Windows.

## Out of scope

opencode's `vim.fn.system({"cp",…})` (Windows blocker) and the codex/copilot
Windows shims belong to the per-agent rollout PRs, not this one.

## Suggested skills

- `tdd` — STEP 0 samples → failing specs → grammar. Good fit here.
- `verify` — confirm a real delete marks neo-tree on Windows end-to-end.

## Before merge

Remove this file, and remove `pre_tool_bash_detect_spec.lua` from the CI Windows
exclusion if it now passes.
