-- apply/patch.lua — Parse OpenCode/GPT-style patch format and produce
-- per-file original/proposed line lists.
--
-- The patch shape:
--
--   *** Begin Patch
--   *** Update File: path/to/file
--   @@
--   -old line
--   +new line
--    context line
--   *** End Patch
--
-- (Plus *** Add File: and *** Delete File: variants.)
--
-- Pure function: returns a list of {path, rel_path, action, orig, prop} where
-- orig and prop are arrays of lines. The caller decides whether to write them
-- to files (the bin/apply-patch.lua shim does, pre_tool may use them
-- differently in future).

local M = {}

-- Detect already-absolute paths before joining with cwd. Besides a Unix "/",
-- Codex emits Windows-absolute paths in apply_patch directives (a drive-letter
-- `D:\proj\file` / `D:/proj/file`, or a UNC `\\server\share`). Without these
-- checks such a path is treated as relative and doubled onto cwd
-- (`D:\proj\D:\proj\file`), which then fs_stats as missing (so the file is
-- mis-marked "created"), opens the diff at a bogus path, and injects a junk
-- neo-tree node.
local function resolve_path(path, cwd)
  if path:sub(1, 1) == "/"             -- Unix absolute
    or path:match("^%a:[/\\]")         -- Windows drive-letter absolute
    or path:sub(1, 2) == "\\\\" then   -- Windows UNC
    return path
  end
  return cwd .. "/" .. path
end

local function read_lines(path)
  local fh = io.open(path, "r")
  if not fh then
    return {}
  end
  local lines = {}
  for line in fh:lines() do
    table.insert(lines, line)
  end
  fh:close()
  return lines
end

local function apply_hunks(orig_lines, hunks)
  if #hunks == 0 then
    return orig_lines
  end

  local result = {}
  local orig_idx = 1

  for _, hunk in ipairs(hunks) do
    local match_lines = {}
    for _, hl in ipairs(hunk.lines) do
      local prefix = hl:sub(1, 1)
      if prefix == " " then
        table.insert(match_lines, { type = "context", text = hl:sub(2) })
      elseif prefix == "-" then
        table.insert(match_lines, { type = "remove", text = hl:sub(2) })
      elseif prefix == "+" then
        table.insert(match_lines, { type = "add", text = hl:sub(2) })
      else
        table.insert(match_lines, { type = "context", text = hl })
      end
    end

    local first_match_text = nil
    for _, ml in ipairs(match_lines) do
      if ml.type == "context" or ml.type == "remove" then
        first_match_text = ml.text
        break
      end
    end

    if first_match_text then
      while orig_idx <= #orig_lines do
        if orig_lines[orig_idx] == first_match_text then
          break
        end
        table.insert(result, orig_lines[orig_idx])
        orig_idx = orig_idx + 1
      end
    end

    for _, ml in ipairs(match_lines) do
      if ml.type == "context" then
        table.insert(result, ml.text)
        orig_idx = orig_idx + 1
      elseif ml.type == "remove" then
        orig_idx = orig_idx + 1
      elseif ml.type == "add" then
        table.insert(result, ml.text)
      end
    end
  end

  while orig_idx <= #orig_lines do
    table.insert(result, orig_lines[orig_idx])
    orig_idx = orig_idx + 1
  end

  return result
end

local function parse_sections(patch_text)
  local files = {}
  local current_file = nil
  local current_action = nil

  for line in (patch_text .. "\n"):gmatch("([^\n]*)\n") do
    local update_path = line:match("^%*%*%* Update File:%s*(.+)$")
    local add_path = line:match("^%*%*%* Add File:%s*(.+)$")
    local delete_path = line:match("^%*%*%* Delete File:%s*(.+)$")

    if update_path then
      current_file = { path = update_path:gsub("%s+$", ""), action = "update", hunks = {}, current_hunk = nil }
      table.insert(files, current_file)
      current_action = "update"
    elseif add_path then
      current_file = { path = add_path:gsub("%s+$", ""), action = "add", hunks = {}, current_hunk = nil }
      table.insert(files, current_file)
      current_action = "add"
    elseif delete_path then
      current_file = { path = delete_path:gsub("%s+$", ""), action = "delete", hunks = {}, current_hunk = nil }
      table.insert(files, current_file)
      current_action = "delete"
    elseif line:match("^@@") and current_file then
      current_file.current_hunk = { lines = {} }
      table.insert(current_file.hunks, current_file.current_hunk)
    elseif line == "*** End Patch" or line == "*** Begin Patch" then
      current_file = nil
    elseif current_file then
      -- `*** Add File:` in the GPT patch format has no `@@` marker — lazy-
      -- create a hunk on first content line so those lines aren't dropped.
      if not current_file.current_hunk and current_action == "add" then
        current_file.current_hunk = { lines = {} }
        table.insert(current_file.hunks, current_file.current_hunk)
      end
      if current_file.current_hunk then
        table.insert(current_file.current_hunk.lines, line)
      end
    end
  end

  return files
end

--- @param patch_text string  the raw patch text
--- @param cwd string  cwd used to resolve relative paths
--- @return table  list of {path, rel_path, action, orig, prop} where
---                orig and prop are arrays of lines
function M.parse(patch_text, cwd)
  local files = parse_sections(patch_text)
  local results = {}

  for _, file_section in ipairs(files) do
    local abs_path = resolve_path(file_section.path, cwd)
    local orig_lines, prop_lines

    if file_section.action == "delete" then
      orig_lines = read_lines(abs_path)
      prop_lines = {}
    elseif file_section.action == "add" then
      orig_lines = {}
      prop_lines = {}
      for _, hunk in ipairs(file_section.hunks) do
        for _, hl in ipairs(hunk.lines) do
          if hl:sub(1, 1) == "+" then
            table.insert(prop_lines, hl:sub(2))
          elseif hl:sub(1, 1) ~= "-" then
            table.insert(prop_lines, hl)
          end
        end
      end
    else
      orig_lines = read_lines(abs_path)
      prop_lines = apply_hunks(orig_lines, file_section.hunks)
    end

    table.insert(results, {
      path = abs_path,
      rel_path = file_section.path,
      action = file_section.action,
      orig = orig_lines,
      prop = prop_lines,
    })
  end

  return results
end

-- Exposed so the PostToolUse handler resolves a patch's file path identically to
-- the PreToolUse open path. A separate copy of this join in post_tool was what
-- let the Windows-absolute doubling be fixed on open but not on close (the diff
-- opened under the clean path but post tried to close a doubled one).
M.resolve_path = resolve_path

return M
