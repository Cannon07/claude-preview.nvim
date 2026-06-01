# Handoff — Windows 11 support (issue #46)

You are picking up an in-progress effort to add Windows support to
code-preview.nvim. This doc carries the **in-flight state** that isn't already
in git. Read the durable artifacts first, then the "where we are" section.

## Read these first (the decisions are already recorded)

- **`docs/adr/0007-windows-shim-via-shared-powershell-discovery.md`** — the
  keystone. Shared PowerShell shim; all agents (incl. OpenCode) reuse it;
  verbatim-payload-splice invariant; forward-slashed tempfile; transport-agnostic
  dispatcher. Supersedes ADR-0006.
- **`CONTEXT.md`** — updated terms: *Hook entry* (per-OS, PowerShell 5.1 floor),
  *Socket discovery* (pipe-enumeration fallback), *Pidfile* (`%LOCALAPPDATA%` base).
- **Branch `feat/windows-46`**, commits (newest last):
  1. `docs:` Windows architecture decisions
  2. `feat:` OS-agnostic groundwork
  3. `feat:` PowerShell shim — claudecode vertical slice
- Issue #46 (request) and #47 (the bash→Lua migration that made this possible).

## Critical constraint

The prior session ran on **macOS** and **could not execute any PowerShell, named
pipes, or Windows nvim**. Everything `.ps1` is **drafted but UNVALIDATED**. You
are (presumably) on the Windows box — your first job is to *run* it.

Also: per `CLAUDE.md`, after code changes do NOT trigger a test edit yourself —
wait for the user to restart Neovim and ask for a test edit.

## Where we are

**Validated on macOS (safe, OS-agnostic groundwork, commit 2):**
- `pidfile.lua` — `%LOCALAPPDATA%\code-preview\sockets` on Windows (writer side).
- `codex.lua` / `copilot.lua` — stem-based marker matching (`code-preview-diff` /
  `code-close-diff`, slash/ext-agnostic), `chmod` gated behind `has("unix")`,
  `CODEX_HOME` honoured.
- `health.lua` — PowerShell-presence check on Windows in place of jq.
- Tests green: Lua specs (110), codex E2E (22), copilot E2E (15).

**Drafted, UNVALIDATED (commit 3) — the claudecode vertical slice:**
- `bin/nvim-socket.ps1`, `bin/nvim-call.ps1` — discovery + RPC.
- `backends/claudecode/code-{preview,close}-diff.ps1` — the shims.
- `claudecode.lua` — writes `powershell -NoProfile -ExecutionPolicy Bypass -File
  <path>.ps1` + `.ps1` paths on Windows (Unix path unchanged, verified).

## Your immediate task: run the validation ladder (the "spike")

Bottom-up; stop and fix at the first failure. Two items are most likely to bite,
called out below.

- **Rung 0 — pidfile.** In Windows nvim with the plugin loaded:
  `:lua print(require('code-preview.pidfile').path())` and
  `:lua print(vim.v.servername)`. Confirm the file exists under
  `%LOCALAPPDATA%\code-preview\sockets\<pid>`, line 1 = `\\.\pipe\nvim...` pipe.
- **Rung 1 — discovery.** PowerShell from repo root, nvim running:
  `. .\bin\nvim-socket.ps1; Find-NvimSocket -ProjectCwd (Get-Location).Path`
  → should print the same pipe. (Watch `GetFiles('\\.\pipe\')` in the fallback —
  occasionally surprises on specific Windows builds.)
- **Rung 2 — RPC round-trip. ⚠ LIKELIEST FAILURE.**
  `. .\bin\nvim-call.ps1; $s = Find-NvimSocket -ProjectCwd (Get-Location).Path;`
  `Invoke-NvimCall -Server $s -Module "code-preview.changes" -Function "set" -ArgsJson '["C:/tmp/probe.txt","modified"]'`
  then in nvim:
  `:lua print(vim.inspect(require('code-preview.changes').get_all()))`.
  **PS 5.1 lacks `PSNativeCommandArgumentPassing`** and may mangle the embedded
  double quotes in `$expr` when handing it to `nvim.exe` (see the SPIKE comment in
  `bin/nvim-call.ps1`). If nvim errors, the fix is likely `Start-Process
  -ArgumentList` or an escaped arg array — confirm empirically.
- **Rung 3 — shim end-to-end.** Pipe a fake Claude Code payload into
  `.\backends\claudecode\code-preview-diff.ps1` (JSON with `cwd`, `tool_name`,
  `tool_input`) → preview should open + stdout carries `permissionDecision` JSON.
- **Rung 4 — real install + Claude Code. ⚠ SECOND SPIKE ITEM.**
  `:CodePreviewInstallClaudeCodeHooks`, verify the `command` in
  `.claude\settings.local.json`, run Claude Code, edit a file. This validates
  whether Claude Code actually **shell-executes** the `command` string on Windows
  (the assumption behind writing `powershell -File ...` as one string). If it
  raw-execs a bare path instead, add a `.cmd` trampoline (see ADR-0007).

## After the slice validates — remaining rollout (deliberately NOT started)

Held until Rung 2/4 prove the pattern, to avoid cloning a broken pattern 4×:
1. **codex / copilot `.ps1` shims** + installer `.ps1`/command wiring. NOTE the
   codex/copilot shims have a stdin fast-path tool filter (see their `.sh`) —
   replicate it in PS. Confirm codex/copilot `command`-field invocation semantics
   (the other half of the spike — less certain than claudecode).
3. **CI** — add a `windows-latest` GitHub Actions job: Lua specs + a PowerShell
   shim smoke test (the automated form of Rungs 0–2). Do NOT port the bash E2E.
4. **`health.lua`** — the per-OS script-executability checks still assume `.sh` +
   `chmod`; they'll warn spuriously on Windows. Reshape alongside per-agent slices.
5. **README** — Windows setup notes.

## Invariants to preserve (do not regress)

- Shim **never** deserialises-then-reserialises the payload — splice raw JSON
  verbatim (avoids `ConvertTo-Json` depth-2 truncation of MultiEdit/ApplyPatch).
- Forward-slash any path spliced into a Lua source string.
- Pidfile dir computed **identically** in `pidfile.lua` and `nvim-socket.ps1`.
- Discovery/RPC stay **one implementation per OS** — do not give any agent
  (esp. opencode) a private TS-native discovery path (ADR-0007).

## Suggested skills for the next session

- **`verify`** — to drive the app and confirm the slice works on Windows.
- **`to-issues`** — if you want to slice the remaining rollout into tracked
  issues (the prior session offered this; user chose to keep it in-chat for now).
- The grilling is **done** — no need to re-run `grill-with-docs`.

## Rollout / comms note (user decision, not code)

Announce per-agent via GitHub releases; gate the **single Reddit post** on
claudecode being proven-solid on a real Windows box (don't wait for all 4 agents;
do scope the post honestly: "starting with Claude Code, others rolling out").
