local M = {}

-- Resolve the absolute path to the plugin's bin/ directory.
-- We use debug.getinfo so this works regardless of where the plugin is installed.
-- Resolve plugin root from this file's location
local function plugin_root()
  local src = debug.getinfo(1, "S").source
  -- src is "@/absolute/path/to/lua/code-preview/backends/claudecode.lua"
  local lua_file = src:sub(2)                            -- strip leading "@"
  local lua_dir  = vim.fn.fnamemodify(lua_file, ":h")    -- .../lua/code-preview/backends
  -- Go up three levels: backends/ → code-preview/ → lua/ → plugin root
  return vim.fn.fnamemodify(lua_dir, ":h:h:h")
end

-- Path to shared utilities (bin/)
local function bin_dir()
  return plugin_root() .. "/bin"
end

local platform = require("code-preview.platform")

-- Markers identifying our hook entries. "hook-entry" is the current stem
-- (bin/hook-entry.{sh,ps1}); "code-preview" / "claude-preview" match older
-- installs (the per-backend code-preview-diff shim, and the legacy name) so
-- uninstall still cleans them up after an upgrade.
local HOOK_MARKERS = { "hook-entry", "code-preview", "claude-preview" }

local function is_our_command(cmd)
  cmd = tostring(cmd or "")
  for _, m in ipairs(HOOK_MARKERS) do
    if cmd:find(m, 1, true) then return true end
  end
  return false
end

-- Tools whose proposals we intercept. On Windows, Claude Code exposes a
-- distinct `PowerShell` tool alongside `Bash` and routes shell file ops
-- (Remove-Item / Move-Item / Set-Content …) through it — observed with the
-- Haiku model, which deletes via `Remove-Item`. Without `PowerShell` in the
-- matcher the PreToolUse hook never fires for those proposals, so a shell
-- delete/write never marks neo-tree (issue #46 follow-up). The normaliser
-- folds `PowerShell` into the canonical `Bash` path; here we just make sure
-- the hook fires. Harmless on Unix (no such tool is ever emitted there).
local TOOL_MATCHER = "Edit|Write|MultiEdit|Bash|PowerShell"

local function settings_path()
  return vim.fn.getcwd() .. "/.claude/settings.local.json"
end

local function read_settings(path)
  local f = io.open(path, "r")
  if not f then return {} end
  local raw = f:read("*a")
  f:close()
  if raw == "" then return {} end
  local ok, data = pcall(vim.json.decode, raw)
  return ok and data or {}
end

local function write_settings(path, data)
  -- Ensure parent directory exists
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = assert(io.open(path, "w"), "Cannot write to " .. path)
  f:write(vim.json.encode(data))
  f:close()
end

-- Remove entries matching either the current or legacy hook marker.
-- This lets users who installed with the old name uninstall after upgrading.
local function remove_ours(list)
  local filtered = {}
  for _, entry in ipairs(list) do
    local cmd = ""
    if entry.hooks and entry.hooks[1] then
      cmd = tostring(entry.hooks[1].command or "")
    end
    if not is_our_command(cmd) then
      table.insert(filtered, entry)
    end
  end
  return filtered
end

function M.install()
  -- One generic shim per OS, parameterized by backend + event (ADR-0008).
  local hook = bin_dir() .. "/hook-entry" .. platform.script_ext()

  if vim.fn.filereadable(hook) == 0 then
    vim.notify("[code-preview] hook script not found: " .. hook, vim.log.levels.ERROR)
    return
  end

  local path = settings_path()
  local data = read_settings(path)

  -- Initialise missing structure
  data.hooks = data.hooks or {}
  data.hooks.PreToolUse  = data.hooks.PreToolUse  or {}
  data.hooks.PostToolUse = data.hooks.PostToolUse or {}

  data.hooks.PreToolUse  = remove_ours(data.hooks.PreToolUse)
  data.hooks.PostToolUse = remove_ours(data.hooks.PostToolUse)

  -- The command invokes the shim with the backend + event; on Windows
  -- platform.hook_command wraps it in `powershell -File …`. See ADR-0007/0008.
  table.insert(data.hooks.PreToolUse, {
    matcher = TOOL_MATCHER,
    hooks   = { { type = "command", command = platform.hook_command(hook, "claudecode pre") } },
  })
  table.insert(data.hooks.PostToolUse, {
    matcher = TOOL_MATCHER,
    hooks   = { { type = "command", command = platform.hook_command(hook, "claudecode post") } },
  })

  write_settings(path, data)
  vim.notify("[code-preview] Hooks installed → " .. path, vim.log.levels.INFO)
end

--- Report whether the Claude Code hooks are wired up in this project.
--- @return { state: "installed"|"missing", warnings: string[]? }
function M.install_state()
  local path = settings_path()
  local f = io.open(path, "r")
  if not f then return { state = "missing" } end
  local content = f:read("*a") or ""
  f:close()
  if is_our_command(content) then return { state = "installed" } end
  return { state = "missing" }
end

function M.uninstall()
  local path = settings_path()
  local data = read_settings(path)

  if not data.hooks then
    vim.notify("[code-preview] No hooks found in " .. path, vim.log.levels.WARN)
    return
  end

  data.hooks.PreToolUse  = remove_ours(data.hooks.PreToolUse or {})
  data.hooks.PostToolUse = remove_ours(data.hooks.PostToolUse or {})

  write_settings(path, data)
  vim.notify("[code-preview] Hooks removed from " .. path, vim.log.levels.INFO)
end

return M
