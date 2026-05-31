<!-- Status: superseded by ADR-0007 -->
<!-- This ADR's central prediction (OpenCode would drop bash by going shim-free in TS)
     was revised by #46: OpenCode drops bash *on Windows* by switching to the shared
     PowerShell shim, not by owning a TS-native discovery path. See ADR-0007. -->

# OpenCode's integration keeps the bash shim, deferring OS-independence to issue #46

Issue #47 phase 3 flips OpenCode's [hook entry](../../CONTEXT.md#hook-entry) from `execSync`ing the bash [core handler](../../CONTEXT.md#core-handler) to a single [RPC](../../CONTEXT.md#rpc) into the in-process Lua orchestrator (see [ADR-0005](0005-core-handler-runs-in-process.md)). The natural next question: OpenCode's plugin is TypeScript, which runs natively on Windows. Should the flip also make OpenCode's integration the *first* bash-free [integration](../../CONTEXT.md#integration) — TS calls `nvim --server` directly, or speaks msgpack-rpc, with [socket discovery](../../CONTEXT.md#socket-discovery) reimplemented in TS?

We decided no. The TS plugin continues to `execSync` a thin `backends/opencode/code-preview-diff.sh` shim that sources `bin/nvim-socket.sh` and `bin/nvim-call.sh`, identical in shape to the claudecode shim.

## Considered Options

- **TS-native discovery** — reimplement the pidfile read, the `/var/folders/*/T/nvim.*/0` / `/tmp/${NVIM_APPNAME}.*/0` / `$XDG_RUNTIME_DIR` glob fallbacks, the cwd-matching tiebreak, and the stale-socket probe in TypeScript. Pro: OpenCode becomes the first integration that doesn't need bash. Con: two divergent discovery implementations — every change to `bin/nvim-socket.sh` (e.g. issue #47 phase 1's pidfile work) has to land twice and stay in sync.
- **JS msgpack-rpc client** — add `neovim` or similar to the OpenCode plugin's dependencies and speak the protocol directly. Same divergent-implementation problem, plus a new runtime dependency to manage.
- **Bash shim** *(chosen)* — claudecode's pattern. One discovery implementation; OpenCode pays a bash dependency.

## Consequences

- OpenCode's integration still requires bash to be on `PATH`, which is the very thing issue #47 was originally opened to fix for Windows users. The Windows story for OpenCode users does not improve in this phase.
- Issue #46 (centralised RPC/discovery rewrite) inherits exactly one target to port, not two. When #46 lands, OpenCode and claudecode flip together.
- This ADR is **not** a claim that bash is the right end state for OpenCode. It is a deliberate deferral: the TS plugin's natural cross-platform reach is being held back so that #46 has a single discovery implementation to replace. Once #46 ships, OpenCode is expected to be among the first integrations to drop the bash dependency.
