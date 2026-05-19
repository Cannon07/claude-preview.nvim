-- pre_tool/normalisers.lua — Per-backend hook payload normalisation.
--
-- Every backend passes the raw hook payload (parsed from JSON) and a backend
-- name; the matching normaliser returns the canonical shape consumed by
-- pre_tool.handle:
--
--   { tool_name = "Edit"|"Write"|"MultiEdit"|"Bash"|"ApplyPatch",
--     cwd       = "/abs/path",
--     tool_input = { file_path, ..., (tool-specific fields) } }
--
-- Today most backends pre-normalise on their own side (Claude Code's hook
-- format is already canonical; OpenCode's TS plugin maps camelCase →
-- snake_case before invoking us), so most entries here are identity. New
-- backends slot in by adding a function to the table.

local M = {}

local function identity(raw)
  return raw
end

M.normalisers = {
  claudecode = identity,
  opencode   = identity,
  -- codex / copilot / gemini will land their own normalisers as they flip.
}

--- @param raw table  decoded hook payload
--- @param backend string  CODE_PREVIEW_BACKEND value
--- @return table  { tool_name, cwd, tool_input }
function M.normalise(raw, backend)
  local fn = M.normalisers[backend] or identity
  return fn(raw)
end

return M
