# nvim-socket.ps1 — Windows counterpart to nvim-socket.sh. Discovers the
# running Neovim's named-pipe address (\\.\pipe\nvim.<pid>.0) and exposes it
# via Find-NvimSocket. See issue #46 / docs/adr/0007-windows-shim-via-shared-powershell-discovery.md.
#
# Usage (dot-source, then call):
#   . "$PSScriptRoot\nvim-socket.ps1"
#   $socket = Find-NvimSocket -ProjectCwd $cwd
#
# Discovery order mirrors the Unix resolver, minus the Unix-only globs:
#   1. $env:NVIM_LISTEN_ADDRESS, if responsive.
#   2. Pidfile lookup under %LOCALAPPDATA%\code-preview\sockets (preferred path;
#      written by lua/code-preview/pidfile.lua, same dir formula).
#   3. Named-pipe enumeration fallback (\\.\pipe\nvim.*).
# Every candidate is validated with a `--remote-expr "1"` responsiveness probe,
# which self-heals stale pidfiles left by crashed Neovims. There is no
# is-socket precheck (named pipes have no reliable existence test on Windows).

# Probe a server address for responsiveness. We only care about the exit code;
# all stdout/stderr is discarded.
#
# --headless is REQUIRED on Windows: without it, `nvim --server <addr>
# --remote-expr ...` starts a local TUI instead of acting purely as a remote
# client, and that local instance exits 0 even when <addr> is dead — a false
# positive that would make this probe accept stale pidfiles. With --headless,
# a dead server correctly yields a non-zero exit. (Validated on nvim 0.11,
# Windows; the Unix shim does not need this flag.)
function Test-NvimResponsive {
  param([string]$Server)
  if ([string]::IsNullOrEmpty($Server)) { return $false }
  try {
    & nvim --headless --server $Server --remote-expr "1" *> $null
    return ($LASTEXITCODE -eq 0)
  } catch {
    return $false
  }
}

# Pidfile directory — MUST match lua/code-preview/pidfile.lua's Windows branch
# (%LOCALAPPDATA%\code-preview\sockets). Both sides compute it independently.
function Get-PidfileDir {
  return (Join-Path $env:LOCALAPPDATA "code-preview\sockets")
}

function Find-NvimSocket {
  param([string]$ProjectCwd = "")

  # 1. Explicit env var — probe it directly (no is-socket precheck on Windows).
  $envAddr = $env:NVIM_LISTEN_ADDRESS
  if (-not [string]::IsNullOrEmpty($envAddr) -and (Test-NvimResponsive $envAddr)) {
    return $envAddr
  }

  $live = New-Object System.Collections.Generic.List[string]

  # 2. Pidfile lookup. File format (two lines): line 1 = pipe path, line 2 = cwd.
  $pidDir = Get-PidfileDir
  if (Test-Path $pidDir) {
    foreach ($pf in (Get-ChildItem -Path $pidDir -File -ErrorAction SilentlyContinue)) {
      $lines = @(Get-Content -Path $pf.FullName -ErrorAction SilentlyContinue)
      if ($lines.Count -lt 1) { continue }
      $pipe = $lines[0]
      $cwd  = if ($lines.Count -ge 2) { $lines[1] } else { "" }
      if ([string]::IsNullOrEmpty($pipe)) { continue }

      # Responsiveness probe self-heals stale pidfiles (crashed nvim, recycled PID).
      if (-not (Test-NvimResponsive $pipe)) { continue }

      # cwd match-or-parent rule, using the cwd the nvim itself reported.
      if (-not [string]::IsNullOrEmpty($ProjectCwd) -and -not [string]::IsNullOrEmpty($cwd)) {
        if ($ProjectCwd -eq $cwd -or $ProjectCwd.StartsWith($cwd + '\')) {
          return $pipe
        }
      }
      $live.Add($pipe)
    }
  }

  # 3. Named-pipe enumeration fallback. Cannot run the cwd tiebreak (a pipe found
  # this way has no associated cwd — Windows has no /proc or lsof), so it only
  # contributes live candidates, degrading to "first responsive pipe".
  try {
    foreach ($path in [System.IO.Directory]::GetFiles('\\.\pipe\')) {
      $leaf = Split-Path $path -Leaf
      if ($leaf -like 'nvim.*') {
        $pipe = "\\.\pipe\$leaf"
        if (-not $live.Contains($pipe) -and (Test-NvimResponsive $pipe)) {
          $live.Add($pipe)
        }
      }
    }
  } catch {
    # Pipe enumeration can throw on exotic pipe names; treat as "no fallback hits".
  }

  if ($live.Count -eq 0) { return "" }

  # 4. Prefer a cwd match among enumerated candidates is not possible (no cwd),
  # so fall back to the first live pipe.
  return $live[0]
}
