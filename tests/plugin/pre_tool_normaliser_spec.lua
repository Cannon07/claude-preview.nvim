-- pre_tool_normaliser_spec.lua — Per-backend hook payload normalisation.
--
-- Claude Code's hook format is already canonical, so its normaliser is
-- identity. OpenCode fires hooks with lowercase tool names and camelCase
-- argument keys, so its normaliser maps both into the canonical shape.

local normalisers = require("code-preview.pre_tool.normalisers")

describe("normalisers.normalise (claudecode)", function()
  local canonical = {
    tool_name = "Edit",
    cwd       = "/proj",
    tool_input = { file_path = "/proj/foo.lua", old_string = "a", new_string = "b" },
  }

  it("claudecode is identity", function()
    assert.are.same(canonical, normalisers.normalise(canonical, "claudecode"))
  end)

  it("unknown backend falls back to identity", function()
    assert.are.same(canonical, normalisers.normalise(canonical, "future-agent"))
  end)
end)

describe("normalisers.normalise (opencode)", function()
  it("maps tool name and Edit fields, resolves relative path", function()
    local raw = {
      tool = "edit",
      cwd  = "/proj",
      args = { filePath = "foo.lua", oldString = "a", newString = "b", replaceAll = true },
    }
    assert.are.same({
      tool_name = "Edit",
      cwd       = "/proj",
      tool_input = {
        file_path   = "/proj/foo.lua",
        old_string  = "a",
        new_string  = "b",
        replace_all = true,
      },
    }, normalisers.normalise(raw, "opencode"))
  end)

  it("preserves absolute filePath", function()
    local raw = { tool = "write", cwd = "/proj", args = { filePath = "/abs/x", content = "x" } }
    local out = normalisers.normalise(raw, "opencode")
    assert.equals("/abs/x", out.tool_input.file_path)
    assert.equals("Write",  out.tool_name)
    assert.equals("x",      out.tool_input.content)
  end)

  it("collapses .. segments to canonical path", function()
    -- Matches the old TS plugin's path.resolve semantics so internal keys
    -- compare equal across backends.
    local raw = { tool = "edit", cwd = "/proj/sub", args = { filePath = "../foo.lua" } }
    local out = normalisers.normalise(raw, "opencode")
    assert.equals("/proj/foo.lua", out.tool_input.file_path)
  end)

  it("maps MultiEdit edits array", function()
    local raw = {
      tool = "multiedit",
      cwd  = "/proj",
      args = {
        filePath = "/proj/f",
        edits = {
          { oldString = "a", newString = "A" },
          { oldString = "b", newString = "B" },
        },
      },
    }
    local out = normalisers.normalise(raw, "opencode")
    assert.equals("MultiEdit", out.tool_name)
    assert.are.same({
      { old_string = "a", new_string = "A" },
      { old_string = "b", new_string = "B" },
    }, out.tool_input.edits)
  end)

  it("maps Bash command", function()
    local raw = { tool = "bash", cwd = "/proj", args = { command = "ls" } }
    local out = normalisers.normalise(raw, "opencode")
    assert.equals("Bash", out.tool_name)
    assert.equals("ls",   out.tool_input.command)
  end)

  it("accepts both patch and patchText for ApplyPatch", function()
    local a = normalisers.normalise(
      { tool = "apply_patch", cwd = "/proj", args = { patch = "PATCH_A" } }, "opencode")
    local b = normalisers.normalise(
      { tool = "apply_patch", cwd = "/proj", args = { patchText = "PATCH_B" } }, "opencode")
    assert.equals("ApplyPatch", a.tool_name)
    assert.equals("PATCH_A",    a.tool_input.patch_text)
    assert.equals("PATCH_B",    b.tool_input.patch_text)
  end)

  it("unknown tool yields nil tool_name (dispatched as no-op upstream)", function()
    local out = normalisers.normalise(
      { tool = "read", cwd = "/proj", args = { filePath = "/proj/x" } }, "opencode")
    assert.is_nil(out.tool_name)
  end)
end)
