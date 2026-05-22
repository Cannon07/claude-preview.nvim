-- install_state_spec.lua — Contract test for the unified backend
-- install_state() interface (#58).
--
-- Each backend module must expose:
--   install_state() -> { state = "installed"|"missing", warnings = string[]? }
--
-- These tests run against a fresh tmp cwd with no backend artifacts present,
-- so every backend should report `missing`. The point is to lock the return
-- shape across all four backends; end-to-end install/uninstall behaviour is
-- covered by the per-backend shell tests under tests/backends/.

local BACKENDS = { "claudecode", "opencode", "copilot", "codex" }

-- Preload backend modules while the original cwd (which is on rtp via `.`) is
-- still active; cd-ing first would break the require path.
local LOADED = {}
for _, n in ipairs(BACKENDS) do
  LOADED[n] = require("code-preview.backends." .. n)
end

local original_cwd

describe("backends install_state() contract", function()
  before_each(function()
    original_cwd = vim.fn.getcwd()
    local tmp = vim.fn.tempname()
    vim.fn.mkdir(tmp, "p")
    vim.cmd("cd " .. vim.fn.fnameescape(tmp))
  end)

  after_each(function()
    vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))
  end)

  for _, name in ipairs(BACKENDS) do
    it(name .. " reports missing in an empty project", function()
      local mod = LOADED[name]
      assert.is_function(mod.install_state)
      local s = mod.install_state()
      assert.is_table(s)
      assert.equals("missing", s.state)
    end)
  end

  -- The codex degraded path (hooks present but `codex_hooks = true` missing)
  -- is exercised end-to-end by tests/backends/codex/test_install.sh, which
  -- can actually invoke install() against a real filesystem without fighting
  -- the plenary headless cwd handling.
end)
