local M = {}

function M.check()
  -- vim.health API differs between Neovim 0.9 and 0.10+
  local h = vim.health or require("health")
  local ok    = h.ok    or h.report_ok
  local warn  = h.warn  or h.report_warn
  local error = h.error or h.report_error
  local start = h.start or h.report_start

  -- Hook shims are per-OS: .sh on Unix, .ps1 on Windows (issue #46 / ADR-0007).
  local is_win   = vim.fn.has("win32") == 1
  local shim_ext = is_win and ".ps1" or ".sh"

  -- Report a shim/script artifact. On Windows there is no executable bit (the
  -- hook command invokes the interpreter explicitly), so readability is the
  -- correct check; on Unix we additionally require the executable bit.
  local function check_script(label, path)
    if vim.fn.filereadable(path) == 0 then
      error(label .. " not found at " .. path)
    elseif is_win or vim.fn.executable(path) == 1 then
      ok(label .. (is_win and " is present" or " is executable"))
    else
      warn(label .. " exists but is not executable (run: chmod +x " .. path .. ")")
    end
  end

  -- ── Common ────────────────────────────────────────────────────

  start("code-preview.nvim")

  -- Neovim RPC socket (required for both backends)
  local socket = vim.v.servername or ""
  if socket ~= "" then
    ok("Neovim RPC socket: " .. socket)
  else
    warn("Neovim RPC socket not found (start Neovim with --listen or set NVIM_LISTEN_ADDRESS)")
  end

  -- Diff layout
  local cfg = require("code-preview").config or {}
  local layout = (cfg.diff and cfg.diff.layout) or "unknown"
  ok("Diff layout: " .. layout)

  -- Pidfile registration — used by hook scripts to find this nvim's socket
  -- without OS-specific socket-glob discovery.
  local pidfile = require("code-preview.pidfile").path()
  local pf = io.open(pidfile, "r")
  if not pf then
    warn("Pidfile not found at " .. pidfile .. " (hook scripts will fall back to socket discovery)")
  else
    local pf_socket = pf:read("*l") or ""
    local pf_cwd = pf:read("*l") or ""
    pf:close()
    if pf_socket == "" or pf_cwd == "" then
      warn("Pidfile " .. pidfile .. " is malformed (expected socket+cwd on two lines)")
    else
      ok("Pidfile registered: " .. pidfile)
    end
  end

  -- RPC dispatcher (loaded by every hook RPC; readability check only since
  -- it's a Lua module on the rtp, not a standalone script).
  if pcall(require, "code-preview.rpc") then
    ok("code-preview.rpc dispatcher loadable")
  else
    error("code-preview.rpc dispatcher failed to load — hook RPC will not work")
  end

  -- ── Claude Code backend ───────────────────────────────────────

  start("Claude Code backend")

  -- Hook-shim dependency, reported per-OS. The Unix shims (.sh) parse JSON with
  -- jq; the Windows shims (.ps1) use PowerShell's native ConvertFrom-Json, so jq
  -- is irrelevant there. See issue #46.
  if vim.fn.has("win32") == 1 then
    if vim.fn.executable("powershell") == 1 then
      ok("PowerShell is available (used by the Windows hook shims; built in on Windows 11)")
    else
      warn("powershell not found in PATH (required by the Windows hook scripts)")
    end
  elseif vim.fn.executable("jq") == 1 then
    ok("jq is available")
  else
    warn("jq not found in PATH (required by the Unix hook scripts)")
  end

  -- Hook scripts executable
  local src = debug.getinfo(1, "S").source
  local lua_file = src:sub(2)
  local lua_dir  = vim.fn.fnamemodify(lua_file, ":h")
  local plugin_root = vim.fn.fnamemodify(lua_dir, ":h:h")
  local bin = plugin_root .. "/bin"
  local claudecode_dir = plugin_root .. "/backends/claudecode"

  -- Claude Code adapter scripts (per-OS shim extension)
  for _, stem in ipairs({ "code-preview-diff", "code-close-diff" }) do
    check_script(stem .. shim_ext, claudecode_dir .. "/" .. stem .. shim_ext)
  end

  -- Shared scripts: the discovery + RPC shims are per-OS; the apply-* workers
  -- are Lua on every OS.
  for _, stem in ipairs({ "nvim-socket", "nvim-call" }) do
    check_script(stem .. shim_ext, bin .. "/" .. stem .. shim_ext)
  end
  for _, script in ipairs({ "apply-edit.lua", "apply-multi-edit.lua" }) do
    check_script(script, bin .. "/" .. script)
  end

  -- .claude/settings.local.json
  local settings = vim.fn.getcwd() .. "/.claude/settings.local.json"
  local f = io.open(settings, "r")
  if not f then
    warn(".claude/settings.local.json not found — run :CodePreviewInstallClaudeCodeHooks")
  else
    local raw = f:read("*a")
    f:close()
    local parsed_ok, data = pcall(vim.json.decode, raw)
    if not parsed_ok then
      error(".claude/settings.local.json is invalid JSON")
    elseif not (data.hooks and data.hooks.PreToolUse) then
      warn(".claude/settings.local.json exists but code-preview hooks are not installed")
    else
      local found_new = false
      local found_legacy = false
      for _, entry in ipairs(data.hooks.PreToolUse) do
        local cmd = ""
        if entry.hooks and entry.hooks[1] then
          cmd = tostring(entry.hooks[1].command or "")
        end
        if cmd:find("code-preview", 1, true) then
          found_new = true
          break
        elseif cmd:find("claude-preview", 1, true) then
          found_legacy = true
        end
      end
      if found_new then
        ok("Claude Code hooks are installed")
      elseif found_legacy then
        warn("Legacy claude-preview hooks detected — run :CodePreviewInstallClaudeCodeHooks to update")
      else
        warn("code-preview hooks not found — run :CodePreviewInstallClaudeCodeHooks")
      end
    end
  end

  -- ── OpenCode backend ──────────────────────────────────────────

  start("OpenCode backend")

  -- OpenCode CLI
  if vim.fn.executable("opencode") == 1 then
    ok("opencode is available in PATH")
  else
    warn("opencode not found in PATH (install from https://opencode.ai)")
  end

  -- OpenCode plugin installed
  local opencode_plugin = vim.fn.getcwd() .. "/.opencode/plugins/index.ts"
  if vim.fn.filereadable(opencode_plugin) == 1 then
    ok("OpenCode plugin is installed (.opencode/plugins/)")
  else
    warn("OpenCode plugin not installed — run :CodePreviewInstallOpenCodeHooks")
  end

  -- ── Copilot CLI backend ───────────────────────────────────────

  start("GitHub Copilot CLI backend")

  -- copilot binary
  if vim.fn.executable("copilot") == 1 then
    ok("copilot CLI is available in PATH")
  else
    warn("copilot not found in PATH (install from https://github.com/github/copilot-cli)")
  end

  -- Adapter scripts (Unix only — Copilot's Windows shim is pending, issue #46)
  local copilot_dir = plugin_root .. "/backends/copilot"
  if is_win then
    warn("Copilot CLI on Windows is not yet supported (issue #46); use Claude Code on Windows")
  else
    for _, stem in ipairs({ "code-preview-diff", "code-close-diff" }) do
      check_script(stem .. ".sh", copilot_dir .. "/" .. stem .. ".sh")
    end
  end

  -- hooks.json installed
  local copilot_hooks = vim.fn.getcwd() .. "/.github/hooks/code-preview.json"
  if vim.fn.filereadable(copilot_hooks) == 1 then
    ok("Copilot CLI hooks are installed (.github/hooks/code-preview.json)")
  else
    warn("Copilot CLI hooks not installed — run :CodePreviewInstallCopilotCliHooks")
  end

  -- ── Codex CLI backend ─────────────────────────────────────────

  start("OpenAI Codex CLI backend")

  if vim.fn.executable("codex") == 1 then
    ok("codex CLI is available in PATH")
  else
    warn("codex not found in PATH (install from https://github.com/openai/codex)")
  end

  local codex_dir = plugin_root .. "/backends/codex"
  if is_win then
    warn("Codex CLI on Windows is not yet supported (issue #46); use Claude Code on Windows")
  else
    for _, stem in ipairs({ "code-preview-diff", "code-close-diff" }) do
      check_script(stem .. ".sh", codex_dir .. "/" .. stem .. ".sh")
    end
  end

  local codex_backend = require("code-preview.backends.codex")
  if codex_backend.is_installed() then
    ok("Codex CLI hooks are installed (.codex/hooks.json)")
    -- Modern Codex enables hooks by default under [features]; the canonical
    -- key is `hooks` (with `codex_hooks` accepted as a deprecated alias).
    -- The only failure mode here is the user having explicitly opted out.
    if codex_backend.feature_flag_state() == "disabled" then
      warn("Codex hooks are explicitly disabled in config.toml (`[features] hooks = false`) — remove it or set `hooks = true`")
    else
      ok("Codex hooks feature is enabled (default; no flag required)")
    end
  else
    warn("Codex CLI hooks not installed — run :CodePreviewInstallCodexCliHooks")
  end
end

return M
