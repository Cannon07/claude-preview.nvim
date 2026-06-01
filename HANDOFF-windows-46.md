# Handoff — Windows 11 support (issue #46)

This doc tracks the in-flight state of Windows support that isn't already in
git. **Status as of 2026-06-02: the claudecode vertical slice is VALIDATED on a
real Windows 11 box** (PowerShell 5.1 + nvim 0.11.2). The original "drafted but
unvalidated" spike is done; this revision records what that validation found and
what remains.

## Read these first (durable decisions)

- **`docs/adr/0007-windows-shim-via-shared-powershell-discovery.md`** — the
  keystone. Shared PowerShell shim; all agents (incl. OpenCode) reuse it;
  verbatim-payload-splice invariant; forward-slashed tempfile; transport-agnostic
  dispatcher. Supersedes ADR-0006.
- **`CONTEXT.md`** — *Hook entry* (per-OS, PowerShell 5.1 floor), *Socket
  discovery* (pipe-enumeration fallback), *Pidfile* (`%LOCALAPPDATA%` base).
- **Branch `feat/windows-46`**, commits (newest last):
  1. `docs:` Windows architecture decisions
  2. `feat:` OS-agnostic groundwork
  3. `feat:` PowerShell shim — claudecode vertical slice
  4. `docs:` Windows handoff
  5. **`fix: validate Windows claudecode slice on a real box` (`69ff052`)** — this
     session's fixes (below).

## Critical context

The slice was authored on **macOS** (couldn't run PowerShell / named pipes /
Windows nvim). This session ran it on a real Windows box. **The installed Claude
Code hook command invokes Windows PowerShell 5.1 (`powershell.exe`), NOT pwsh 7**
— always validate `.ps1` changes against 5.1; several bugs only reproduce there.

## What changed this session (commit `69ff052`)

Ran the ADR-0007 validation ladder bottom-up under 5.1 against a live nvim. Found
and fixed **four** bugs the macOS-only session could not catch:

1. **Missing `--headless`** (`bin/nvim-socket.ps1`, `bin/nvim-call.ps1`). On
   Windows, `nvim --server X --remote-expr Y` starts a *local TUI* instead of
   acting as a pure remote client — stdout came back as terminal escape codes
   with no result. It also made the responsiveness probe exit 0 against a *dead*
   pipe (false positive → would accept stale pidfiles). With `--headless`, the
   result returns cleanly and a dead server yields exit 2.
2. **PowerShell 5.1 quote mangling** (`bin/nvim-call.ps1`). 5.1 lacks
   `PSNativeCommandArgumentPassing` and strips the embedded double quotes in
   `luaeval("...")`, so nvim parsed `require(...)` as Vimscript → `E117`. Fixed by
   using a single-quoted Vimscript body with Lua long-bracket `[[...]]` literals —
   zero quote chars to mangle; equally correct under pwsh 7.
3. **`/tmp` fallback** (`lua/code-preview/pre_tool/init.lua`). `tmpdir()` returned
   `/tmp` on Windows (no `$TMPDIR` there) → diff tempfiles hit a nonexistent
   `C:\tmp` and previews silently failed. Added a Windows branch (`TMP`/`TEMP`,
   forward-slashed); Unix branch left byte-identical.
4. **Mixed-separator log path** (`lua/code-preview/log.lua`). Normalised with
   `vim.fs.normalize` so Windows no longer produces `…\nvim-data/code-preview.log`.
   No-op on Unix; same physical file on Windows.

## Validation performed (all PASS)

- **Rung 0 — pidfile**: `%LOCALAPPDATA%\code-preview\sockets\<pid>` written with
  pipe path on line 1, cwd on line 2.
- **Rung 1 — discovery**: `Find-NvimSocket` returns the live pipe; self-heals
  past stale/dead pidfiles via the (now `--headless`) probe.
- **Rung 2 — RPC round-trip**: `set` then `get_all` returns the value set,
  through `rpc.dispatch` under 5.1.
- **Rung 3 — shim end-to-end**: piping a Claude Code `Write` payload into
  `code-preview-diff.ps1` opens a real preview in nvim and prints the
  `permissionDecision` JSON.
- **Rung 4 — real Claude Code**: hooks install correctly (forward-slashed
  `powershell -NoProfile -ExecutionPolicy Bypass -File "<path>.ps1"` command in
  `.claude\settings.local.json`); live edits open previews across multiple
  projects. Claude Code DOES shell-execute the command string on Windows — **no
  `.cmd` trampoline needed.**
- **Debug logging**: confirmed identical to macOS (in-process Lua only; shims
  don't log on either OS). Path is `%LOCALAPPDATA%\nvim-data\code-preview.log`.

## Windows gotchas worth remembering

- **`--headless` is mandatory** for every `nvim --server --remote-expr` call.
- **No double quotes** may reach `nvim.exe` args under 5.1 — keep using the
  `[[...]]` form.
- **TUI vs `--embed`**: in testing, terminal `nvim .` instances did not expose a
  named-pipe server here while GUI `--embed` (e.g. Neovide) ones did. Not fully
  run to ground because it turned out to be a red herring for the issue below —
  but if "no diff appears," first confirm the target nvim has a reachable pipe.
- **Hooks are per-project**: a "diff didn't show" report traced to hooks simply
  not being installed in that project (run `:CodePreviewInstallClaudeCodeHooks`).

## Remaining rollout (NOT started)

1. **codex / copilot / opencode `.ps1` shims** + installer `.ps1`/command wiring.
   Replicate the stdin fast-path tool filter from their `.sh` shims. Confirm each
   agent's `command`-field invocation semantics on Windows (claudecode is proven;
   the others are not).
2. **CI — `windows-latest` GitHub Actions job**: Lua specs + a PowerShell shim
   smoke test (automated Rungs 0–2). ⚠ **`PlenaryBustedDirectory` HANGS headless
   on Windows**; per-file `PlenaryBustedFile` works — CI must iterate specs
   per-file. Do NOT port the bash E2E.
3. **`bash_detect.lua` is Unix-path-only**: `looks_like_path` rejects any path
   containing a backslash, and `resolve` only treats `/`-prefixed strings as
   absolute (drive-letter `C:\...` breaks it). 2 specs fail on Windows today from
   hardcoded `/tmp` and `~`/`HOME`. Needs Windows-path awareness + portable specs;
   belongs with the bash-backend work, not the claudecode slice.
4. **`health.lua`** — per-OS script-executability checks still assume `.sh` +
   `chmod`; reshape alongside per-agent slices.
5. **README** — Windows setup notes.
6. **Stale code** (minor, unrelated to Windows): `log.lua:75-88` documents shims
   reading `M.state()`/`get_log_path()`, but no shim does post-ADR-0005 — looks
   like dead code.

## Invariants to preserve (do not regress)

- Shim **never** deserialises-then-reserialises the payload — splice raw JSON
  verbatim (avoids `ConvertTo-Json` depth-2 truncation of MultiEdit/ApplyPatch).
- Forward-slash any path spliced into a Lua source string.
- Pidfile dir computed **identically** in `pidfile.lua` and `nvim-socket.ps1`.
- Discovery/RPC stay **one implementation per OS** — no agent (esp. opencode)
  gets a private TS-native discovery path (ADR-0007).

## Rollout / comms note (user decision, not code)

Announce per-agent via GitHub releases; gate the single Reddit post on claudecode
being proven solid on a real Windows box — **that bar is now met** — while
scoping the post honestly ("starting with Claude Code, others rolling out").
