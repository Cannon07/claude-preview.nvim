# Core handler runs in-process inside the user's Neovim, not as a headless worker

Issue #47 phase 3 ports the bash [core handler](../../CONTEXT.md#core-handler) (`bin/core-pre-tool.sh`, ~600 lines) to Lua. The issue text framed the port as a like-for-like swap to a [headless worker](../../CONTEXT.md#headless-worker) (`nvim --headless -l bin/core-pre-tool.lua`). We instead fold the handler into in-process Lua (`lua/code-preview/pre_tool.lua`), invoked through a single [RPC](../../CONTEXT.md#rpc) call from the per-agent [hook entry](../../CONTEXT.md#hook-entry).

The reason: the bash handler is a headless worker only because bash had no other option. Its job — mutating the [changes](../../CONTEXT.md#change) registry, opening [previews](../../CONTEXT.md#preview), driving neo-tree [reveal](../../CONTEXT.md#reveal) — is entirely in-process work that today reaches the user's Neovim through a chain of small RPC calls (`log.state`, `hook_context`, `changes.set`, `neo_tree.refresh`, `diff.show_diff`). Moving the orchestration *into* the Neovim it's already mutating eliminates the cold-start (50–100ms × every proposal) and collapses 5+ RPC round-trips per proposal into one fat call.

## Considered Options

- **A — Lua headless worker** (the issue's literal proposal). `bin/core-pre-tool.lua` spawned per proposal. Pays cold-start every time; keeps the RPC chain. Wins on isolation (handler crashes don't touch the user's session) and lets the handler run with no live Neovim — but the bash version's "degrade safely without nvim" path was always doing nothing useful, so the second win is illusory.
- **B — In-process Lua via one RPC** *(chosen)*. Per-agent hook entry makes a single `nvim --server <socket> --remote-expr 'luaeval(...)'` call into the running Neovim. No cold-start, no intra-handler RPC chatter.

Windows portability — the original motivation for #47 — is satisfied identically by both options. The orchestration logic (the prize of #47) is Lua either way; the only per-OS surface is the thin per-agent hook entry, which needs a `.cmd`/`.ps1` shim on Windows regardless of A vs B.

## Consequences

- The pre-tool pipeline runs on Neovim's main thread. None of the work is CPU-heavy (regex scans of Bash commands, JSON decode, file copies), but a 20-file MultiEdit or ApplyPatch does it all serially during the hook. Acceptable; if it ever bites, individual stages can be deferred with `vim.schedule`.
- If the user's Neovim is unreachable (no nvim running, stale socket, RPC timeout, wrong-cwd instance), the hook exits 0 with no stdout — the plugin **abstains**, and the agent falls back to its native permission/edit flow exactly as if the plugin weren't installed. This preserves the bash version's "no-nvim degradation" path. The plugin enhances when it can; it does not gatekeep when it can't. Hard-failing on unreachable nvim was considered and rejected: a user who tabs away from or quits Neovim mid-session must not get a blocked or frozen agent.
- [Hook context query](../../CONTEXT.md#hook-context-query) becomes a local function call inside `pre_tool.lua`; the RPC entry point survives only for callers that still live outside the user's Neovim (e.g. a backend that hasn't yet flipped to the Lua entry).
- The `apply-edit` / `apply-multi-edit` / `apply-patch` logic moves to `lua/code-preview/apply/{edit,multi_edit,patch}.lua` and is called in-process from `pre_tool.lua`. The `bin/apply-*.lua` files survive as thin shims that `require` the module and forward CLI args, so any external caller invoking the old paths still works. Inlining preserves the cold-start win for the common Edit / MultiEdit / ApplyPatch proposals — leaving them as headless workers would have reintroduced the per-proposal spawn cost the in-process choice was made to eliminate.
- The `bin/` directory's role narrows to thin shims and any genuinely out-of-process tooling. New orchestration and transformation code belongs under `lua/code-preview/`.
