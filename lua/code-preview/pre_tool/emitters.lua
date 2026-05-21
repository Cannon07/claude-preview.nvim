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

-- Only Edit / Write / MultiEdit prompt for review under Claude Code. Bash,
-- ApplyPatch, and unknown tools must produce no stdout (matches the bash
-- core's `*) exit 0;;` / per-case early exits before the permission block).
local CLAUDECODE_EMIT_TOOLS = { Edit = true, Write = true, MultiEdit = true }

local function claudecode(ctx)
  if ctx.defer_claude_permissions then return "" end
  if not CLAUDECODE_EMIT_TOOLS[ctx.tool_name or ""] then return "" end
  -- Hand-built JSON: vim.json.encode doesn't preserve table key order, so
  -- the string varies across Lua hash seeds. The downstream consumer
  -- (Claude Code) doesn't care about order, but the shell-level tests
  -- assert byte-exact output. Keep the order matching the historical
  -- bash printf format: hookEventName, permissionDecision, permissionDecisionReason.
  return '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Diff preview sent to Neovim. Review before accepting."}}\n'
end

M.emitters = {
  claudecode = claudecode,
  opencode   = none,
  copilot    = none,
  -- codex / gemini default to `none` via the fallback below.
}

--- @param backend string
--- @param ctx table  { has_nvim, defer_claude_permissions, ... }
--- @return string  bytes to print to stdout from the hook-entry shim
function M.emit(backend, ctx)
  local fn = M.emitters[backend] or none
  return fn(ctx)
end

return M
