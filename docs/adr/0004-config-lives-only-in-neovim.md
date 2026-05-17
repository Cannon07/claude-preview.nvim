# Config lives only in the running Neovim; the bash layer carries none of its own

The plugin's config (`M.config` in `lua/code-preview/init.lua`) is the single source of truth. The bash [core handler](../../CONTEXT.md#core-handler) does not read user config files, environment variables, or a cached copy on disk — every config value it needs is fetched at hook time via a [hook context query](../../CONTEXT.md#hook-context-query) RPC into the running Neovim. If Neovim is unreachable, the bash handler degrades to a safe minimum (no logging, no [review gate](../../CONTEXT.md#review-gate), no visibility filtering) and proceeds.

The reason: keeping a second copy of config on the bash side creates two ways to be wrong. The user changes `diff.visible_only` at runtime via `:CodePreviewToggleVisibleOnly`; a file-cached copy would have to be invalidated. The user reloads their `init.lua` and changes `defer_claude_permissions`; the cached file is now stale. RPC-on-demand sidesteps the entire cache-coherency problem at the cost of one round-trip per hook.

## Considered Options

- **Cache config in a JSON file under `stdpath('cache')`.** Rejected: requires invalidation on every config change (runtime toggle, `setup()` re-call, `:source` of init.lua), and the staleness window is silent — the bash side would happily make decisions on yesterday's config.
- **Read config from environment variables exported at `setup()`.** Rejected: env vars only flow forward to processes spawned *after* the export. The bash handler is spawned by the agent, not by Neovim, so it inherits the agent's environment, not Neovim's.
- **Query Neovim at hook time** *(chosen)*. Always reflects current config; trades one RPC round-trip for cache-coherency freedom.

## Consequences

- Per-hook latency includes at least one RPC round-trip (often two: `log.state` early + `hook_context` later). Acceptable today; if the cost ever bites, the two queries can be merged into one.
- The bash handler's behaviour without Neovim is a real fallback path, not a bug — it must remain safe and silent. Tests should exercise the "no nvim" branch.
- After issue #47 phases 3 and 4, the [core handler](../../CONTEXT.md#core-handler) runs as Lua via `nvim --headless -l`. The hook-context-query pattern still applies, but the call becomes an in-process function call rather than an RPC. The principle (config in Neovim, fetched on demand) does not change.
- New config keys that the bash side might need must be added to `hook_context()`'s return shape — not silently exported to the environment or written to a side file.
