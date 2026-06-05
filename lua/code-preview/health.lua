local M = {}

function M.check()
  -- vim.health API differs between Neovim 0.9 and 0.10+
  local h = vim.health or require("health")
  local ok    = h.ok    or h.report_ok
  local warn  = h.warn  or h.report_warn
  local error = h.error or h.report_error
  local start = h.start or h.report_start

  -- Hook shims are per-OS: .sh on Unix, .ps1 on Windows (issue #46 / ADR-0007).
  local platform = require("code-preview.platform")
  local is_win   = platform.is_windows()
  local shim_ext = platform.script_ext()

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
  -- jq; the Windows shims (.ps1) use PowerShell's native ConvertFrom-Json. See
  -- issue #46.
  local dep = platform.shim_dependency()
  if vim.fn.executable(dep) == 1 then
    if is_win then
      ok("PowerShell is available (used by the Windows hook shims; built in on Windows 11)")
    else
      ok("jq is available")
    end
  else
    warn(dep .. " not found in PATH (required by the hook scripts)")
  end

  -- Shared shims. The hook entry is one generic per-OS shim (bin/hook-entry,
  -- ADR-0008); the discovery + RPC shims are per-OS too; the apply-* workers
  -- are Lua on every OS.
  local src = debug.getinfo(1, "S").source
  local lua_file = src:sub(2)
  local lua_dir  = vim.fn.fnamemodify(lua_file, ":h")
  local plugin_root = vim.fn.fnamemodify(lua_dir, ":h:h")
  local bin = plugin_root .. "/bin"

  for _, stem in ipairs({ "hook-entry", "nvim-socket", "nvim-call" }) do
    check_script(stem .. shim_ext, bin .. "/" .. stem .. shim_ext)
  end
  for _, script in ipairs({ "apply-edit.lua", "apply-multi-edit.lua" }) do
    check_script(script, bin .. "/" .. script)
  end

  -- .claude/settings.local.json — delegate hook detection to the backend, which
  -- matches by command *shape* (the "hook-entry" marker), not by install path.
  -- (A previous inline re-parse keyed off "code-preview"/"claude-preview"
  -- substrings, which mis-fired after the hook-entry rename — e.g. flagging a
  -- fresh install as "legacy" just because the plugin lived under a
  -- claude-preview.nvim directory.)
  local settings = vim.fn.getcwd() .. "/.claude/settings.local.json"
  if vim.fn.filereadable(settings) == 0 then
    warn(".claude/settings.local.json not found — run :CodePreviewInstallClaudeCodeHooks")
  elseif require("code-preview.backends.claudecode").install_state().state == "installed" then
    ok("Claude Code hooks are installed")
  else
    warn("code-preview hooks not installed in .claude/settings.local.json — run :CodePreviewInstallClaudeCodeHooks")
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

  -- Copilot uses the shared bin/hook-entry.sh (checked above) through its `bash`
  -- hook field. On Windows that field needs git-bash, so Copilot-on-Windows is
  -- deferred (issue #46).
  if is_win then
    warn("Copilot CLI on Windows is not yet supported (issue #46); use Claude Code on Windows")
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

  -- Codex now uses the shared bin/hook-entry shim (checked above); no
  -- per-backend adapter script remains. Codex-on-Windows is wired but not yet
  -- validated end-to-end (issue #46).
  if is_win then
    warn("Codex CLI on Windows is not yet validated (issue #46); use Claude Code on Windows")
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
