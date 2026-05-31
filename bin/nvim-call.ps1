# nvim-call.ps1 — Windows counterpart to nvim-call.sh. Structured RPC into the
# running Neovim over a named pipe. See issue #46 / ADR-0007.
#
# Usage (dot-source after nvim-socket.ps1, then call):
#   $result = Invoke-NvimCall -Server $socket -Module code-preview.pre_tool `
#                             -Function handle -ArgsJson $argsJson
#
# $ArgsJson is a JSON array string. It is written to a tempfile VERBATIM and
# never re-serialised (the depth-truncation invariant in ADR-0007: round-tripping
# the payload through ConvertTo-Json would silently truncate deep MultiEdit /
# ApplyPatch structures at depth 2). The receiving Lua decodes it with
# vim.json.decode in lua/code-preview/rpc.lua.

function Invoke-NvimCall {
  param(
    [string]$Server,
    [string]$Module,
    [string]$Function,
    [string]$ArgsJson = "[]"
  )
  if ([string]::IsNullOrEmpty($Server)) { return $null }

  # Tempfile in %TEMP% (atomic creation; the Windows analogue of mktemp).
  $tmp = [System.IO.Path]::GetTempFileName()
  try {
    # Write the args JSON verbatim, UTF-8 with NO BOM — a BOM would choke
    # vim.json.decode on the receiving side.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($tmp, $ArgsJson, $utf8NoBom)

    # Forward-slash the path: it is spliced into a Lua *source string* below, and
    # Windows backslashes are Lua escape sequences (\U, \T, ...). Lua's io.open
    # accepts forward slashes on Windows, so this is lossless.
    $tmpLua = $tmp -replace '\\', '/'

    # Only Module / Function / tmp — all controlled by us — enter the Lua source.
    # User data flows through the tempfile as JSON, decoded by the dispatcher.
    $expr = "luaeval(`"require('code-preview.rpc').dispatch('$Module', '$Function', '$tmpLua')`")"

    # SPIKE / KNOWN RISK (ADR-0007): Windows PowerShell 5.1 lacks
    # PSNativeCommandArgumentPassing and can mangle embedded double quotes when
    # handing $expr to nvim.exe. $expr deliberately keeps user data out and uses
    # single quotes inside the Lua source, but the outer luaeval("...") still
    # carries double quotes. Validate the exact quoting on a real Windows box;
    # if 5.1 mangles it, the fix is Start-Process with -ArgumentList or an
    # escaped arg array — confirm empirically before committing a workaround.
    $out = & nvim --server $Server --remote-expr $expr 2>$null
    return $out
  }
  finally {
    Remove-Item -Path $tmp -ErrorAction SilentlyContinue
  }
}
