## Summary

- Adds OpenAI Codex CLI as the fourth supported AI backend alongside Claude Code, OpenCode, and Copilot CLI.
- Install writes `.codex/hooks.json` and detects the required `codex_hooks = true` feature flag in `.codex/config.toml` (project or global) — `:CodePreviewStatus` and `:checkhealth` both surface flag state so users can self-diagnose silent-no-op failures.
- Adds shell-write detection to the unified Bash hook: `>` / `>>` / `&>` / `&>>`, `mv X.tmp X`, `cp`, `tee`, and `sed -i` targets are flagged in the changes registry as `bash_modified` / `bash_created` so users get neo-tree feedback for shell-driven edits — important for Codex GPT models, which prefer the atomic-replace idiom (`{ printf …; cat F; } > F.tmp && mv F.tmp F`).
- Fixes ApplyPatch `*** Delete File:` showing the orange "modified" pencil instead of the red "deleted" trash icon.

## What's included

**Codex backend**
- `backends/codex/{code-preview-diff,code-close-diff}.sh` — translate Codex's payload (which delivers `apply_patch` text in `tool_input.command`) into the normalized shape consumed by `bin/core-{pre,post}-tool.sh`. `Bash` passes through.
- `lua/code-preview/backends/codex.lua` — install/uninstall, plus `feature_flag_state()` that checks `.codex/config.toml` (project) and falls back to `~/.codex/config.toml` (global).
- `:CodePreviewInstall/UninstallCodexCliHooks` commands; Codex rows in `:CodePreviewStatus` and `:checkhealth`, including feature-flag detection.

**Shell-write detection (Bash hook)**
- New block in `bin/core-pre-tool.sh` that extracts likely write targets from a Bash command and marks each one `bash_modified` (file exists) or `bash_created` (file doesn't exist) in the changes registry.
- `looks_like_path` filters false positives leaked from quoted strings (e.g. `printf '<!-- … -->\n\n'`); `is_transient_path` skips `.tmp`/`.bak`/`.swp`/`/dev/*`/`/tmp/*`; tilde paths expand to `$HOME` before the relative-path resolver to avoid `$CWD/~/foo`.
- rm-wins reveal precedence — when a command both `rm`s and writes, only the rm branch queues a `defer_fn` reveal so we don't double-fire.
- Acknowledged limitations (in-code comments): `mv -t DST` flag-inverted form, `tee FILE OTHER_FILE` multi-target, and the always-on cost of the detector for read-only Bash invocations.

**Neo-tree integration for shell writes**
- `bash_modified` and `bash_created` render with the same icons/highlights as `modified` and `created` for v1 — documented in `neo_tree.lua` as a deliberate simplification.
- New `changes.clear_by_statuses({...})` helper; the Bash post-hook now batches `deleted` + `bash_modified` + `bash_created` cleanup into a single RPC instead of three.

**ApplyPatch delete fix**
- `show_diff` accepts an optional `action` hint; the Codex/ApplyPatch hook passes `"delete"` for `*** Delete File:` directives. `mark_change_and_reveal` only emits `"deleted"` when explicitly told — a legitimate truncate-to-empty edit still shows as `modified`.
- `vim.loop.fs_stat` switched to `vim.uv.fs_stat` in `diff.lua` to match the convention used elsewhere in the codebase.

**Docs / housekeeping**
- README: Codex Quick Start section, backend list updated to all four, Neovim floor aligned to `>= 0.10` (matches actual `vim.uv` usage), `:checkhealth` wording, test-runner examples for `backends/copilot` and `backends/codex`.
- `.gitignore`: ignore `test_output.log`.

## Tests

22 new shell tests in the Codex suite plus 2 plenary regressions:

- `tests/backends/codex/test_install.sh` — `.codex/hooks.json` layout, idempotent re-install, user-authored Pre/PostToolUse entries survive install/uninstall, feature-flag detection (project + global, missing flag, no config.toml).
- `tests/backends/codex/test_edit.sh` — Codex `apply_patch` translation, Bash `rm`, shell-write detection (modified/created/atomic-replace/.tmp filter), HTML-comment false-positive guard, read-only no-op, noise-tool skip, malformed-payload skip.
- `tests/backends/codex/test_apply_patch.sh` — Update / Add / mixed Update+Add+Delete.
- `tests/plugin/diff_lifecycle_spec.lua` — `show_diff(..., "delete")` marks the file `deleted`; truncate-to-empty without an action stays `modified` (regression guard against the false-positive that the action hint replaced).
- `test_install_preserves_user_hooks` extended to assert PostToolUse mirroring (was previously only checking PreToolUse).

## Test plan

- [ ] `bash tests/run.sh all` passes locally
- [ ] `./tests/run_lua.sh diff_lifecycle` — plenary regressions pass
- [ ] Install/uninstall cycle in a real Codex CLI session, with and without `codex_hooks = true`
- [ ] `:CodePreviewStatus` and `:checkhealth code-preview` correctly report flag state for: project config, global config (`~/.codex/config.toml`), missing flag, no config file
- [ ] Codex `apply_patch` Update / Add / Delete — diffs open on pre, close on accept, `*** Delete File:` shows the red trash icon in neo-tree
- [ ] Codex Bash atomic-replace (`{ … } > F.tmp && mv F.tmp F`) — neo-tree shows the orange pencil on `F` during the approval window, clears on post
