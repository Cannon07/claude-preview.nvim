-- pre_tool/bash_detect.lua — Tier 1 shell-write + rm detection.
--
-- Inputs: a Bash command string and the project cwd.
-- Output: a structured table { rm_paths = {...}, write_paths = {...} }.
--
-- This is a port of the regex-based detection that lived inline in
-- bin/core-pre-tool.sh. The edge cases here all come from real bugs; resist
-- "obvious simplifications" without first reading bash_detect_spec.lua.

local M = {}

-- Resolve a raw token (possibly relative, possibly ~-prefixed) to an absolute
-- path. Caller is responsible for unquoting first.
local function resolve(p, cwd)
  if p == "" then return nil end
  if p:sub(1, 1) == "/" then return p end
  if p == "~" then return os.getenv("HOME") or "~" end
  if p:sub(1, 2) == "~/" then
    return (os.getenv("HOME") or "~") .. "/" .. p:sub(3)
  end
  return cwd .. "/" .. p
end

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
local SHELL_ESCAPED = { ["'"]=true, ['"']=true, ["\\"]=true, [" "]=true, ["$"]=true, ["&"]=true }
local function shell_unescape(s)
  return (s:gsub("\\(.)", function(c) return SHELL_ESCAPED[c] and c or ("\\" .. c) end))
end

-- True if the string looks like a transient file we should skip.
local function is_transient(p)
  if p:match("%.tmp$") or p:match("%.bak$") or p:match("%.swp$") then return true end
  if p:sub(-1) == "~" then return true end
  if p:sub(1, 5) == "/dev/" then return true end
  return false
end

-- Reject obvious non-paths (leaked escape sequences, stray quotes, etc.).
-- This catches cases like `printf '<!-- note -->\n\n'` where the regex picks
-- up `\n\n'` from inside a quoted string.
local function looks_like_path(p)
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

-- ── rm detection ─────────────────────────────────────────────────

-- Iterate sub-commands separated by ; && || (single or double).
local function each_subcommand(cmd)
  local parts = {}
  local buf = {}
  local i = 1
  while i <= #cmd do
    local c = cmd:sub(i, i)
    local n = cmd:sub(i + 1, i + 1)
    if c == ";" then
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

local function detect_rm_in(subcmd, cwd)
  local cmd = subcmd:gsub("^%s+", "")
  -- Optional `sudo `, then `rm` as standalone command.
  local body = cmd:match("^sudo%s+rm%s+(.*)$") or cmd:match("^rm%s+(.*)$")
  if not body then return {} end

  local paths = {}
  for token in body:gmatch("%S+") do
    -- Skip flags (-rf, --force, etc.). Single-dash followed by alpha; or `--`.
    if not token:match("^%-") then
      local p = shell_unescape(unquote(token))
      -- Strip trailing CR (Windows-style payloads).
      p = p:gsub("\r$", "")
      if p ~= "" then
        local abs = resolve(p, cwd)
        if abs then table.insert(paths, abs) end
      end
    end
  end
  return paths
end

function M.detect_rm_paths(cmd, cwd)
  local out = {}
  local seen = {}
  for _, sub in ipairs(each_subcommand(cmd)) do
    for _, p in ipairs(detect_rm_in(sub, cwd)) do
      if not seen[p] then
        seen[p] = true
        table.insert(out, p)
      end
    end
  end
  return out
end

-- ── write-path detection ────────────────────────────────────────

-- Match output redirections (`>`, `>>`, `&>`, `&>>`) and capture the filename.
-- Excludes FD redirections (`2>&1`) by requiring no digit prefix on bare `>`.
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

function M.detect_write_paths(cmd, cwd)
  local raw = {}
  for _, p in ipairs(detect_redirects(cmd)) do table.insert(raw, p) end
  for _, p in ipairs(detect_mv_cp(cmd))     do table.insert(raw, p) end
  for _, p in ipairs(detect_tee(cmd))       do table.insert(raw, p) end
  for _, p in ipairs(detect_sed_i(cmd))     do table.insert(raw, p) end

  local out = {}
  local seen = {}
  for _, r in ipairs(raw) do
    local p = shell_unescape(unquote(r))
    if looks_like_path(p) then
      local abs = resolve(p, cwd)
      if abs and not is_transient(abs) and not seen[abs] then
        seen[abs] = true
        table.insert(out, abs)
      end
    end
  end
  return out
end

--- Combined entry point used by pre_tool.handle for Bash proposals.
--- @param cmd string  the raw Bash command
--- @param cwd string  project cwd for relative-path resolution
--- @return table  { rm_paths = {...absolute...}, write_paths = {...absolute...} }
function M.detect(cmd, cwd)
  return {
    rm_paths    = M.detect_rm_paths(cmd, cwd),
    write_paths = M.detect_write_paths(cmd, cwd),
  }
end

return M
