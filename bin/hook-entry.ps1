# hook-entry.ps1 — generic per-OS hook entry (Windows), parameterized by
# backend + event. Windows counterpart to bin/hook-entry.sh; replaces the
# per-backend backends/<agent>/code-{preview,close}-diff.ps1 shims. See ADR-0008.
#
# Invoked by the installer as:
#   powershell -NoProfile -ExecutionPolicy Bypass -File hook-entry.ps1 <backend> <pre|post>
#
# Reads the agent's hook payload on stdin, optionally fast-path-filters noisy
# tools, discovers the running Neovim (named pipe), and makes a single RPC into
# the in-process orchestrator. Abstains (exit 0, no stdout) on any failure.

# $HookEvent, not $Event: $Event is a PowerShell automatic variable (eventing
# subsystem). Harmless here, but renamed to avoid the foot-gun.
param([string]$Backend, [string]$HookEvent)

try {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

  # ConvertFrom-Json is read-only and unbounded in depth, so this never
  # truncates; we use it only for the shallow fields below. The payload itself
  # is spliced verbatim into the RPC args (ADR-0007), never re-serialised.
  $payload = $raw | ConvertFrom-Json

  # Per-backend fast-path filter (perf gate; the Lua normaliser is the source of
  # truth). Only codex/copilot need it; claudecode filters via its settings
  # matcher, opencode via its TS allowlist.
  switch ($Backend) {
    'codex' {
      $tool = $payload.tool_name
      if ([string]::IsNullOrEmpty($tool) -or
          $tool -in @('read','view','glob','grep','ls','list_files') -or
          $tool -like 'mcp__*') { exit 0 }
    }
    'copilot' {
      $tool = $payload.toolName
      if ([string]::IsNullOrEmpty($tool) -or
          $tool -in @('view','glob','grep','ls','report_intent')) { exit 0 }
    }
  }

  $cwd = $payload.cwd

  . (Join-Path $PSScriptRoot "nvim-socket.ps1")
  . (Join-Path $PSScriptRoot "nvim-call.ps1")

  $socket = Find-NvimSocket -ProjectCwd $cwd
  if ([string]::IsNullOrEmpty($socket)) { exit 0 }

  # Verbatim splice of the raw payload into [payload, backend].
  $argsJson = "[$raw,""$Backend""]"

  if ($HookEvent -eq 'post') {
    $null = Invoke-NvimCall -Server $socket -Module 'code-preview.post_tool' `
                            -Function 'handle' -ArgsJson $argsJson
  } else {
    $result = Invoke-NvimCall -Server $socket -Module 'code-preview.pre_tool' `
                              -Function 'handle' -ArgsJson $argsJson
    if ($null -ne $result -and $result -ne '') { Write-Output $result }
  }
} catch {
  # Boundary between agent and plugin: abstain on any failure.
  exit 0
}
