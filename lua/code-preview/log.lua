--- code-preview.nvim — Logging module
---
--- Opt-in debug logging following Neovim plugin conventions.
--- - WARN/ERROR: shown to user via vim.notify()
--- - DEBUG/INFO: written to log file only (when enabled)
--- - Log file: vim.fn.stdpath("log") .. "/code-preview.log"

local M = {}

local log_file_path = nil
local enabled = false

--- Initialise logging. Called once from setup().
--- @param opts { debug: boolean }
function M.init(opts)
  enabled = opts and opts.debug or false
  if enabled then
    -- vim.fs.normalize keeps the separator consistent: on Windows stdpath("log")
    -- is backslashed (…\nvim-data) and the "/code-preview.log" suffix would
    -- otherwise leave a mixed-separator path. Normalising yields all forward
    -- slashes (which io.open accepts on every OS); on Unix it's a no-op.
    log_file_path = vim.fs.normalize(vim.fn.stdpath("log") .. "/code-preview.log")
  end
end

--- Write a line to the log file. No-op when debug is disabled.
--- @param level string "DEBUG"|"INFO"|"WARN"|"ERROR"
--- @param msg string
local function write(level, msg)
  if not enabled or not log_file_path then
    return
  end
  local f = io.open(log_file_path, "a")
  if not f then
    return
  end
  f:write(string.format("[%s] [%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), level, msg))
  f:close()
end

function M.debug(msg) write("DEBUG", msg) end
function M.info(msg) write("INFO", msg) end

function M.warn(msg)
  write("WARN", msg)
  vim.notify("[code-preview] " .. msg, vim.log.levels.WARN)
end

function M.error(msg)
  write("ERROR", msg)
  vim.notify("[code-preview] " .. msg, vim.log.levels.ERROR)
end

--- Format helper for structured messages.
--- @param template string format string
--- @param ... any format arguments
--- @return string
function M.fmt(template, ...)
  return string.format(template, ...)
end

--- Check whether debug logging is enabled.
--- @return boolean
function M.is_enabled()
  return enabled
end

--- Return the log file path (for shell scripts via hook_context).
--- @return string|nil
function M.get_log_path()
  return log_file_path
end

--- Bundled state for hook-script logging setup. Returns the fields all
--- bash hooks need in one RPC call: debug flag, log file path, this
--- nvim's servername, and its cwd. Backends use the latter two when
--- they want to log which nvim instance the diff is being routed to.
---
--- Consumers (all in backends/): the per-backend code-preview-diff.sh /
--- code-close-diff.sh shims read debug + log_file. copilot/code-preview-diff.sh
--- additionally reads servername + cwd. Renaming any field is a breaking change
--- for those scripts — grep for "log state" before touching this shape.
--- @return { debug: boolean, log_file: string, servername: string, cwd: string }
function M.state()
  return {
    debug     = enabled,
    log_file  = log_file_path or "",
    servername = vim.v.servername or "",
    cwd       = vim.fn.getcwd(),
  }
end

return M
