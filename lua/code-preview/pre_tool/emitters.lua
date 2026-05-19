-- pre_tool/emitters.lua — Per-backend stdout shape produced by handle().
--
-- The hook-entry shim prints whatever string handle() returns. For most
-- backends that's empty (the hook is a side effect, not a permission gate).
-- For Claude Code the plugin actively emits a permissionDecision JSON envelope
-- so the agent prompts the user before writing — unless the user has set
-- diff.defer_claude_permissions, in which case we abstain and let Claude
-- Code's own permission settings win.

local M = {}

local function none(_ctx)
  return ""
end

local function claudecode(ctx)
  if ctx.has_nvim == false then return "" end
  if ctx.defer_claude_permissions then return "" end
  local reason = "Diff preview sent to Neovim. Review before accepting."
  return vim.json.encode({
    hookSpecificOutput = {
      hookEventName = "PreToolUse",
      permissionDecision = "ask",
      permissionDecisionReason = reason,
    },
  }) .. "\n"
end

M.emitters = {
  claudecode = claudecode,
  opencode   = none,
  -- codex / copilot / gemini default to `none` via the fallback below.
}

--- @param backend string
--- @param ctx table  { has_nvim, defer_claude_permissions, ... }
--- @return string  bytes to print to stdout from the hook-entry shim
function M.emit(backend, ctx)
  local fn = M.emitters[backend] or none
  return fn(ctx)
end

return M
