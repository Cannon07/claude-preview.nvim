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

  -- Windows: Claude Code routes shell file ops through a distinct `PowerShell`
  -- tool (Haiku deletes via Remove-Item). It carries the same {command} shape as
  -- Bash and is a shell proposal, so the normaliser folds it onto canonical Bash.
  it("folds the PowerShell tool onto canonical Bash", function()
    local raw = {
      tool_name  = "PowerShell",
      cwd        = "/proj",
      tool_input = { command = 'Remove-Item -Path "foo.txt" -Force' },
    }
    local out = normalisers.normalise(raw, "claudecode")
    assert.equals("Bash", out.tool_name)
    assert.equals('Remove-Item -Path "foo.txt" -Force', out.tool_input.command)
    assert.equals("/proj", out.cwd)
  end)

  it("does not mutate the input payload when folding PowerShell", function()
    local raw = { tool_name = "PowerShell", cwd = "/proj", tool_input = { command = "ls" } }
    normalisers.normalise(raw, "claudecode")
    assert.equals("PowerShell", raw.tool_name)
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

describe("normalisers.normalise (copilot)", function()
  -- Copilot's hook payload is {toolName, cwd, toolArgs} where toolArgs is a
  -- JSON-encoded string for preToolUse (an object for postToolUse). For
  -- apply_patch the string is the raw patch text — not JSON.

  local function copilot_pre(tool_name, args_obj)
    return {
      toolName = tool_name,
      cwd      = "/proj",
      toolArgs = vim.json.encode(args_obj),
    }
  end

  it("edit maps to canonical Edit with resolved absolute path", function()
    local out = normalisers.normalise(
      copilot_pre("edit", { path = "src/foo.lua", old_str = "a", new_str = "b" }), "copilot")
    assert.are.same({
      tool_name = "Edit",
      cwd       = "/proj",
      tool_input = {
        file_path   = "/proj/src/foo.lua",
        old_string  = "a",
        new_string  = "b",
        replace_all = false,
      },
    }, out)
  end)

  it("str_replace aliases to Edit", function()
    local out = normalisers.normalise(
      copilot_pre("str_replace", { path = "/abs/x", old_str = "x", new_str = "y" }), "copilot")
    assert.equals("Edit",   out.tool_name)
    assert.equals("/abs/x", out.tool_input.file_path)
    assert.equals("x",      out.tool_input.old_string)
    assert.equals("y",      out.tool_input.new_string)
  end)

  it("create maps to Write with file_text → content", function()
    local out = normalisers.normalise(
      copilot_pre("create", { path = "/proj/new.lua", file_text = "hello" }), "copilot")
    assert.equals("Write",         out.tool_name)
    assert.equals("/proj/new.lua", out.tool_input.file_path)
    assert.equals("hello",         out.tool_input.content)
  end)

  it("write maps to Write and accepts content as fallback", function()
    local out = normalisers.normalise(
      copilot_pre("write", { path = "/proj/w.lua", content = "body" }), "copilot")
    assert.equals("Write", out.tool_name)
    assert.equals("body",  out.tool_input.content)
  end)

  it("bash maps to Bash with command", function()
    local out = normalisers.normalise(
      copilot_pre("bash", { command = "ls", description = "list" }), "copilot")
    assert.equals("Bash", out.tool_name)
    assert.equals("ls",   out.tool_input.command)
  end)

  -- Regression (issue #46): on Windows Copilot's shell tool is `powershell`,
  -- not `bash` (observed with Gemini-class models). Same {command, description}
  -- shape; must alias to Bash so shell_detect runs and marks neo-tree. Without
  -- it, Remove-Item deletes arrive as tool_name=nil and are silently dropped.
  it("powershell (Windows shell tool) maps to Bash with command", function()
    local cmd = 'Remove-Item -Path "D:\\a\\x.txt", "D:\\b\\y.txt" -ErrorAction Stop'
    local out = normalisers.normalise(
      copilot_pre("powershell", { command = cmd, description = "delete temp files" }), "copilot")
    assert.equals("Bash", out.tool_name)
    assert.equals(cmd,    out.tool_input.command)
  end)

  it("apply_patch treats toolArgs string as raw patch text (not JSON)", function()
    local out = normalisers.normalise({
      toolName = "apply_patch",
      cwd      = "/proj",
      toolArgs = "*** Begin Patch\n*** End Patch\n",
    }, "copilot")
    assert.equals("ApplyPatch", out.tool_name)
    assert.equals("*** Begin Patch\n*** End Patch\n", out.tool_input.patch_text)
  end)

  it("apply_patch with object toolArgs (postToolUse shape) stringifies it", function()
    -- Mirrors the bash adapter's `if type==string then . else tojson end`.
    local out = normalisers.normalise({
      toolName = "apply_patch",
      cwd      = "/proj",
      toolArgs = { some = "object" },
    }, "copilot")
    assert.equals("ApplyPatch", out.tool_name)
    assert.is_string(out.tool_input.patch_text)
  end)

  it("resolves relative path against cwd", function()
    local out = normalisers.normalise(
      copilot_pre("edit", { path = "src/rel.lua", old_str = "a", new_str = "b" }), "copilot")
    assert.equals("/proj/src/rel.lua", out.tool_input.file_path)
  end)

  -- Regression (issue #46): Gemini-class models route edits through Copilot's
  -- `edit`/`create` tools with an ABSOLUTE Windows path. resolve_path must treat
  -- a drive-letter / UNC path as already-absolute; otherwise it is joined onto
  -- cwd (`D:/proj/D:/proj/file`), which fs_stats as missing → the file is
  -- mis-marked "created", no diff renders, and a junk neo-tree node is injected.
  it("does not double an absolute Windows drive-letter path", function()
    local raw = copilot_pre("edit", { path = "D:/proj/sub/foo.lua", old_str = "a", new_str = "b" })
    raw.cwd = "D:/proj"
    local out = normalisers.normalise(raw, "copilot")
    assert.equals("Edit",                out.tool_name)
    assert.equals("D:/proj/sub/foo.lua", out.tool_input.file_path)
  end)

  it("does not double an absolute UNC path", function()
    local out = normalisers.normalise(
      copilot_pre("create", { path = "\\\\srv\\share\\new.lua", file_text = "x" }), "copilot")
    assert.equals("Write", out.tool_name)
    -- Key regression assertion: cwd ("/proj") is NOT prepended.
    assert.is_nil(out.tool_input.file_path:find("proj", 1, true))
  end)

  it("noise / unknown tool yields nil tool_name", function()
    local out = normalisers.normalise(
      copilot_pre("view", { path = "/tmp/whatever" }), "copilot")
    assert.is_nil(out.tool_name)
  end)

  it("malformed JSON toolArgs is treated as empty args (no raise)", function()
    -- E2E regression: Copilot must never send an empty-path Edit downstream.
    -- The defensive blank-path branch drops tool_name to nil so the dispatcher
    -- no-ops — matches the old bash shim's `if [[ -z "$FP" ]]; then exit 0`.
    local out = normalisers.normalise({
      toolName = "edit",
      cwd      = "/proj",
      toolArgs = "}{not json",
    }, "copilot")
    assert.is_nil(out.tool_name)
  end)

  it("Edit with explicit empty path drops tool_name (matches old bash guard)", function()
    -- {"toolName":"edit","toolArgs":'{"path":"","old_str":"a","new_str":"b"}'}
    -- The old shim exited 0 on empty $FP. Without this defensive branch the
    -- payload would reach diff.show_diff with file_path="" and open a broken
    -- diff tab. Keep parity by nilling tool_name.
    local out = normalisers.normalise(
      copilot_pre("edit", { path = "", old_str = "a", new_str = "b" }), "copilot")
    assert.is_nil(out.tool_name)
  end)

  it("Write with explicit empty path drops tool_name", function()
    local out = normalisers.normalise(
      copilot_pre("create", { path = "", file_text = "x" }), "copilot")
    assert.is_nil(out.tool_name)
  end)

  it("Bash with empty command drops tool_name", function()
    local out = normalisers.normalise(
      copilot_pre("bash", { command = "", description = "noop" }), "copilot")
    assert.is_nil(out.tool_name)
  end)

  it("apply_patch with empty toolArgs string drops tool_name", function()
    local out = normalisers.normalise({
      toolName = "apply_patch",
      cwd      = "/proj",
      toolArgs = "",
    }, "copilot")
    assert.is_nil(out.tool_name)
  end)

  it("postToolUse object toolArgs is used directly", function()
    local out = normalisers.normalise({
      toolName = "edit",
      cwd      = "/proj",
      toolArgs = { path = "/proj/p.lua", old_str = "a", new_str = "b" },
    }, "copilot")
    assert.equals("Edit",         out.tool_name)
    assert.equals("/proj/p.lua",  out.tool_input.file_path)
  end)
end)

describe("normalisers.normalise (codex)", function()
  -- Codex's hook payload is almost canonical: top-level {tool_name, cwd,
  -- tool_input}. The only real translation is apply_patch → ApplyPatch with
  -- tool_input.command moved to tool_input.patch_text.

  it("apply_patch translates to ApplyPatch with patch_text", function()
    local out = normalisers.normalise({
      tool_name  = "apply_patch",
      cwd        = "/proj",
      tool_input = { command = "*** Begin Patch\n*** End Patch\n" },
    }, "codex")
    assert.equals("ApplyPatch", out.tool_name)
    assert.equals("*** Begin Patch\n*** End Patch\n", out.tool_input.patch_text)
  end)

  it("ApplyPatch passes through unchanged", function()
    local out = normalisers.normalise({
      tool_name  = "ApplyPatch",
      cwd        = "/proj",
      tool_input = { patch_text = "PATCH" },
    }, "codex")
    assert.equals("ApplyPatch", out.tool_name)
    assert.equals("PATCH",      out.tool_input.patch_text)
  end)

  it("Edit passthrough resolves relative file_path", function()
    local out = normalisers.normalise({
      tool_name  = "Edit",
      cwd        = "/proj",
      tool_input = { file_path = "src/foo.lua", old_string = "a", new_string = "b" },
    }, "codex")
    assert.equals("Edit",              out.tool_name)
    assert.equals("/proj/src/foo.lua", out.tool_input.file_path)
    assert.equals("a",                 out.tool_input.old_string)
    assert.equals("b",                 out.tool_input.new_string)
  end)

  it("Edit collapses .. segments via resolve_path", function()
    local out = normalisers.normalise({
      tool_name  = "Edit",
      cwd        = "/proj/sub",
      tool_input = { file_path = "../foo.lua" },
    }, "codex")
    assert.equals("/proj/foo.lua", out.tool_input.file_path)
  end)

  it("Write passthrough preserves content and resolves file_path", function()
    local out = normalisers.normalise({
      tool_name  = "Write",
      cwd        = "/proj",
      tool_input = { file_path = "new.lua", content = "hello" },
    }, "codex")
    assert.equals("Write",         out.tool_name)
    assert.equals("/proj/new.lua", out.tool_input.file_path)
    assert.equals("hello",         out.tool_input.content)
  end)

  it("Bash passthrough preserves command", function()
    local out = normalisers.normalise({
      tool_name  = "Bash",
      cwd        = "/proj",
      tool_input = { command = "ls" },
    }, "codex")
    assert.equals("Bash", out.tool_name)
    assert.equals("ls",   out.tool_input.command)
  end)

  it("apply_patch with empty command drops tool_name", function()
    local out = normalisers.normalise({
      tool_name  = "apply_patch",
      cwd        = "/proj",
      tool_input = { command = "" },
    }, "codex")
    assert.is_nil(out.tool_name)
  end)

  it("Edit with empty file_path drops tool_name", function()
    local out = normalisers.normalise({
      tool_name  = "Edit",
      cwd        = "/proj",
      tool_input = { file_path = "", old_string = "a", new_string = "b" },
    }, "codex")
    assert.is_nil(out.tool_name)
  end)

  it("Write with empty file_path drops tool_name", function()
    local out = normalisers.normalise({
      tool_name  = "Write",
      cwd        = "/proj",
      tool_input = { file_path = "", content = "x" },
    }, "codex")
    assert.is_nil(out.tool_name)
  end)

  it("Bash with empty command drops tool_name", function()
    local out = normalisers.normalise({
      tool_name  = "Bash",
      cwd        = "/proj",
      tool_input = { command = "" },
    }, "codex")
    assert.is_nil(out.tool_name)
  end)

  it("mcp__* tools yield nil tool_name", function()
    -- The shim fast-path filter drops these before RPC, but the Lua map
    -- remains the source of truth for correctness.
    local out = normalisers.normalise({
      tool_name  = "mcp__server__do_thing",
      cwd        = "/proj",
      tool_input = { whatever = true },
    }, "codex")
    assert.is_nil(out.tool_name)
  end)

  it("noise tools (read/view/glob/grep/ls/list_files) yield nil tool_name", function()
    for _, tool in ipairs({ "read", "view", "glob", "grep", "ls", "list_files" }) do
      local out = normalisers.normalise({
        tool_name  = tool,
        cwd        = "/proj",
        tool_input = {},
      }, "codex")
      assert.is_nil(out.tool_name)
    end
  end)
end)
