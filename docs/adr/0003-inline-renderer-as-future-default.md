# The inline renderer is the strategic direction; side-by-side is legacy

The plugin has two preview [renderers](../../CONTEXT.md#renderer). The inline renderer is where new rendering features land; the side-by-side renderer is retained for users who depend on it but is no longer being invested in. The default [layout](../../CONTEXT.md#layout) (`"tab"`) still uses side-by-side today — flipping the default to `"inline"` is a future migration, not a current one.

The reason: inline already does things side-by-side cannot reasonably do — character-level highlights, `]c`/`[c` navigation inside the diff buffer, a custom statuscolumn showing old|new line numbers — and it occupies a single window, which fits better with the rest of a typical Neovim workflow (file tree, terminal, sidebar). Side-by-side relies on Neovim's built-in `:diffthis`, which is robust but offers no extension surface for plugin-specific UX.

## Considered Options

- **Keep both as first-class peers indefinitely.** Rejected: doubles the surface that any future rendering work has to cover (extmark highlights, statuscolumn integration, keymaps). Two equally-maintained renderers is two backlogs.
- **Delete the side-by-side renderer.** Rejected for now: users have `layout = "tab"` baked into their configs, and `:diffthis` is genuinely battle-tested. A hard removal would force a migration without a clean upgrade signal.
- **Inline is the future, side-by-side is legacy** *(chosen)*. Side-by-side first reaches a *feature floor* with inline — anything inline can do that also makes sense for two side-by-side windows (e.g. character-level highlights) gets back-ported. After that point, no new direction-setting features land in side-by-side; it stays available, stable, and ungrowing.

## Consequences

- New direction-setting work (e.g. word-level highlight tuning, fold support, conflict-marker visualisation) lands in the inline path and is not back-ported to side-by-side. Feature-floor parity (the inline features that translate naturally to a two-window view, e.g. character-level highlights) *does* get back-ported once, then side-by-side is closed for further additions.
- Bug fixes against the side-by-side renderer are still in scope — "legacy" means "no new direction," not "abandoned."
- Items that don't translate to side-by-side at all (the custom statuscolumn with old|new line numbers, the inline-specific `]c`/`[c` keymaps that duplicate `:diffthis`'s built-ins) are *not* part of the feature floor and don't need ports.
- A future ADR (or this one, superseded) will record the default flip. That decision needs at least: the inline renderer reaching feature parity for everything users actually rely on, and a deprecation window communicated in release notes.
- The `lua/code-preview/diff.lua` split (referenced in the user's memory note) should respect this asymmetry: extract the inline renderer cleanly so it can grow, and let the side-by-side path stay as a thin wrapper around `:diffthis`.
