# code-preview-diff.ps1 — PreToolUse hook entry for Claude Code on Windows.
# PowerShell counterpart to code-preview-diff.sh (see that file for the full
# rationale). Reads the hook payload from stdin, discovers the running Neovim,
# and makes a single RPC into the in-process orchestrator
# (lua/code-preview/pre_tool/init.lua), printing whatever it returns.
#
# When Neovim is unreachable — or anything else fails — the shim abstains:
# exit 0 with no stdout, so Claude Code falls back to its native permission
# flow as if the plugin weren't installed. See ADR-0007.

try {
  # Read all of stdin.
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

  # Parse only the shallow .cwd we need for socket discovery. ConvertFrom-Json
  # reads arbitrarily deep, so this never truncates; a parse failure means a
  # malformed payload — abstain. (We never re-serialise: the raw payload is
  # spliced verbatim below, per ADR-0007.)
  $cwd = ($raw | ConvertFrom-Json).cwd

  $binDir = Join-Path $PSScriptRoot "..\..\bin"
  . (Join-Path $binDir "nvim-socket.ps1")
  . (Join-Path $binDir "nvim-call.ps1")

  $socket = Find-NvimSocket -ProjectCwd $cwd
  if ([string]::IsNullOrEmpty($socket)) { exit 0 }

  # Build the RPC args array [payload, backend] by splicing the raw payload
  # JSON verbatim — the PowerShell analogue of jq's `--argjson r "$INPUT"`.
  $argsJson = "[$raw,""claudecode""]"

  $result = Invoke-NvimCall -Server $socket -Module "code-preview.pre_tool" `
                            -Function "handle" -ArgsJson $argsJson
  if ($null -ne $result -and $result -ne "") {
    Write-Output $result
  }
} catch {
  # The shim is the boundary between the agent and the plugin: abstain on any
  # failure rather than surfacing a hook error to Claude Code.
  exit 0
}
