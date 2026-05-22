local M = {}

-- Module-level config, populated by setup()
M.config = {}

local default_config = {
  debug = false,  -- enable debug logging to stdpath("log")/code-preview.log
  diff = {
    layout = "tab",        -- "tab", "vsplit", or "inline"
    labels = { current = "CURRENT", proposed = "PROPOSED" },
    equalize = true,
    full_file = true,
    visible_only = false,  -- only show diffs for files open in a visible nvim window
    defer_claude_permissions = false,  -- when true, skip permissionDecision and let Claude Code's own settings decide
  },
  neo_tree = {
    enabled = true,
    -- reveal = false disables scroll-to-file in the tree. Change indicators
    -- (modified/created/deleted icons) still appear — to disable those too,
    -- set neo_tree.enabled = false.
    reveal = true,         -- reveal edited files in neo-tree
    reveal_root = "cwd",   -- "cwd" (default) or "git" (nearest git root)
    refresh_on_change = true,
    position = "right",
    symbols = {
      modified = "󰏫",
      created  = "󰎔",
      deleted  = "󰆴",
    },
    highlights = {
      modified = { fg = "#e8a838", bold = true },
      created  = { fg = "#56c8d8", bold = true },
      deleted  = { fg = "#e06c75", bold = true, strikethrough = true },
    },
  },
  keys = {
    -- Set any entry to false to skip that binding. Set `keys = false` to skip all.
    -- <Plug>(CodePreviewCloseAll) is always defined so users can map it themselves.
    next_change = "]c",        -- buffer-local in inline diff buffers
    prev_change = "[c",        -- buffer-local in inline diff buffers
    close_all   = "<leader>dq", -- global; close diff and clear indicators
  },
  highlights = {
    current = {
      DiffAdd    = { bg = "#4c2e2e" },
      DiffDelete = { bg = "#4c2e2e" },
      DiffChange = { bg = "#4c3a2e" },
      DiffText   = { bg = "#5c3030" },
    },
    proposed = {
      DiffAdd    = { bg = "#2e4c2e" },
      DiffDelete = { bg = "#4c2e2e" },
      DiffChange = { bg = "#2e3c4c" },
      DiffText   = { bg = "#3e5c3e" },
    },
    inline = {
      added        = { bg = "#2e4c2e" },
      removed      = { bg = "#4c2e2e" },
      added_text   = { bg = "#3a6e3a" },
      removed_text = { bg = "#6e3a3a" },
    },
  },
}

local function deep_merge(base, override)
  local result = vim.deepcopy(base)
  for k, v in pairs(override) do
    if type(v) == "table" and type(result[k]) == "table" then
      result[k] = deep_merge(result[k], v)
    else
      result[k] = v
    end
  end
  return result
end

function M.setup(user_config)
  M.config = deep_merge(default_config, user_config or {})

  -- Initialise logging
  require("code-preview.log").init({ debug = M.config.debug })

  -- Self-register socket + cwd for hook-script discovery
  require("code-preview.pidfile").setup()

  -- Clear any leftover /tmp/code-preview-diff-* tempfiles from prior sessions
  -- (also matches the legacy /tmp/claude-diff-* prefix transitionally — see
  -- pre_tool.sweep_leftover_tempfiles).
  require("code-preview.pre_tool").sweep_leftover_tempfiles()

  -- ── New commands ──────────────────────────────────────────────

  vim.api.nvim_create_user_command("CodePreviewInstallClaudeCodeHooks", function()
    require("code-preview.backends.claudecode").install()
  end, { desc = "Install code-preview PreToolUse/PostToolUse hooks for Claude Code" })

  vim.api.nvim_create_user_command("CodePreviewUninstallClaudeCodeHooks", function()
    require("code-preview.backends.claudecode").uninstall()
  end, { desc = "Uninstall code-preview hooks for Claude Code" })

  vim.api.nvim_create_user_command("CodePreviewInstallOpenCodeHooks", function()
    require("code-preview.backends.opencode").install()
  end, { desc = "Install code-preview plugin for OpenCode" })

  vim.api.nvim_create_user_command("CodePreviewUninstallOpenCodeHooks", function()
    require("code-preview.backends.opencode").uninstall()
  end, { desc = "Uninstall code-preview plugin from OpenCode" })

  vim.api.nvim_create_user_command("CodePreviewInstallCopilotCliHooks", function()
    require("code-preview.backends.copilot").install()
  end, { desc = "Install code-preview hooks for GitHub Copilot CLI" })

  vim.api.nvim_create_user_command("CodePreviewUninstallCopilotCliHooks", function()
    require("code-preview.backends.copilot").uninstall()
  end, { desc = "Uninstall code-preview hooks for GitHub Copilot CLI" })

  vim.api.nvim_create_user_command("CodePreviewInstallCodexCliHooks", function()
    require("code-preview.backends.codex").install()
  end, { desc = "Install code-preview hooks for OpenAI Codex CLI" })

  vim.api.nvim_create_user_command("CodePreviewUninstallCodexCliHooks", function()
    require("code-preview.backends.codex").uninstall()
  end, { desc = "Uninstall code-preview hooks for OpenAI Codex CLI" })

  vim.api.nvim_create_user_command("CodePreviewCloseDiff", function()
    require("code-preview.diff").close_diff_and_clear()
  end, { desc = "Manually close code-preview diff (use after rejecting a change)" })

  vim.api.nvim_create_user_command("CodePreviewStatus", function()
    M.status()
  end, { desc = "Show code-preview status" })

  vim.api.nvim_create_user_command("CodePreviewToggleVisibleOnly", function()
    M.config.diff.visible_only = not M.config.diff.visible_only
    vim.notify(
      "code-preview: visible_only = " .. tostring(M.config.diff.visible_only),
      vim.log.levels.INFO,
      { title = "code-preview" }
    )
  end, { desc = "Toggle visible_only — show diffs only for open buffers vs all files" })

  -- Neo-tree integration (soft dependency)
  if M.config.neo_tree.enabled then
    require("code-preview.neo_tree").setup(M.config)
  end

  -- <Plug> mapping is always defined so users can bind it themselves
  -- regardless of the `keys` config (e.g. `keys = false` to disable defaults).
  vim.keymap.set("n", "<Plug>(CodePreviewCloseAll)", function()
    require("code-preview.diff").close_diff_and_clear()
  end, { desc = "Close code-preview diff" })

  if M.config.keys ~= false then
    local close_all = M.config.keys and M.config.keys.close_all
    if close_all then
      vim.keymap.set("n", close_all, "<Plug>(CodePreviewCloseAll)",
        { desc = "Close code-preview diff" })
    end
  end
