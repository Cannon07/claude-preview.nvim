# One parameterized hook entry per OS, not one per agent

Status: accepted

Each agent integration had its own pair of [hook entry](../../CONTEXT.md#hook-entry) shims (`backends/<agent>/code-{preview,close}-diff.{sh,ps1}`). Post-[#47](0005-core-handler-runs-in-process.md) these were near-identical — read stdin, optionally fast-path-filter noisy tools, discover the running Neovim, splice the payload, make one [RPC](../../CONTEXT.md#rpc) — differing only in *data*: the backend name, the pre/post event, and which tools the fast-path filter drops. Extending that per-agent shape to Windows (a `.ps1` per agent) would have reached 4 agents × 2 OSes × 2 events ≈ 16 near-identical files, each carrying its own copy of the abstain contract and the verbatim-splice invariant.

We collapse the hook entry to **one parameterized shim per OS** — `bin/hook-entry.sh` and `bin/hook-entry.ps1` — invoked as `hook-entry <backend> <pre|post>`. The fast-path filter becomes a backend-keyed branch inside the shim (only codex/copilot need one; claudecode filters via its settings matcher, opencode via its TS allowlist); the `pre_tool.normalisers` tool map remains the source of truth. The OS branch that selects the shim and builds the command is centralised in `lua/code-preview/platform.lua` (`script_ext` / `hook_command` / `make_executable` / `shim_dependency`), replacing logic that was duplicated across every installer and `health.lua`.

## Considered Options

- **Keep per-agent shims** — rejected: 16 copies of the same glue, so every change to the abstain/splice contract (exactly the kind ADR-0007 keeps revising) lands 16 times. The per-agent seam was hypothetical — no agent has ever needed different shim *logic*.
- **One shim per OS *and* event (4 files)** — acceptable fallback; rejected in favour of folding the trivial event axis into an argument.
- **One shim per OS (2 files)** *(chosen)* — the OS axis is the only real axis of variation, because it is a language boundary (bash vs PowerShell).

## Consequences

- Adding the remaining Windows agents is "register a name," not "write more `.ps1` files." `backends/` now holds only OpenCode's TS plugin; the per-agent shim directories are gone.
- This extends [ADR-0007](0007-windows-shim-via-shared-powershell-discovery.md)'s "one discovery implementation per OS" to "one hook entry per OS."
- The per-agent customisation seam is *defaulted, not abolished*: a future agent that genuinely needs bespoke pre-processing can still ship its own shim and the installer point at it. We stop paying for the seam until a second adapter proves it real.
- **Copilot** invokes the shim through its `bash` config field, so it always uses `hook-entry.sh` (the PowerShell-wrapped command form doesn't apply); Copilot-on-Windows would need git-bash and stays deferred.
- **Risk (to validate on Windows):** the installed command passes `<backend> <event>` as positional arguments to `powershell -File hook-entry.ps1`. Windows PowerShell 5.1 lacks `PSNativeCommandArgumentPassing`; the args are simple alphanumeric tokens (no spaces/quotes), so the risk is low, but it must be confirmed on a real box before the Windows side of this is trusted.
