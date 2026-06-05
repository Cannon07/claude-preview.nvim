-- platform.lua — the single home for the per-OS branch in the integration
-- layer. Before this, script-extension / hook-command / chmod logic was
-- duplicated across every backend installer and health.lua; centralising it
-- keeps the OS fork in one place as more backends go cross-platform.
-- See issue #46 / ADR-0008.

local M = {}

function M.is_windows()
  return vim.fn.has("win32") == 1
end

-- Hook shims are per-OS: a .sh shim on Unix, a .ps1 shim on Windows.
function M.script_ext()
  return M.is_windows() and ".ps1" or ".sh"
end

--- Build the command an agent should invoke for a hook entry.
--- On Windows the .ps1 is run through PowerShell explicitly (the file is not
--- directly executable); on Unix the .sh path runs directly. `args` (a string,
--- e.g. "claudecode pre") is appended so the generic hook-entry shim knows
--- which backend + event it is serving.
--- @param script_path string  absolute path to the hook-entry shim
--- @param args string?        space-separated args appended to the command
--- @return string
function M.hook_command(script_path, args)
  local suffix = (args and args ~= "") and (" " .. args) or ""
  if M.is_windows() then
    return string.format(
      'powershell -NoProfile -ExecutionPolicy Bypass -File "%s"%s',
      script_path, suffix
    )
  end
  return script_path .. suffix
end

--- Make a shim executable. chmod +x on Unix; a no-op on Windows, where there is
--- no executable bit and the interpreter is invoked explicitly.
--- @param path string
function M.make_executable(path)
  if not M.is_windows() then
    vim.fn.system({ "chmod", "+x", path })
  end
end

--- The external dependency each OS's shim relies on, for health reporting:
--- the Unix shims parse JSON with jq; the Windows shims use PowerShell's native
--- ConvertFrom-Json (so jq is irrelevant there).
--- @return string
function M.shim_dependency()
  return M.is_windows() and "powershell" or "jq"
end

return M
