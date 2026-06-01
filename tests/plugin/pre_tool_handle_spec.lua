-- pre_tool_handle_spec.lua — Smoke tests for the in-process orchestrator.
--
-- These exercise the happy paths and pin a few high-value invariants:
--   - Bash proposals mutate the changes registry but never open previews
--   - claudecode backend emits a permissionDecision JSON envelope
--   - other backends emit empty stdout
--   - unknown tool_name is a no-op (no crash)
--
-- Edit / Write / MultiEdit / ApplyPatch side effects bottom out in
-- diff.show_diff, which we don't drive UI for in tests — we only assert that
-- handle() does not raise.

local pre_tool = require("code-preview.pre_tool")
local changes  = require("code-preview.changes")

local function payload(tool_name, tool_input, cwd)
  return { tool_name = tool_name, cwd = cwd or "/proj", tool_input = tool_input }
end

describe("pre_tool.handle (Bash)", function()
  before_each(function() changes.clear_all() end)

  it("rm command marks file as deleted", function()
    local p = "/proj/gone.txt"
    pre_tool.handle(payload("Bash", { command = "rm gone.txt" }), "claudecode")
    assert.equals("deleted", changes.get(p))
  end)

  it("redirect to new file marks bash_created", function()
    local p = "/tmp/code-preview-test-" .. tostring(vim.loop.hrtime()) .. ".out"
    pre_tool.handle(payload("Bash", { command = "echo x > " .. p }), "claudecode")
    assert.equals("bash_created", changes.get(p))
  end)

  it("redirect to existing file marks bash_modified", function()
    -- Skipped on Windows: this case needs to create the file on disk (io.open
    -- of a /tmp path fails on Windows) AND have bash_detect resolve a Windows
    -- path, which is Unix-path-only today (issue #46, handoff item 3). The
    -- bash-on-Windows work will re-enable this. The new-file/rm cases above use
    -- forward-slash paths that don't need an on-disk file, so they still run.
    if vim.fn.has("win32") == 1 then
      return pending("bash_detect is Unix-path-only on Windows (issue #46)")
    end
    local p = "/tmp/code-preview-test-existing-" .. tostring(vim.loop.hrtime())
    local fh = assert(io.open(p, "w")); fh:write("hi"); fh:close()
    pre_tool.handle(payload("Bash", { command = "echo x > " .. p }), "claudecode")
    assert.equals("bash_modified", changes.get(p))
    os.remove(p)
  end)

  it("read-only command leaves registry empty", function()
    pre_tool.handle(payload("Bash", { command = "ls -la" }), "claudecode")
    assert.equals(0, vim.tbl_count(changes.get_all()))
  end)

  it("rm and write in one command both register", function()
    pre_tool.handle(payload("Bash", { command = "rm old.txt && echo x > new.txt" }), "claudecode")
    assert.equals("deleted",      changes.get("/proj/old.txt"))
    assert.equals("bash_created", changes.get("/proj/new.txt"))
  end)
end)

describe("pre_tool.handle (emitter output)", function()
  it("claudecode emits permissionDecision JSON for Edit", function()
    local out = pre_tool.handle(
      payload("Edit", { file_path = "/tmp/x", old_string = "a", new_string = "b" }),
      "claudecode")
    assert.is_truthy(out:match("permissionDecision"))
    assert.is_truthy(out:match("PreToolUse"))
  end)

  it("claudecode emits nothing for Bash", function()
    local out = pre_tool.handle(payload("Bash", { command = "ls" }), "claudecode")
    assert.equals("", out)
  end)

  it("claudecode emits nothing for unknown tool", function()
    local out = pre_tool.handle(payload("Read", { file_path = "/tmp/x" }), "claudecode")
    assert.equals("", out)
  end)

  it("opencode emits empty stdout", function()
    local raw = { tool = "edit", cwd = "/proj", args = { filePath = "/tmp/x" } }
    local out = pre_tool.handle(raw, "opencode")
    assert.equals("", out)
  end)

  it("unknown backend emits empty stdout", function()
    local out = pre_tool.handle(payload("Edit", { file_path = "/tmp/x" }), "future-agent")
    assert.equals("", out)
  end)
end)

describe("pre_tool.handle (robustness)", function()
  before_each(function() changes.clear_all() end)

  it("unknown tool_name does not raise", function()
    assert.has_no.errors(function()
      pre_tool.handle(payload("UnknownTool", {}), "claudecode")
    end)
  end)

  it("missing tool_input does not raise", function()
    assert.has_no.errors(function()
      pre_tool.handle({ tool_name = "Bash", cwd = "/proj" }, "claudecode")
    end)
  end)
end)
