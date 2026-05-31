-- pidfile.lua — Self-registers this nvim's RPC socket + cwd so the hook
-- scripts can find it without OS-specific socket-glob discovery.
--
-- File format (two lines):
--   <socket path>
--   <cwd>
--
-- Location: ${XDG_STATE_HOME:-$HOME/.local/state}/code-preview/sockets/<pid>
-- The same path is computed by bin/nvim-socket.sh.

local M = {}

function M.dir()
  -- This path must be computed identically by the shim reader (bin/nvim-socket.sh
  -- on Unix, the PowerShell shim on Windows), which has no running Neovim and so
  -- cannot call stdpath(). That is why we build the path from raw env vars rather
  -- than vim.fn.stdpath('state'): on Windows the two would NOT agree (stdpath
  -- resolves to %LOCALAPPDATA%\nvim-data), and the shim couldn't replicate it.
  -- See issue #46 / ADR-0007.
  if vim.fn.has("win32") == 1 then
    -- The Unix $XDG_STATE_HOME/$HOME formula yields a driveless garbage path on
    -- Windows; use %LOCALAPPDATA% (always set on Windows 11, machine-local —
    -- correct for per-machine named-pipe registration).
    local local_appdata = vim.env.LOCALAPPDATA or ""
    return local_appdata .. "\\code-preview\\sockets"
  end
  local state = vim.env.XDG_STATE_HOME
  if not state or state == "" then
    state = (vim.env.HOME or "") .. "/.local/state"
  end
  return state .. "/code-preview/sockets"
end

function M.path()
  return M.dir() .. "/" .. tostring(vim.fn.getpid())
end

local function write()
  local socket = vim.v.servername or ""
  if socket == "" then return end

  vim.fn.mkdir(M.dir(), "p")

  local f, err = io.open(M.path(), "w")
  if not f then
    require("code-preview.log").warn("pidfile: open failed: " .. tostring(err))
    return
  end
  f:write(socket, "\n", vim.fn.getcwd(), "\n")
  f:close()
end

local function remove()
  pcall(os.remove, M.path())
end

function M.setup()
  -- Initial write
  pcall(write)

  local group = vim.api.nvim_create_augroup("CodePreviewPidfile", { clear = true })

  -- Refresh cwd line when the user :cd's so socket discovery stays accurate.
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function() pcall(write) end,
  })

  -- Re-write if servername changes (rare, but possible via :let v:servername).
  vim.api.nvim_create_autocmd("VimEnter", {
    group = group,
    callback = function() pcall(write) end,
  })

  -- Cleanup on exit
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = remove,
  })
end

return M
