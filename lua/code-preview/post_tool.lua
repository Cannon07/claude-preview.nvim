-- post_tool.lua — In-process orchestration for PostToolUse hooks.
--
-- The per-backend hook-entry shim passes the raw decoded hook JSON plus the
-- backend name; handle() clears the relevant changes, closes the matching
-- preview(s), and refreshes neo-tree. See docs/adr/0005-core-handler-runs-in-process.md.
--
-- Tempfile cleanup is delegated to the OS (/tmp eviction); we do not rm the
-- per-proposal tempfiles here. The historical bash post-tool did, via a global
-- wildcard sweep — relying on /tmp hygiene is equally fine and removes a class
-- of "did I race the next hook?" bugs.

local M = {}

local normalisers  = require("code-preview.pre_tool.normalisers")
local changes      = require("code-preview.changes")
local neo_tree     = require("code-preview.neo_tree")
local diff         = require("code-preview.diff")
local log          = require("code-preview.log")
local apply_patch  = require("code-preview.apply.patch")
local shell_detect = require("code-preview.pre_tool.shell_detect")

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
  -- Resolve relative paths against cwd. Reuse apply.patch.resolve_path so the
  -- close path matches the open path exactly — including Windows-absolute
  -- handling (a private copy here is what previously doubled cwd onto an
  -- already-absolute path, so close never matched the open diff).
  local out = {}
  for _, p in ipairs(paths) do
    table.insert(out, apply_patch.resolve_path(p, cwd or ""))
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
    -- Clear only THIS command's files, not every bash-owned marker: a global
    -- status sweep wiped the still-pending markers of concurrent Bash commands
    -- (issue #83). Detection is deterministic, so re-running it on the post
    -- payload yields exactly the paths pre_tool marked — mirroring how the
    -- ApplyPatch branch closes specific files via patch_paths. This also keeps
    -- concurrent Edit/Write `modified`/`created` markers untouched, since those
    -- paths never appear in a shell command's detection.
    local cmd = input.tool_input and input.tool_input.command or ""
    local detected = shell_detect.detect(cmd, input.cwd or "")
    for _, p in ipairs(detected.rm_paths)    do changes.clear(p) end
    for _, p in ipairs(detected.write_paths) do changes.clear(p) end
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
