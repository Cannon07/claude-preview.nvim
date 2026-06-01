-- pre_tool/init.lua — In-process orchestration for PreToolUse hooks.
--
-- The per-backend hook-entry shim passes the raw decoded hook JSON plus the
-- backend name; handle() does normalisation, tool dispatch, side effects
-- (changes registry, neo-tree refresh, diff.show_diff), and returns the
-- per-backend stdout bytes.
--
-- See docs/adr/0005-core-handler-runs-in-process.md.

local M = {}

local normalisers = require("code-preview.pre_tool.normalisers")
local emitters    = require("code-preview.pre_tool.emitters")
local bash_detect = require("code-preview.pre_tool.bash_detect")

local apply_edit       = require("code-preview.apply.edit")
local apply_multi_edit = require("code-preview.apply.multi_edit")
local apply_patch      = require("code-preview.apply.patch")

local changes  = require("code-preview.changes")
local neo_tree = require("code-preview.neo_tree")
local diff     = require("code-preview.diff")
local log      = require("code-preview.log")

-- ── Tempfile helpers ─────────────────────────────────────────────
-- The historical bash flow used $$ to namespace /tmp/claude-diff-* tempfiles.
-- In-process Lua uses hrtime + a monotonic counter so multiple proposals in
-- the same Neovim never collide. Tempfile prefix is now code-preview-* (see #60).

local _counter = 0
local function next_id()
  _counter = _counter + 1
  return string.format("%d-%d", vim.loop.hrtime(), _counter)
end

local function tmpdir()
  -- Windows has no /tmp, and $TMPDIR is usually unset there (it's a POSIX
  -- convention); a normal user nvim would otherwise fall through to "/tmp",
  -- which resolves to a nonexistent C:\tmp and makes every diff tempfile write
  -- fail. Use the standard Windows temp vars, falling back to nvim's own temp
  -- dir, and forward-slash it so it composes cleanly with the "/code-preview-*"
  -- suffixes below (issue #46). The Unix branch is left byte-identical — the
  -- macOS path and the shell E2E suite depend on $TMPDIR/"/tmp" exactly.
  if vim.fn.has("win32") == 1 then
    local dir = os.getenv("TMP") or os.getenv("TEMP")
      or vim.fn.fnamemodify(vim.fn.tempname(), ":h")
    return (dir:gsub("\\", "/"))
  end
  return os.getenv("TMPDIR") or "/tmp"
end

-- One-time startup sweep of leftover proposal tempfiles.
--
-- Per-proposal tempfile tracking is a follow-up (see issue #64). To prevent
-- unbounded accumulation across long sessions where Neovim doesn't restart,
-- run the sweep once at setup(). macOS doesn't auto-evict /tmp under a few
-- days, so this matters in practice.
--
-- The old claude-* patterns are matched transitionally so leftover tempfiles
-- from prior nvim sessions (pre-#60) still get cleaned up. Drop the old
-- patterns one release after this bridge ships, once users on the prior
-- version have had a chance to upgrade.
function M.sweep_leftover_tempfiles()
  local dir = tmpdir()
  local fd = vim.loop.fs_scandir(dir)
  if not fd then return end
  while true do
    local name = vim.loop.fs_scandir_next(fd)
    if not name then break end
    if name:match("^code%-preview%-diff%-original%-") or
       name:match("^code%-preview%-diff%-proposed%-") or
       name:match("^code%-preview%-patch%-") or
       -- transitional; drop in v1.2
       name:match("^claude%-diff%-original%-") or
       name:match("^claude%-diff%-proposed%-") or
       name:match("^claude%-patch%-") then
      pcall(vim.loop.fs_unlink, dir .. "/" .. name)
    end
  end
end

local function write_file(path, content)
  local fh = assert(io.open(path, "w"))
  fh:write(content or "")
  fh:close()
end

local function copy_or_empty(src_path, dst_path)
  local fh = io.open(src_path, "r")
  if fh then
    local content = fh:read("*a")
    fh:close()
    write_file(dst_path, content)
  else
    write_file(dst_path, "")
  end
end

-- ── In-process hook context (replaces hook_context RPC) ──────────

local function file_visible(file_path)
  if not file_path or file_path == "" then return false end
  local target = vim.uv.fs_realpath(file_path) or vim.fn.fnamemodify(file_path, ":p")
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    local raw = vim.api.nvim_buf_get_name(b)
    if raw ~= "" then
      local name = vim.uv.fs_realpath(raw) or vim.fn.fnamemodify(raw, ":p")
      if name == target then return true end
    end
  end
  return false
end

local function should_show(cfg, file_path)
  if not (cfg.diff and cfg.diff.visible_only) then return true end
  return file_visible(file_path)
end

-- ── Per-tool handlers ───────────────────────────────────────────

-- Compute the orig/proposed tempfile pair for a single-file tool and hand off
-- to diff.show_diff (or skip when visible_only excludes the file). The only
-- per-tool variation is how `proposed_content` is computed, so each handler
-- below is a one-liner around this helper.
local function present_single_file(file_path, proposed_content, input, cfg)
  local id = next_id()
  local orig = tmpdir() .. "/code-preview-diff-original-" .. id
  local prop = tmpdir() .. "/code-preview-diff-proposed-" .. id

  copy_or_empty(file_path, orig)
  write_file(prop, proposed_content)

  if not should_show(cfg, file_path) then
    log.info(log.fmt("pre_tool: skipping diff for %s (visible_only)", file_path))
    return
  end

  local display = file_path
  if input.cwd and file_path:sub(1, #input.cwd + 1) == input.cwd .. "/" then
    display = file_path:sub(#input.cwd + 2)
  end
  diff.show_diff(orig, prop, display, file_path, nil)
end

local function handle_edit(input, cfg)
  local fp = input.tool_input.file_path
  local content = apply_edit.apply(
    fp,
    input.tool_input.old_string or "",
    input.tool_input.new_string or "",
    input.tool_input.replace_all == true
  )
  present_single_file(fp, content, input, cfg)
end

local function handle_write(input, cfg)
  local fp = input.tool_input.file_path
  present_single_file(fp, input.tool_input.content or "", input, cfg)
end

local function handle_multi_edit(input, cfg)
  local fp = input.tool_input.file_path
  local content = apply_multi_edit.apply(fp, input.tool_input.edits or {})
  present_single_file(fp, content, input, cfg)
end

local function handle_bash(input)
  local cmd = input.tool_input.command or ""
  local detected = bash_detect.detect(cmd, input.cwd or "")

  local touched = false

  -- rm first (rm wins for reveal precedence).
  for _, p in ipairs(detected.rm_paths) do
    changes.set(p, "deleted")
    touched = true
  end

  for _, p in ipairs(detected.write_paths) do
    local status = vim.uv.fs_stat(p) and "bash_modified" or "bash_created"
    changes.set(p, status)
    touched = true
  end

  if touched then
    log.info(log.fmt("pre_tool: bash rm=%d write=%d",
      #detected.rm_paths, #detected.write_paths))
    neo_tree.refresh()
    -- Reveal: rm beats write.
    local target = detected.rm_paths[1] or detected.write_paths[1]
    if target then
      neo_tree.reveal_deferred(target, 300)
    end
  end
end

local function handle_apply_patch(input, cfg)
  local patch_text = input.tool_input and input.tool_input.patch_text
  if not patch_text or patch_text == "" then
    log.info("pre_tool: ApplyPatch with empty patch_text")
    return
  end

  local id = next_id()
  local outdir = tmpdir() .. "/code-preview-patch-out-" .. id
  vim.fn.mkdir(outdir, "p")

  local files = apply_patch.parse(patch_text, input.cwd or "")

  local function write_lines(path, lines)
    local fh = assert(io.open(path, "w"))
    for i, line in ipairs(lines) do
      fh:write(line)
      if i < #lines then fh:write("\n") end
    end
    if #lines > 0 then fh:write("\n") end
    fh:close()
  end

  for i, file in ipairs(files) do
    local tag = string.format("%02d", i)
    local orig = outdir .. "/" .. tag .. "-orig"
    local prop = outdir .. "/" .. tag .. "-prop"
    write_lines(orig, file.orig)
    write_lines(prop, file.prop)

    if should_show(cfg, file.path) then
      log.info(log.fmt("pre_tool: ApplyPatch send %s action=%s", file.rel_path, file.action))
      diff.show_diff(orig, prop, file.rel_path, file.path, file.action)
    else
      log.info(log.fmt("pre_tool: ApplyPatch skip %s (visible_only)", file.rel_path))
    end
  end
end

local dispatchers = {
  Edit       = handle_edit,
  Write      = handle_write,
  MultiEdit  = handle_multi_edit,
  Bash       = function(input, _cfg) handle_bash(input) end,
  ApplyPatch = handle_apply_patch,
}

-- ── Public entry ─────────────────────────────────────────────────

--- Handle a normalised PreToolUse hook.
--- @param raw table  decoded hook payload (per-backend shape)
--- @param backend string  CODE_PREVIEW_BACKEND value
--- @return string  bytes the hook-entry shim should print to stdout
function M.handle(raw, backend)
  local cfg = require("code-preview").config or {}
  local input = normalisers.normalise(raw, backend)
  local tool_name = input and input.tool_name

  log.info(log.fmt("pre_tool: tool=%s backend=%s", tostring(tool_name), tostring(backend)))

  local fn = dispatchers[tool_name]
  if fn then
    local ok, err = pcall(fn, input, cfg)
    if not ok then
      log.error("pre_tool: dispatch failed: " .. tostring(err))
    end
  end

  return emitters.emit(backend, {
    tool_name = tool_name,
    defer_claude_permissions = cfg.diff and cfg.diff.defer_claude_permissions or false,
  })
end

return M
