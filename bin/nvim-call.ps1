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
    #
    # Quoting (the ADR-0007 5.1 spike, now RESOLVED): the expression must contain
    # NO double-quote characters. Windows PowerShell 5.1 lacks
    # PSNativeCommandArgumentPassing and strips embedded double quotes when handing
    # an argument to nvim.exe; a `luaeval("...")` form arrives as a bare
    # `luaeval(require(...))`, which nvim parses as Vimscript and rejects with
    # E117 (validated empirically on 5.1). So we use a single-quoted Vimscript
    # string for the luaeval body and Lua long-bracket strings ([[...]]) for the
    # module/function/path literals — zero quote characters of either kind, so
    # there is nothing for 5.1 to mangle, and it is equally correct under pwsh 7.
    # Safe because Module/Function/tmpLua are all our own values and never
    # contain the long-bracket terminator ]].
    $expr = "luaeval('require([[code-preview.rpc]]).dispatch([[$Module]], [[$Function]], [[$tmpLua]])')"

    # --headless is REQUIRED on Windows: without it nvim starts a local TUI on
    # this invocation (emitting terminal escape sequences to stdout and NOT
    # returning the --remote-expr result) instead of acting as a pure remote
    # client. With --headless the result is returned cleanly. See nvim-socket.ps1
    # for the matching rationale; validated on nvim 0.11, Windows. The Unix shim
    # does not need this flag.
    $out = & nvim --headless --server $Server --remote-expr $expr 2>$null
    return $out
  }
  finally {
    Remove-Item -Path $tmp -ErrorAction SilentlyContinue
  }
}
