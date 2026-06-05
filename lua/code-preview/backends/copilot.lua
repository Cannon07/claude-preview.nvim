local M = {}

-- Resolve plugin root from this file's location
local function plugin_root()
  local src = debug.getinfo(1, "S").source
  local lua_file = src:sub(2)
  local lua_dir = vim.fn.fnamemodify(lua_file, ":h")
  -- Go up three levels: backends/ → code-preview/ → lua/ → plugin root
  return vim.fn.fnamemodify(lua_dir, ":h:h:h")
end

local platform = require("code-preview.platform")

local function bin_dir() return plugin_root() .. "/bin" end
-- Copilot's hook field is `bash` (the value runs under a bash shell), so it
-- always invokes the .sh shim — the PowerShell-wrapped command form doesn't
-- apply to this field shape. Copilot-on-Windows (which would need git-bash)
-- is deferred (issue #46).
local function hook_script() return bin_dir() .. "/hook-entry.sh" end

local function hooks_dir()   return vim.fn.getcwd() .. "/.github/hooks" end
local function config_path() return hooks_dir() .. "/code-preview.json" end

-- Shell-quote a path for use inside the `bash` field of hooks.json.
local function shquote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- True iff `path` looks like a code-preview.json our installer produced. We
-- match on the hook-entry shim stem ("hook-entry"), with "code-preview-diff"
-- kept so older per-backend installs are still recognised for uninstall after
-- an upgrade. Specific enough that user-authored hook files are unlikely to
-- collide. Guards status display and uninstall from misidentifying a
-- user-owned file with the same name.
function M.is_our_config(path)
  if vim.fn.filereadable(path) == 0 then return false end
  local f = io.open(path, "r")
  if not f then return false end
  local content = f:read("*a")
  f:close()
  if not content then return false end
  return content:find("hook-entry", 1, true) ~= nil
      or content:find("code-preview-diff", 1, true) ~= nil
end

local function ensure_executable(path)
  if vim.fn.filereadable(path) == 0 then
    vim.notify("[code-preview] script not found: " .. path, vim.log.levels.ERROR)
    return false
  end
  platform.make_executable(path)  -- chmod +x on Unix; no-op on Windows
  return true
end

function M.install()
  local hook = hook_script()
  if not ensure_executable(hook) then return end

  vim.fn.mkdir(hooks_dir(), "p")

  -- The bash field runs the shim under bash with the backend + event args.
  local data = {
    version = 1,
    hooks = {
      preToolUse  = { { type = "command", bash = shquote(hook) .. " copilot pre",  timeoutSec = 30 } },
      postToolUse = { { type = "command", bash = shquote(hook) .. " copilot post", timeoutSec = 30 } },
    },
  }

  local path = config_path()
  local f = assert(io.open(path, "w"), "Cannot write to " .. path)
  f:write(vim.json.encode(data))
  f:close()

  vim.notify("[code-preview] Copilot CLI hooks installed → " .. path, vim.log.levels.INFO)
end

--- Report whether the Copilot CLI hooks config was produced by our installer.
--- @return { state: "installed"|"missing", warnings: string[]? }
function M.install_state()
  if M.is_our_config(config_path()) then
    return { state = "installed" }
  end
  return { state = "missing" }
end

function M.uninstall()
  local path = config_path()
  if vim.fn.filereadable(path) == 0 then
    vim.notify("[code-preview] No Copilot hooks found at " .. path, vim.log.levels.WARN)
    return
  end
  if not M.is_our_config(path) then
    vim.notify(
      "[code-preview] Refusing to remove " .. path .. ": not produced by code-preview install. Delete it manually if intentional.",
      vim.log.levels.WARN
    )
    return
  end
  vim.fn.delete(path)
  -- Try to prune the hooks dir if it became empty (don't touch parents).
  pcall(vim.fn.delete, hooks_dir(), "d")
  vim.notify("[code-preview] Copilot CLI hooks uninstalled", vim.log.levels.INFO)
end

return M
