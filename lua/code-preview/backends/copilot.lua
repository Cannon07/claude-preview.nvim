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
-- Copilot's hook entry carries BOTH a `bash` and a `powershell` field (issue
-- #46). Copilot picks the one matching the OS: `bash` runs hook-entry.sh on
-- macOS/Linux, `powershell` runs hook-entry.ps1 on Windows. Unlike Claude
-- Code/Codex — where our installer writes the interpreter into the command and
-- gets Windows PowerShell 5.1 — Copilot runs the `powershell` field's string
-- itself under pwsh 7+, so we emit a bare `& '<path>' …` invocation rather than
-- reusing platform.hook_command's 5.1 `powershell -File` form.
local function sh_hook_script() return bin_dir() .. "/hook-entry.sh" end
local function ps_hook_script() return bin_dir() .. "/hook-entry.ps1" end

local function hooks_dir()   return vim.fn.getcwd() .. "/.github/hooks" end
local function config_path() return hooks_dir() .. "/code-preview.json" end

-- Quote a path for the `bash` field (POSIX single-quote escaping).
local function shquote(s)
  return "'" .. s:gsub("'", "'\\''") .. "'"
end

-- Quote a path for the `powershell` field (PowerShell single-quote escaping:
-- a literal ' is doubled). Paired with the call operator (`& '<path>'`) so
-- paths containing spaces invoke correctly.
local function psquote(s)
  return "'" .. s:gsub("'", "''") .. "'"
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
  local sh_hook = sh_hook_script()
  local ps_hook = ps_hook_script()
  -- Verify (and, on Unix, chmod) only the OS-native shim — matches the
  -- claudecode/codex installers. The config references both shims so it works
  -- across OSes, but the non-native one is never executed here and always ships
  -- with the plugin, so we don't fail the install on its account.
  if not ensure_executable(bin_dir() .. "/hook-entry" .. platform.script_ext()) then return end

  vim.fn.mkdir(hooks_dir(), "p")

  -- Each entry carries both fields so the hook fires on every OS: Copilot runs
  -- `bash` on macOS/Linux and `powershell` (under pwsh 7+) on Windows.
  local function entry(event)
    return {
      type       = "command",
      bash       = shquote(sh_hook) .. " copilot " .. event,
      powershell = "& " .. psquote(ps_hook) .. " copilot " .. event,
      timeoutSec = 30,
    }
  end

  local data = {
    version = 1,
    hooks = {
      preToolUse  = { entry("pre") },
      postToolUse = { entry("post") },
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
