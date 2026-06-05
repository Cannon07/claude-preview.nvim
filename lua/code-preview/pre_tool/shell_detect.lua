-- pre_tool/shell_detect.lua — Tier 1 shell-write + delete detection.
--
-- (Renamed from bash_detect.lua: the detector handles more than bash now.)
--
-- Inputs: a shell command string and the project cwd.
-- Output: a structured table { rm_paths = {...}, write_paths = {...} }.
--
-- The detector entangles two INDEPENDENT axes, and the architecture review
-- (issue #46 follow-up) split them on purpose — they are NOT the same as "OS":
--
--   1. Path conventions — how a raw token resolves to an absolute path, and
--      what counts as a path at all. POSIX (`/`-absolute, `~/`, `/dev/`) vs
--      Windows (`C:\`/`C:/`, UNC `\\…`, backslash separators, relative against
--      a backslash cwd). Selected by OS via `path_adapter()`.
--   2. Command grammar — which verbs/operators write or delete. POSIX
--      (`rm`, `>`/`>>`, `mv`, `cp`, `tee`, `sed -i`) and PowerShell
--      (`Remove-Item`, `Set-Content`, `Out-File`, `Move-Item`, …). Both
--      grammars run on every command regardless of OS; they share the redirect
--      operator and differ only in verbs, so adding PowerShell cannot change a
--      POSIX result (verified by the POSIX rows in shell_detect_spec.lua).
--
-- Why PowerShell at all: on Windows, Claude Code routes shell file ops through
-- a distinct `PowerShell` tool (the Haiku model deletes via `Remove-Item …`).
-- The claudecode normaliser folds that onto the canonical Bash path, so those
-- commands arrive here as PowerShell syntax. See STEP 0 of the handoff.
--
-- The POSIX edge cases here all come from real bugs in the historical bash
-- pre-tool detection logic; resist "obvious simplifications" without first
-- reading shell_detect_spec.lua.

local M = {}

local function is_windows()
  return vim.fn.has("win32") == 1
end

-- ── Quoting / escaping primitives ────────────────────────────────

-- Strip a single matching pair of surrounding quotes.
local function unquote(s)
  if #s >= 2 then
    local first, last = s:sub(1, 1), s:sub(-1)
    if (first == '"' and last == '"') or (first == "'" and last == "'") then
      return s:sub(2, -2)
    end
  end
  return s
end

-- Undo shell backslash-escapes that bash actually requires for filenames:
-- \', \", \\, \ , \$, \&. Pseudo-escapes like \n / \t are NOT touched —
-- those typically appear inside quoted strings (e.g. `printf '<!-- -->\n\n'`)
-- and undoing them here would turn the leak into a fake-looking path.
--
-- POSIX ONLY. On Windows a backslash is a path separator, not an escape, so the
-- Windows adapter must not run this (it would eat `C:\new`'s separator or fold
-- a UNC `\\` prefix). That difference is exactly why cleaning lives in the path
-- adapter rather than being shared.
local SHELL_ESCAPED = { ["'"]=true, ['"']=true, ["\\"]=true, [" "]=true, ["$"]=true, ["&"]=true }
local function shell_unescape(s)
  return (s:gsub("\\(.)", function(c) return SHELL_ESCAPED[c] and c or ("\\" .. c) end))
end

-- ── POSIX path adapter (behaviour byte-identical to the historical detector) ──

local unix_paths = {}

-- Resolve a raw token (possibly relative, possibly ~-prefixed) to an absolute
-- path. Caller is responsible for cleaning (unquote/unescape) first.
function unix_paths.resolve(p, cwd)
  if p == "" then return nil end
  if p:sub(1, 1) == "/" then return p end
  if p == "~" then return os.getenv("HOME") or "~" end
  if p:sub(1, 2) == "~/" then
    return (os.getenv("HOME") or "~") .. "/" .. p:sub(3)
  end
  return cwd .. "/" .. p
end

-- Unquote, undo bash escapes, drop a trailing CR (Windows-style payloads).
function unix_paths.clean(s)
  local p = shell_unescape(unquote(s))
  return (p:gsub("\r$", ""))
end

-- Reject obvious non-paths (leaked escape sequences, stray quotes, etc.).
-- This catches cases like `printf '<!-- note -->\n\n'` where the redirect
-- regex picks up `\n\n'` from inside a quoted string.
function unix_paths.looks_like_path(p)
  if p == "" then return false end
  -- Reject backslash and double-quote: those typically leak from inside
  -- quoted strings (e.g. `printf '<!-- -->\n\n'`). Apostrophe is allowed
  -- because shell_unescape produces it legitimately from `\'`.
  if p:find('[\\"]') then return false end
  local first = p:sub(1, 1)
  if first == "/" then return true end
  if p:sub(1, 2) == "./" or p:sub(1, 3) == "../" then return true end
  if p:sub(1, 2) == "~/" then return true end
  if first:match("[%w_]") then return true end
  return false
end

-- True if the string looks like a transient file we should skip.
function unix_paths.is_transient(p)
  if p:match("%.tmp$") or p:match("%.bak$") or p:match("%.swp$") then return true end
  if p:sub(-1) == "~" then return true end
  if p:sub(1, 5) == "/dev/" then return true end
  return false
end

-- ── Windows path adapter ─────────────────────────────────────────
--
-- A Windows box runs BOTH git-bash (POSIX grammar, `/c/…` or relative paths)
-- and PowerShell (Windows paths), so this adapter is a superset: it accepts the
-- Unix forms too. Output is canonicalised to BACKSLASH separators with `..`
-- collapsed, because that is the exact form Claude Code's Edit/Write proposals
-- key the changes registry with (e.g. `D:\proj\file.lua`), and `fnamemodify`
-- `:p` is a no-op on an already-absolute path — it neither flips separators nor
-- collapses `..`. Emitting any other form would key a different registry entry
-- than the editor path for the same file, and the neo-tree indicator would miss.

local win_paths = {}

local function win_is_absolute(p)
  return p:match("^%a:[\\/]") ~= nil  -- drive-letter: C:\ or C:/
      or p:match("^\\\\") ~= nil      -- UNC: \\server\share
      or p:sub(1, 1) == "/"           -- unix-rooted (git-bash)
end

-- Canonicalise to backslash separators with ./.. collapsed.
local function win_canon(p)
  return (vim.fs.normalize(p):gsub("/", "\\"))
end

function win_paths.resolve(p, cwd)
  if p == "" then return nil end
  if p == "~" then return os.getenv("USERPROFILE") or os.getenv("HOME") or "~" end
  if p:match("^~[\\/]") then
    local home = os.getenv("USERPROFILE") or os.getenv("HOME") or "~"
    return win_canon(home .. "/" .. p:sub(3))
  end
  if win_is_absolute(p) then
    -- UNC must keep its leading "\\"; vim.fs.normalize preserves it.
    return win_canon(p)
  end
  return win_canon((cwd or "") .. "/" .. p)
end

-- Unquote and drop a trailing CR. No bash unescaping: backslash is a separator.
function win_paths.clean(s)
  local p = unquote(s)
  return (p:gsub("\r$", ""))
end

-- Positive-shape match: accept things that look like a real Windows/Unix path,
-- reject leaked escape sequences. We can't blanket-reject backslash like the
-- POSIX adapter does (backslash is a legitimate separator here), so instead we
-- only accept recognised path shapes. The html-comment leak `\n\n'` matches
-- none of them (a single leading `\` is neither a drive, a UNC `\\`, nor a
-- relative/absolute prefix), so it is still rejected.
function win_paths.looks_like_path(p)
  if p == "" then return false end
  if p:find('"') then return false end                 -- stray quote leak
  if p:match("^%a:[\\/]") then return true end          -- C:\ or C:/
  if p:match("^\\\\") then return true end              -- UNC \\server
  if p:sub(1, 1) == "/" then return true end            -- /unix/abs (git-bash)
  if p:match("^~[\\/]?") then return true end           -- ~ or ~/ or ~\
  if p:match("^%.%.?[\\/]") then return true end         -- ./ ../ .\ ..\
  if p:match("^%.[%w_]") then return true end            -- .step0 .config dotdirs
  if p:sub(1, 1):match("[%w_]") then return true end     -- bare / relative name
  return false
end

function win_paths.is_transient(p)
  if p:match("%.[Tt][Mm][Pp]$") or p:match("%.[Bb][Aa][Kk]$") or p:match("%.[Ss][Ww][Pp]$") then
    return true
  end
  if p:sub(-1) == "~" then return true end
  return false
end

local function path_adapter()
  return is_windows() and win_paths or unix_paths
end

-- ── Sub-command splitting (shared) ───────────────────────────────

-- Iterate sub-commands separated by ; && || (single or double) and newlines.
-- PowerShell uses `;`, `|`, and newlines; `&&`/`||` exist in PS7 but not 5.1
-- (the installed hook runs under 5.1). POSIX uses all of these. Splitting on
-- the union is safe: a separator absent from a given shell simply never occurs.
local function each_subcommand(cmd)
  local parts = {}
  local buf = {}
  local i = 1
  while i <= #cmd do
    local c = cmd:sub(i, i)
    local n = cmd:sub(i + 1, i + 1)
    if c == ";" or c == "\n" or c == "\r" then
      table.insert(parts, table.concat(buf)); buf = {}; i = i + 1
    elseif (c == "&" and n == "&") or (c == "|" and n == "|") then
      table.insert(parts, table.concat(buf)); buf = {}; i = i + 2
    elseif c == "&" or c == "|" then
      table.insert(parts, table.concat(buf)); buf = {}; i = i + 1
    else
      table.insert(buf, c); i = i + 1
    end
  end
  if #buf > 0 then table.insert(parts, table.concat(buf)) end
  return parts
end

-- ── POSIX command grammar ────────────────────────────────────────

local function detect_rm_in(subcmd, cwd, adapter)
  local cmd = subcmd:gsub("^%s+", "")
  -- Optional `sudo `, then `rm` as standalone command.
  local body = cmd:match("^sudo%s+rm%s+(.*)$") or cmd:match("^rm%s+(.*)$")
  if not body then return {} end

  local paths = {}
  for token in body:gmatch("%S+") do
    -- Skip flags (-rf, --force, etc.). Single-dash followed by alpha; or `--`.
    if not token:match("^%-") then
      local p = adapter.clean(token)
      if p ~= "" then
        local abs = adapter.resolve(p, cwd)
        if abs then table.insert(paths, abs) end
      end
    end
  end
  return paths
end

-- Match output redirections (`>`, `>>`, `&>`, `&>>`) and capture the filename.
-- Excludes FD redirections (`2>&1`) by requiring no digit prefix on bare `>`.
-- Shared by POSIX and PowerShell (both use `>` / `>>`).
local function detect_redirects(cmd)
  local out = {}
  -- Walk character by character so we can disambiguate `2>&1` (skip) from
  -- `> file` (capture). Cheap and explicit beats a clever regex here.
  local i = 1
  while i <= #cmd do
    local c = cmd:sub(i, i)
    local prev = i > 1 and cmd:sub(i - 1, i - 1) or ""
    if c == ">" then
      -- Skip if prev is digit (FD redirection like 2>) — unless prev is &.
      if prev:match("%d") then
        i = i + 1
      else
        -- Skip ">>" doubling
        if cmd:sub(i + 1, i + 1) == ">" then i = i + 1 end
        i = i + 1
        -- Skip whitespace
        while i <= #cmd and cmd:sub(i, i):match("%s") do i = i + 1 end
        -- Collect token until terminator. Special: `>&1` etc. emit empty.
        if cmd:sub(i, i) == "&" then
          -- It's an FD dup like `>&1`; skip the dup target.
          i = i + 1
          while i <= #cmd and cmd:sub(i, i):match("[%w_]") do i = i + 1 end
        else
          local start = i
          while i <= #cmd do
            local ch = cmd:sub(i, i)
            if ch:match("[%s&;|<>(){}`]") then break end
            i = i + 1
          end
          if i > start then
            local tok = cmd:sub(start, i - 1)
            if tok ~= "" and not tok:match("^/dev/(null|stdout|stderr|tty)$") then
              table.insert(out, tok)
            end
          end
        end
      end
    else
      i = i + 1
    end
  end
  return out
end

-- `mv SRC DST` / `cp SRC DST` — emit DST. Greedy last token; misses quoted
-- paths with spaces and the GNU `-t DST SRC...` flag (acceptable for Tier 1).
local function detect_mv_cp(cmd)
  local out = {}
  for _, sub in ipairs(each_subcommand(cmd)) do
    local body = sub:match("^%s*mv%s+(.+)$") or sub:match("^%s*cp%s+(.+)$")
    if body then
      local tokens = {}
      for tok in body:gmatch("%S+") do table.insert(tokens, tok) end
      if #tokens > 0 then table.insert(out, tokens[#tokens]) end
    end
  end
  return out
end

-- `tee [-a] FILE` — captures only the first target.
local function detect_tee(cmd)
  local out = {}
  -- Match "tee" optionally followed by "-a", then the next token.
  local body = cmd:match("tee%s+%-a%s+([^%s&;|<>(){}`]+)")
  if body then
    table.insert(out, body)
  else
    body = cmd:match("tee%s+([^%s&;|<>(){}`]+)")
    if body and body ~= "-a" then table.insert(out, body) end
  end
  return out
end

-- `sed -i ... FILE` — last token wins; BSD's backup-suffix would be flagged
-- too (acceptable for Tier 1).
local function detect_sed_i(cmd)
  local out = {}
  -- Match `sed` then a flag-token containing `i`, then capture trailing args
  -- up to the next pipe/semicolon.
  for body in cmd:gmatch("sed%s+%-[%a]*i[%a]*%s+([^|&;]+)") do
    local tokens = {}
    for tok in body:gmatch("%S+") do table.insert(tokens, tok) end
    if #tokens > 0 then table.insert(out, tokens[#tokens]) end
  end
  return out
end

-- ── In-place file editors: perl / ruby / awk ─────────────────────
--
-- Like `sed -i`, these rewrite their trailing file(s) in place (Tier-1
-- indicator only, no diff). They get their own quote-aware path rather than a
-- redirect/`each_subcommand`-style scan because an in-place script routinely
-- contains `;` and `|` (`perl -pi -e 's/a/b/; s/c/d/'`) that the char-walk
-- scanners would mis-cut. We require the in-place flag so read-only one-liners
-- (`perl -ne 'print' f`, `awk '{print}' f`) are never flagged.

-- Quote-aware POSIX tokeniser. Single/double-quoted regions span whitespace and
-- separators and stay attached to their word, so a quoted script is one token.
-- Shell separators (; | || & &&) are emitted as their own tokens so the caller
-- can split into command segments without being fooled by quotes.
local function posix_tokenise(s)
  local toks, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c == "\n" or c == "\r" then
      toks[#toks + 1] = ";"; i = i + 1   -- newline is a command separator
    elseif c:match("%s") then
      i = i + 1
    elseif c == ";" then
      toks[#toks + 1] = ";"; i = i + 1
    elseif c == "|" then
      if s:sub(i + 1, i + 1) == "|" then toks[#toks + 1] = "||"; i = i + 2
      else toks[#toks + 1] = "|"; i = i + 1 end
    elseif c == "&" then
      if s:sub(i + 1, i + 1) == "&" then toks[#toks + 1] = "&&"; i = i + 2
      else toks[#toks + 1] = "&"; i = i + 1 end
    else
      local start = i
      while i <= n do
        local ch = s:sub(i, i)
        if ch == "'" or ch == '"' then
          local q = ch; i = i + 1
          while i <= n and s:sub(i, i) ~= q do i = i + 1 end
          i = i + 1  -- past the closing quote (or end of string)
        elseif ch:match("%s") or ch == ";" or ch == "|" or ch == "&" then
          break
        else
          i = i + 1
        end
      end
      toks[#toks + 1] = s:sub(start, i - 1)
    end
  end
  return toks
end

local INPLACE_SEPARATORS = { [";"] = true, ["|"] = true, ["||"] = true, ["&"] = true, ["&&"] = true }

-- A perl/ruby in-place flag: `-i`, a switch cluster containing `i` (`-pi`,
-- `-0pi`, `-ni`, `-pie`), or `-i.bak`. Excludes `-M<module>` (module names may
-- contain an "i").
local function is_perl_inplace_flag(t)
  if t:match("^%-M") then return false end
  if t:match("^%-i%.%w+$") then return true end       -- -i.bak
  return t:match("^%-%w*i%w*$") ~= nil                 -- -i / -pi / -0pi / -pie
end

local function basename(t) return (t:gsub(".*[/\\]", "")) end

-- File targets for one separator-free command segment.
local function inplace_targets(seg)
  local idx = 1
  if seg[idx] == "sudo" then idx = idx + 1 end
  local exe = basename(seg[idx] or "")

  if exe == "perl" or exe == "ruby" then
    -- The `-e`/`-E` switch may be bundled (`-pe`, `-pie`); detect any flag
    -- cluster ending in e/E, and the in-place flag anywhere in the segment.
    local has_inplace, script_idx = false, nil
    for j = idx + 1, #seg do
      local t = seg[j]
      if not script_idx and t:match("^%-%w*[eE]$") and not t:match("^%-M") then
        script_idx = j
      end
      if is_perl_inplace_flag(t) then has_inplace = true end
    end
    if not (has_inplace and script_idx) then return {} end
    local files = {}
    for j = script_idx + 2, #seg do            -- skip the -e flag and its script
      if not seg[j]:match("^%-") then files[#files + 1] = seg[j] end
    end
    return files

  elseif exe == "awk" or exe == "gawk" then
    -- gawk in-place mode is `-i inplace`; the first positional after it is the
    -- awk program, the rest are files.
    local inplace_at
    for j = idx + 1, #seg - 1 do
      if seg[j] == "-i" and seg[j + 1] == "inplace" then inplace_at = j + 1; break end
    end
    if not inplace_at then return {} end
    local files, seen_program = {}, false
    for j = inplace_at + 1, #seg do
      local t = seg[j]
      if t:match("^%-") then            -- skip flags (-F, -v, …)
      elseif not seen_program then seen_program = true   -- the awk program
      else files[#files + 1] = t end
    end
    return files
  end
  return {}
end

local function detect_inplace_edit(cmd)
  local out, seg = {}, {}
  local function flush()
    if #seg > 0 then
      for _, f in ipairs(inplace_targets(seg)) do out[#out + 1] = f end
    end
    seg = {}
  end
  for _, t in ipairs(posix_tokenise(cmd)) do
    if INPLACE_SEPARATORS[t] then flush() else seg[#seg + 1] = t end
  end
  flush()
  return out
end

-- ── PowerShell command grammar ───────────────────────────────────
--
-- PowerShell cmdlets are PascalCase Verb-Noun (`Remove-Item`) with aliases
-- (`ri`, `del`, `rd`), named parameters (`-Path`, `-Destination`), switches
-- (`-Force`, `-Recurse`), positional args, comma-lists, and here-strings
-- (`@"…"@`) for `-Value`. We deliberately keep the bash aliases (`rm`, `cp`,
-- `mv`, `tee`) OUT of these tables — those are handled by the POSIX grammar
-- above, and excluding them keeps the POSIX behaviour provably unchanged.

-- Tokenise a PowerShell sub-command. Quoted regions (including here-strings)
-- span whitespace and become a single token with their quotes preserved, so a
-- here-string `-Value @"a\nb"@` never leaks its body words as positional paths.
local function ps_tokenise(s)
  local tokens, i, n = {}, 1, #s
  while i <= n do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    else
      local start = i
      while i <= n do
        local ch = s:sub(i, i)
        if ch == "'" or ch == '"' then
          -- Here-string @' / @" (quote preceded by @ then a newline).
          local hs_quote = ch
          if s:sub(i - 1, i - 1) == "@" then
            -- consume to the closing "@ / '@
            i = i + 1
            while i <= n do
              if s:sub(i, i) == hs_quote and s:sub(i + 1, i + 1) == "@" then
                i = i + 2; break
              end
              i = i + 1
            end
          else
            -- ordinary quoted region
            i = i + 1
            while i <= n and s:sub(i, i) ~= hs_quote do i = i + 1 end
            i = i + 1  -- skip closing quote
          end
        elseif ch:match("%s") then
          break
        else
          i = i + 1
        end
      end
      table.insert(tokens, s:sub(start, i - 1))
    end
  end
  return tokens
end

-- Split a parameter value on top-level commas (PowerShell `-Path a,b,c`),
-- ignoring commas inside quotes.
local function ps_split_commas(tok)
  local parts, buf, i, n = {}, {}, 1, #tok
  local q = nil
  while i <= n do
    local c = tok:sub(i, i)
    if q then
      buf[#buf + 1] = c
      if c == q then q = nil end
    elseif c == "'" or c == '"' then
      q = c; buf[#buf + 1] = c
    elseif c == "," then
      parts[#parts + 1] = table.concat(buf); buf = {}
    else
      buf[#buf + 1] = c
    end
    i = i + 1
  end
  parts[#parts + 1] = table.concat(buf)
  return parts
end

-- Parameters that take a following value (lowercased, leading dash stripped).
local PS_VALUE_PARAMS = {
  path = true, literalpath = true, filepath = true, destination = true,
  newname = true, target = true, value = true, encoding = true, width = true,
}
-- Switch parameters that take no value.
local PS_SWITCHES = {
  force = true, recurse = true, confirm = true, whatif = true, verbose = true,
  nonewline = true, noclobber = true, passthru = true, append = true,
}

-- Collect a parameter value starting at token `i`, joining comma-connected
-- tokens so an array literal written with spaces (`-Path "a", "b"`) is captured
-- as a single value `"a","b"` instead of leaking "b" as a stray positional.
-- Stops at a flag (`-Force`) even mid-comma, since that is malformed anyway.
local function ps_gather_value(tokens, i)
  if i > #tokens then return nil, i end
  local parts = { tokens[i] }
  i = i + 1
  while i <= #tokens do
    local prev, cur = parts[#parts], tokens[i]
    if (prev:match(",%s*$") or cur:match("^,")) and not cur:match("^%-[%a]") then
      parts[#parts + 1] = cur
      i = i + 1
    else
      break
    end
  end
  return table.concat(parts), i
end

-- Parse `Verb-Noun` style args into { named = {param=value}, positional = {...} }.
local function ps_parse_args(tokens)
  local named, positional = {}, {}
  local i = 1
  while i <= #tokens do
    local t = tokens[i]
    local pname = t:match("^%-([%a][%w]*)$")
    if pname then
      local key = pname:lower()
      if PS_SWITCHES[key] then
        i = i + 1
      elseif PS_VALUE_PARAMS[key] then
        -- Known value parameter: consume its (possibly comma-list) value. Also
        -- swallows `-Value "x"` so the content never lands in `positional`.
        named[key], i = ps_gather_value(tokens, i + 1)
      else
        -- Unknown parameter: consume a following value only if it isn't a flag;
        -- otherwise treat as a standalone switch.
        local nxt = tokens[i + 1]
        if nxt and not nxt:match("^%-[%a]") then
          named[key], i = ps_gather_value(tokens, i + 1)
        else
          i = i + 1
        end
      end
    else
      -- Positional — also gather a comma-list (`Remove-Item a, b`).
      positional[#positional + 1], i = ps_gather_value(tokens, i)
    end
  end
  return named, positional
end

-- Cmdlet/alias → category. Bash aliases (rm/cp/mv/tee) intentionally excluded.
local PS_DELETE = {
  ["remove-item"] = true, ri = true, del = true, erase = true,
  rd = true, rmdir = true,
}
local PS_WRITE = {
  ["set-content"] = true, sc = true, ["add-content"] = true, ac = true,
  ["out-file"] = true, ["tee-object"] = true,
}
local PS_MOVE = {
  ["move-item"] = true, mi = true, move = true, ["rename-item"] = true,
  ren = true, rni = true,
}
local PS_COPY = {
  ["copy-item"] = true, cpi = true, copy = true,
}

-- Pull the path value(s) for a category out of parsed args. `named_keys` lists
-- the value-params to check in priority order; `pos_index` is the positional
-- fallback (1-based). Returns a list of raw tokens (pre-clean), comma-expanded.
local function ps_targets(named, positional, named_keys, pos_index)
  for _, k in ipairs(named_keys) do
    if named[k] then return ps_split_commas(named[k]) end
  end
  local p = positional[pos_index]
  if p then return ps_split_commas(p) end
  return {}
end

local function detect_ps(subcmd)
  local cmd = subcmd:gsub("^%s+", "")
  local verb = cmd:match("^([%a][%w%-]*)")
  if not verb then return {}, {} end
  local key = verb:lower()

  local category
  if PS_DELETE[key] then category = "delete"
  elseif PS_WRITE[key] then category = "write"
  elseif PS_MOVE[key] then category = "move"
  elseif PS_COPY[key] then category = "copy"
  else return {}, {} end

  local rest = cmd:sub(#verb + 1)
  local named, positional = ps_parse_args(ps_tokenise(rest))

  local rm_raw, write_raw = {}, {}
  if category == "delete" then
    -- Delete can target many files: `-Path "a","b"` (array) and/or several bare
    -- positionals (`Remove-Item a b`). Collect the named path array AND every
    -- positional, each comma-expanded.
    for _, k in ipairs({ "path", "literalpath" }) do
      if named[k] then
        for _, x in ipairs(ps_split_commas(named[k])) do rm_raw[#rm_raw + 1] = x end
      end
    end
    for _, pos in ipairs(positional) do
      for _, x in ipairs(ps_split_commas(pos)) do rm_raw[#rm_raw + 1] = x end
    end
  elseif category == "write" then
    -- Out-File uses -FilePath; Set/Add-Content use -Path; positional 1 either way.
    write_raw = ps_targets(named, positional, { "path", "literalpath", "filepath" }, 1)
  else -- move / copy → the destination is the write target
    write_raw = ps_targets(named, positional, { "destination", "newname" }, 2)
  end
  return rm_raw, write_raw
end

-- ── Aggregation ──────────────────────────────────────────────────

-- Clean → resolve → filter a list of raw path tokens into absolute paths.
local function finalise(raw_list, cwd, adapter, opts)
  opts = opts or {}
  local out, seen = {}, {}
  for _, r in ipairs(raw_list) do
    local p = adapter.clean(r)
    -- rm/delete trust their explicit targets and skip the looks_like_path
    -- heuristic (matches the historical `rm` behaviour); writes/redirects run
    -- it to reject leaked escape sequences and stray tokens.
    if opts.skip_path_check or adapter.looks_like_path(p) then
      local abs = adapter.resolve(p, cwd)
      if abs and (opts.skip_transient or not adapter.is_transient(abs)) and not seen[abs] then
        seen[abs] = true
        out[#out + 1] = abs
      end
    end
  end
  return out
end

-- POSIX `rm`/`sudo rm` returns already-resolved absolute paths; PowerShell
-- delete returns raw tokens that still need clean/resolve. Keep the two sources
-- explicit so the POSIX ones are never double-resolved.
function M.detect_rm_paths(cmd, cwd)
  local adapter = path_adapter()
  local out, seen = {}, {}
  local function add(abs)
    if abs and not seen[abs] then seen[abs] = true; out[#out + 1] = abs end
  end
  for _, sub in ipairs(each_subcommand(cmd)) do
    -- POSIX rm: detect_rm_in returns resolved absolute paths.
    for _, abs in ipairs(detect_rm_in(sub, cwd, adapter)) do add(abs) end
    -- PowerShell delete: raw tokens → clean → resolve.
    local ps_rm = select(1, detect_ps(sub))
    for _, abs in ipairs(finalise(ps_rm, cwd, adapter, { skip_path_check = true, skip_transient = true })) do
      add(abs)
    end
  end
  return out
end

function M.detect_write_paths(cmd, cwd)
  local adapter = path_adapter()
  local raw = {}
  -- Shared redirects + POSIX verbs (these return raw tokens).
  for _, p in ipairs(detect_redirects(cmd)) do raw[#raw + 1] = p end
  for _, p in ipairs(detect_mv_cp(cmd))     do raw[#raw + 1] = p end
  for _, p in ipairs(detect_tee(cmd))       do raw[#raw + 1] = p end
  for _, p in ipairs(detect_sed_i(cmd))     do raw[#raw + 1] = p end
  for _, p in ipairs(detect_inplace_edit(cmd)) do raw[#raw + 1] = p end
  -- PowerShell write / move / copy targets (raw tokens).
  for _, sub in ipairs(each_subcommand(cmd)) do
    local _, ps_write = detect_ps(sub)
    for _, p in ipairs(ps_write) do raw[#raw + 1] = p end
  end
  return finalise(raw, cwd, adapter)
end

--- Combined entry point used by pre_tool.handle for shell proposals.
--- @param cmd string  the raw shell command (POSIX or PowerShell)
--- @param cwd string  project cwd for relative-path resolution
--- @return table  { rm_paths = {...absolute...}, write_paths = {...absolute...} }
function M.detect(cmd, cwd)
  return {
    rm_paths    = M.detect_rm_paths(cmd, cwd),
    write_paths = M.detect_write_paths(cmd, cwd),
  }
end

return M