end

--- Query hook context for the PreToolUse shell script.
--- Returns a JSON string with config + file visibility in a single RPC call.
--- @param file_path string absolute path of the file being edited
--- @return string JSON: { neo_tree_reveal, reveal_root, visible_only, file_visible }
function M.hook_context(file_path)
  local cfg = M.config
  local neo_tree_reveal = (cfg.neo_tree.enabled and cfg.neo_tree.reveal) and true or false
  local reveal_root = cfg.neo_tree.reveal_root or "cwd"
  local visible_only = cfg.diff.visible_only and true or false
  local defer_claude_permissions = cfg.diff.defer_claude_permissions and true or false

  local file_visible = false
  if visible_only and file_path ~= "" then
    -- fs_realpath returns the filesystem's canonical form, so case-insensitive
    -- volumes (e.g. default APFS) normalize automatically without per-OS logic.
    local target = vim.uv.fs_realpath(file_path) or vim.fn.fnamemodify(file_path, ":p")
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local b = vim.api.nvim_win_get_buf(w)
      local raw = vim.api.nvim_buf_get_name(b)
      if raw ~= "" then
        local name = vim.uv.fs_realpath(raw) or vim.fn.fnamemodify(raw, ":p")
        if name == target then
          file_visible = true
          break
        end
      end
    end
  end

  local log = require("code-preview.log")

  return vim.json.encode({
    neo_tree_reveal = neo_tree_reveal,
    reveal_root = reveal_root,
    visible_only = visible_only,
    file_visible = file_visible,
    defer_claude_permissions = defer_claude_permissions,
    debug = log.is_enabled(),
    log_file = log.get_log_path() or "",
  })
end

function M.status()
  local lines = { "code-preview.nvim status", string.rep("─", 40) }

  -- Socket
  local socket = vim.env.NVIM_LISTEN_ADDRESS or ""
  if socket == "" then
    socket = vim.v.servername or ""
  end
  if socket ~= "" then
    table.insert(lines, "Neovim socket : " .. socket)
  else
    table.insert(lines, "Neovim socket : not found")
  end

  -- Pidfile (used by hook scripts for socket discovery)
  local pidfile = require("code-preview.pidfile").path()
  if vim.fn.filereadable(pidfile) == 1 then
    table.insert(lines, "Pidfile       : " .. pidfile)
  else
    table.insert(lines, "Pidfile       : not registered")
  end

  -- jq dependency
  local jq_ok = vim.fn.executable("jq") == 1
  table.insert(lines, "jq            : " .. (jq_ok and "found" or "MISSING"))

  -- Diff tab open?
  local diff = require("code-preview.diff")
  table.insert(lines, "Diff tab      : " .. (diff.is_open() and "open" or "closed"))

  -- Backends — each module exposes install_state() returning
  -- { state = "installed"|"missing", warnings = {...}? }. Rendering lives
  -- here; per-backend detection logic lives in the backend module.
  table.insert(lines, "")
  table.insert(lines, "Backends:")

  local BACKENDS = {
    { name = "claudecode", label = "Claude Code", install_cmd = ":CodePreviewInstallClaudeCodeHooks" },
    { name = "opencode",   label = "OpenCode   ", install_cmd = ":CodePreviewInstallOpenCodeHooks"   },
    { name = "copilot",    label = "Copilot CLI", install_cmd = ":CodePreviewInstallCopilotCliHooks" },
    { name = "codex",      label = "Codex CLI  ", install_cmd = ":CodePreviewInstallCodexCliHooks"   },
  }

  for _, b in ipairs(BACKENDS) do
    local s = require("code-preview.backends." .. b.name).install_state()
    if s.state == "installed" then
      if s.warnings and #s.warnings > 0 then
        table.insert(lines, "  " .. b.label .. " : installed BUT " .. table.concat(s.warnings, "; "))
      else
        table.insert(lines, "  " .. b.label .. " : installed")
      end
    else
      table.insert(lines, "  " .. b.label .. " : not installed  ->  " .. b.install_cmd)
    end
  end

  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "code-preview" })
end

return M
