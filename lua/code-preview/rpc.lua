-- rpc.lua — Dispatch entry point for hook scripts that call into
-- code-preview from bash via `nvim --server ... --remote-expr`.
--
-- The bash side (bin/nvim-call.sh) writes JSON arguments to a temp file and
-- invokes:
--
--   luaeval("require('code-preview.rpc').dispatch(MOD, FN, FILE)")
--
-- Only the module name, function name, and temp-file path — all controlled
-- by us — are interpolated into the Lua string. User-controlled data
-- (file paths, file contents, etc.) flows through JSON, decoded here. This
-- replaces the older pattern of building Lua source via `escape_lua` in bash,
-- which was the source of every quoting bug in the hook layer.

local M = {}

--- @param mod string  module name, e.g. "code-preview.diff"
--- @param fn string  function name on that module, e.g. "show_diff"
--- @param args_file string  path to a JSON file containing an array of args
--- @return string  the function's return value, JSON-encoded if it's a table,
---                 passed through if it's already a string, "" otherwise.
---
--- Errors are caught and surfaced via log.error (which calls vim.notify), then
--- re-raised so the bash --remote-expr call exits non-zero. The bash side
--- swallows the rc by design — hooks must never block the agent — but the
--- vim.notify ensures the developer sees the failure instead of a silent
--- no-op preview.
function M.dispatch(mod, fn, args_file)
  local ok, result = pcall(function()
    local f, err = io.open(args_file, "r")
    if not f then
      error("open " .. args_file .. ": " .. tostring(err))
    end
    local raw = f:read("*a")
    f:close()

    local args = vim.json.decode(raw)
    -- vim.islist (0.10+) / vim.tbl_islist (older) — JSON arrays only.
    -- A bare object like {"k":"v"} would unpack to zero args and silently
    -- call the target with no arguments.
    local islist = vim.islist or vim.tbl_islist
    if type(args) ~= "table" or not islist(args) then
      error("args file must contain a JSON array, got " .. type(args))
    end

    local module = require(mod)
    local target = module[fn]
    if type(target) ~= "function" then
      error(mod .. "." .. fn .. " is not a function")
    end

    return target(unpack(args))
  end)

  if not ok then
    local msg = string.format("rpc.dispatch(%s, %s): %s", mod, fn, tostring(result))
    require("code-preview.log").error(msg)
    error(msg)
  end

  if result == nil then return "" end
  if type(result) == "string" then return result end
  return vim.json.encode(result)
end

return M
