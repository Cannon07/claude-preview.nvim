# Shell write/delete detection splits path-convention from command-grammar

Status: accepted

Windows support (issue #46) needs the Tier-1 shell-write/delete detector (`pre_tool/shell_detect.lua`, renamed from `bash_detect.lua`; it feeds the [change](../../CONTEXT.md#change) [status](../../CONTEXT.md#status) values `deleted` / `bash_modified` / `bash_created`) to work on Windows. The obvious framings — "make it per-OS" or "add a Windows branch" — are both wrong, because the detector entangles **two independent axes that do not align onto OS**: *path conventions* (`/`-absolute, `~/`, `/dev/`) and *command grammar* (which verbs/operators write or delete). A git-bash shell on Windows has POSIX grammar with Windows-shaped paths; a PowerShell shell has PowerShell grammar with Windows paths — so OS is not the seam.

We therefore split the two axes: rename `bash_detect` → `shell_detect` behind the unchanged `M.detect(cmd, cwd)` interface; extract an OS-selected **path-convention adapter** (Unix, byte-identical to the historical behaviour, plus Windows: `C:\`/`C:/`, UNC `\\…`, backslash separators, relative-against-a-backslash-cwd); and add a **PowerShell command grammar** alongside the POSIX one. Both grammars run on every command — they share the redirect operator and differ only in verbs, and the PowerShell tables deliberately exclude the bash aliases (`rm`/`cp`/`mv`/`tee`), so adding PowerShell provably cannot change a POSIX result.

The PowerShell grammar was **informed by an empirical finding, not guessed** — the same discipline [ADR-0007](0007-windows-shim-via-shared-powershell-discovery.md) forced for the RPC layer. Ground truth (raw hook stdin teed on a Windows box, cross-checked against Claude Code session transcripts) corrected two premises we held going in:

- **It is a separate tool, not the Bash tool emitting PowerShell.** Claude Code on Windows exposes a distinct **`PowerShell`** tool alongside `Bash` and routes shell file ops through it (the Haiku model deletes via `Remove-Item`, moves via `Move-Item`, writes via `Set-Content`/`Out-File`/`Add-Content`); `tool_name` is `"PowerShell"` with a Bash-shaped `{command}` payload. (Opus, by contrast, drives git-bash and emits POSIX `rm` with Windows-shaped paths — exactly the cross-cutting case the axis split predicted.)
- **Routing was therefore not "fine"** — the detector was not the only gap. The PreToolUse matcher was `Edit|Write|MultiEdit|Bash`, so the hook never fired for the `PowerShell` tool. The full fix is three layers: **matcher** (add `PowerShell` to the claudecode Pre/PostToolUse matchers so the hook fires), **normaliser** (fold `tool_name="PowerShell"` onto canonical `Bash`, so the dispatcher/emitters and `shell_detect` need no awareness of a separate tool), and the **detection split** itself.

## Considered Options

- **Per-OS `shell_detect` (grammar tables keyed by OS)** — rejected: cuts along the wrong axis. OS conflates path conventions and command grammar, and the git-bash-on-Windows case (POSIX grammar, Windows paths) breaks the mapping outright.
- **"Just a Windows branch"** — rejected: scatters OS conditionals through a delicate, edge-case-heavy module (its cases come from real historical bugs) along that same wrong axis.
- **Split the two axes** *(chosen)* — path conventions become an OS-selected adapter; command grammars are added by vocabulary, independent of OS.

## Consequences

- The path-convention adapter is the highest-value extraction and is needed whatever shell the agent uses (Windows paths show up even under git-bash). The Windows adapter emits canonical backslash paths, because `fnamemodify(":p")` is a no-op on an already-absolute Windows path, so the detector's output must already match the form Edit/Write key the changes registry with — otherwise the neo-tree indicator keys a different entry and misses.
- POSIX behaviour stays byte-identical through the restructure; `pre_tool_shell_detect_spec.lua` (renamed alongside the module) is the safety net, with POSIX rows and Windows rows each marked `pending` on the other OS.
- `M.detect(cmd, cwd)` stays stable, so callers (`pre_tool.handle`) are untouched.
- **Scope honesty:** the PowerShell vocabulary is table-shaped (verb→category tables), but the POSIX matchers remain the original per-verb functions rather than one unified grammar table. "A second grammar slots in as data" is met functionally — PowerShell was added without disturbing POSIX — not as a single shared table; a full POSIX grammar-table refactor was not needed to land Windows and stays out of scope. The broader integration-registry / install-engine consolidation from the same architecture review is likewise deferred.
- This refines [ADR-0007](0007-windows-shim-via-shared-powershell-discovery.md)'s "one implementation per OS" principle for the *detection* layer: detection is split by *capability axis*, not by OS.
