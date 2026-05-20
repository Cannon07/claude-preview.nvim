-- post_tool.lua — In-process orchestration for PostToolUse hooks.
--
-- Replaces bin/core-post-tool.sh (which remains alive for not-yet-flipped
-- backends). The hook-entry shim passes the raw decoded hook JSON plus the
-- backend name; handle() clears the relevant changes, closes the matching
-- preview(s), and refreshes neo-tree.
--
-- Tempfile cleanup is delegated to the OS (/tmp eviction); we do not rm the
-- per-proposal tempfiles here. The bash version did, but it was best-effort
-- and survived restarts via wildcard sweep — relying on /tmp hygiene is
-- equally fine and removes a class of "did I race the next hook?" bugs.

local M = {}

local normalisers = require("code-preview.pre_tool.normalisers")
local changes     = require("code-preview.changes")
local neo_tree    = require("code-preview.neo_tree")
local diff        = require("code-preview.diff")
local log         = require("code-preview.log")

-- Extract paths from both unified-diff (+++ lines) and custom-patch
-- (*** Update/Add/Delete File:) formats.
local function patch_paths(patch_text, cwd)
  local paths = {}
  for line in (patch_text .. "\n"):gmatch("([^\n]*)\n") do
    local plus = line:match("^%+%+%+ (.+)$")
    if plus then
      plus = plus:gsub("^b/", "")
      if plus ~= "/dev/null" then
        table.insert(paths, plus)
      end
    end
    local custom = line:match("^%*%*%* %a+ File:%s*(.+)$")
    if custom then
      -- gsub returns (string, count); parens discard the count so table.insert
      -- doesn't fall into its (t, pos, value) 3-arg form.
      table.insert(paths, (custom:gsub("%s+$", "")))
    end
  end
  -- Resolve relative paths against cwd.
  local out = {}
  for _, p in ipairs(paths) do
    if p:sub(1, 1) ~= "/" and cwd and cwd ~= "" then
      table.insert(out, cwd .. "/" .. p)
    else
      table.insert(out, p)
    end
  end
  return out
end

--- Handle a normalised PostToolUse hook.
--- @param raw table  decoded hook payload (per-backend shape)
--- @param backend string  CODE_PREVIEW_BACKEND value
--- @return string  always empty — post-tool produces no stdout for any backend
function M.handle(raw, backend)
  local input = normalisers.normalise(raw, backend)
  local tool_name = input and input.tool_name

  log.info(log.fmt("post_tool: tool=%s backend=%s", tostring(tool_name), tostring(backend)))

  if tool_name == "Bash" then
    -- Bash pre-hook set deleted / bash_* markers without opening a preview.
    -- Clear those statuses specifically so we don't clobber `modified` markers
    -- from concurrent Edit/Write/ApplyPatch whose post-hook hasn't fired.
    changes.clear_by_statuses({ "deleted", "bash_modified", "bash_created" })
    neo_tree.refresh_deferred(200)
    return ""
  end

  if tool_name == "ApplyPatch" then
    local patch_text = input.tool_input and input.tool_input.patch_text
    if patch_text and patch_text ~= "" then
      for _, fpath in ipairs(patch_paths(patch_text, input.cwd or "")) do
        log.info(log.fmt("post_tool: close patch file=%s", fpath))
        diff.close_for_file(fpath)
      end
    end
    return ""
  end

  local file_path = input.tool_input and input.tool_input.file_path
  if file_path and file_path ~= "" then
    log.info(log.fmt("post_tool: close file=%s", file_path))
    diff.close_for_file(file_path)
  end

  return ""
end

return M
