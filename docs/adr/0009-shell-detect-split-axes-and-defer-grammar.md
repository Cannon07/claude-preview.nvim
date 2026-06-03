# Shell write/delete detection splits path-convention from command-grammar; the PowerShell grammar is deferred

Status: accepted

Windows support (issue #46) needs the Tier-1 shell-write/delete detector (`pre_tool/bash_detect.lua`, which feeds the [change](../../CONTEXT.md#change) [status](../../CONTEXT.md#status) values `deleted` / `bash_modified` / `bash_created`) to handle Windows. The obvious framings — "make it per-OS" or "add a Windows branch" — are both wrong, because the detector entangles **two independent axes that do not align onto OS**: *path conventions* (`/`-absolute, `~/`, `/dev/`) and *command grammar* (which verbs/operators write or delete: `rm`, `>`, `mv`, `cp`, `tee`, `sed -i`). A git-bash shell on Windows has POSIX grammar with Windows-shaped paths; a PowerShell shell has PowerShell grammar with Windows paths — so OS is not the seam.

We therefore: rename `bash_detect` → `shell_detect` (behind the unchanged `M.detect(cmd, cwd)` interface); extract a **path-convention adapter** (Unix today, Windows added now); make the command matchers **table-shaped** so a second grammar slots in as data; and **defer building the PowerShell grammar** until an empirical finding confirms which shell a given agent's Bash tool actually invokes on Windows (the same kind of spike [ADR-0007](0007-windows-shim-via-shared-powershell-discovery.md) forced for the RPC layer).

## Considered Options

- **Per-OS `shell_detect` (grammar tables keyed by OS)** — rejected: cuts along the wrong axis. OS conflates path conventions and command grammar, and the git-bash-on-Windows case (POSIX grammar, Windows paths) breaks the mapping outright.
- **"Just a Windows branch"** — rejected: scatters OS conditionals through a delicate, edge-case-heavy module (its cases come from real historical bugs) along that same wrong axis.
- **Split the two axes; ship the path adapter; table-shape the matchers; defer the PowerShell grammar** *(chosen)* — isolates the one extraction that is needed regardless of shell (path conventions), and avoids speculative grammar work until the requirement is confirmed.

## Consequences

- The path-convention adapter is the highest-value, lowest-risk extraction and is needed whatever shell the agent uses (Windows paths show up even under git-bash).
- The PowerShell grammar is built only once the empirical "what shell does the Windows Bash tool emit" finding lands (gathered as STEP 0 of the shell_detect work). Observed evidence already points at PowerShell (`Remove-Item`), but the exact cmdlets/aliases/params come from real samples, not guesses.
- The existing POSIX grammar's behaviour must stay byte-identical through the restructure — `pre_tool_bash_detect_spec.lua` (renamed alongside the module) is the safety net.
- `M.detect(cmd, cwd)` stays stable, so callers (`pre_tool.handle`) are untouched. The broader integration-registry / install-engine consolidation considered in the same architecture review is **out of scope** here and deferred.
- This refines [ADR-0007](0007-windows-shim-via-shared-powershell-discovery.md)'s "one implementation per OS" principle for the *detection* layer: detection is split by *capability axis*, not by OS.
