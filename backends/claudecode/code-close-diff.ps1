# code-close-diff.ps1 — PostToolUse hook entry for Claude Code on Windows.
# PowerShell counterpart to code-close-diff.sh. Makes a single RPC into the
# in-process orchestrator (lua/code-preview/post_tool.lua) and exits; the
# orchestrator clears the changes registry, closes any open preview for the
# affected file, and refreshes neo-tree.
#
# Abstains silently (exit 0) when Neovim is unreachable or anything fails.
# See ADR-0007.

try {
  $raw = [Console]::In.ReadToEnd()
  if ([string]::IsNullOrWhiteSpace($raw)) { exit 0 }

  $cwd = ($raw | ConvertFrom-Json).cwd

  $binDir = Join-Path $PSScriptRoot "..\..\bin"
  . (Join-Path $binDir "nvim-socket.ps1")
  . (Join-Path $binDir "nvim-call.ps1")

  $socket = Find-NvimSocket -ProjectCwd $cwd
  if ([string]::IsNullOrEmpty($socket)) { exit 0 }

  $argsJson = "[$raw,""claudecode""]"

  # Output is discarded for the post-tool path.
  $null = Invoke-NvimCall -Server $socket -Module "code-preview.post_tool" `
                          -Function "handle" -ArgsJson $argsJson
} catch {
  exit 0
}
