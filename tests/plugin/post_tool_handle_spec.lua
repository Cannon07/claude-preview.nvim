-- post_tool_handle_spec.lua — Smoke tests for the in-process post-tool.
--
-- post_tool.handle's contract:
--   * Bash: clears the markers for the files THIS command touched (re-detected
--     from the post payload), never every bash-owned marker — so concurrent
--     pending Bash commands keep their markers (issue #83), and `modified` /
--     `created` markers from concurrent Edit/Write/ApplyPatch are untouched.
--   * ApplyPatch: closes one preview per file referenced in the patch text.
--   * Other tools: closes the single preview keyed by file_path.
--   * Always returns "" (no backend reads post-tool stdout).
--   * Robust against malformed inputs (no raise).

local post_tool = require("code-preview.post_tool")
local changes   = require("code-preview.changes")

local function payload(tool_name, tool_input, cwd)
  return { tool_name = tool_name, cwd = cwd or "/proj", tool_input = tool_input }
end

describe("post_tool.handle (Bash status clear)", function()
  before_each(function() changes.clear_all() end)

  it("clears deleted markers", function()
    changes.set("/proj/gone.txt", "deleted")
    post_tool.handle(payload("Bash", { command = "rm gone.txt" }), "claudecode")
    assert.is_nil(changes.get("/proj/gone.txt"))
  end)

  it("clears the bash_modified / bash_created markers for files it touched", function()
    changes.set("/proj/a.txt", "bash_modified")
    changes.set("/proj/b.txt", "bash_created")
    post_tool.handle(payload("Bash", { command = "echo x > a.txt; echo y > b.txt" }), "claudecode")
    assert.is_nil(changes.get("/proj/a.txt"))
    assert.is_nil(changes.get("/proj/b.txt"))
  end)

  it("preserves modified / created markers from concurrent edits", function()
    -- An Edit proposal whose post-hook hasn't fired yet must survive a
    -- concurrent Bash post-hook clearing its own origin-prefixed markers.
    changes.set("/proj/edit.lua", "modified")
    changes.set("/proj/new.lua",  "created")
    changes.set("/proj/gone.txt", "deleted")
    post_tool.handle(payload("Bash", { command = "rm gone.txt" }), "claudecode")
    assert.equals("modified", changes.get("/proj/edit.lua"))
    assert.equals("created",  changes.get("/proj/new.lua"))
    assert.is_nil(changes.get("/proj/gone.txt"))
  end)

  it("accepting one Bash delete keeps other pending Bash deletes marked", function()
    -- Regression for #83: two separate Bash deletes are pending, each with its
    -- own `deleted` marker. Accepting the first command (its PostToolUse fires)
    -- must clear ONLY that command's file; the still-pending command's marker
    -- survives. The old global status sweep wiped both.
    changes.set("/proj/a.txt", "deleted")
    changes.set("/proj/b.txt", "deleted")
    post_tool.handle(payload("Bash", { command = "rm a.txt" }), "claudecode")
    assert.is_nil(changes.get("/proj/a.txt"))
    assert.equals("deleted", changes.get("/proj/b.txt"))
  end)

  it("scoped clear covers bash writes, not just deletes", function()
    -- A pending shell write (`echo x > b.txt` → bash_created/modified) must
    -- survive accepting a different command's write.
    changes.set("/proj/a.txt", "bash_modified")
    changes.set("/proj/b.txt", "bash_created")
    post_tool.handle(payload("Bash", { command = "echo x > a.txt" }), "claudecode")
    assert.is_nil(changes.get("/proj/a.txt"))
    assert.equals("bash_created", changes.get("/proj/b.txt"))
  end)
end)

describe("post_tool.handle (return value)", function()
  it("always returns empty string", function()
    assert.equals("", post_tool.handle(payload("Bash",       { command = "ls" }), "claudecode"))
    assert.equals("", post_tool.handle(payload("Edit",       { file_path = "/proj/x" }), "claudecode"))
    assert.equals("", post_tool.handle(payload("ApplyPatch", { patch_text = "" }), "claudecode"))
    assert.equals("", post_tool.handle(payload("Unknown",    {}), "claudecode"))
  end)
end)

describe("post_tool.handle (ApplyPatch)", function()
  it("custom-patch format (*** Update File:) closes one preview per file", function()
    -- Regression: gsub returns (string, count); without parens around the
    -- gsub call, table.insert falls into its 3-arg (t, pos, value) form and
    -- raises "bad argument #2 to 'insert' (number expected, got string)".
    -- Beyond not crashing, post_tool must call diff.close_for_file once per
    -- patched path with the cwd-resolved absolute path.
    local diff = require("code-preview.diff")
    local closed = {}
    local orig = diff.close_for_file
    diff.close_for_file = function(p) table.insert(closed, p) end

    local patch = table.concat({
      "*** Begin Patch",
      "*** Update File: a.txt",
      "@@",
      "-old",
      "+new",
      "*** Update File: b.txt",
      "@@",
      "-old",
      "+new",
      "*** End Patch",
    }, "\n")
    post_tool.handle(payload("ApplyPatch", { patch_text = patch }), "claudecode")
    diff.close_for_file = orig

    assert.are.same({ "/proj/a.txt", "/proj/b.txt" }, closed)
  end)

  it("does not double cwd onto a Windows-absolute patch path", function()
    -- Regression: post_tool used a private path resolver whose absolute check
    -- was Unix-only, so a Windows-absolute `*** Update File:` path (codex sends
    -- these for some projects) was joined onto cwd and doubled
    -- (D:\proj\D:\proj\sub\README.md). The close path then no longer matched
    -- the open diff, so the marker/diff never cleared after accept. post_tool
    -- now shares apply.patch.resolve_path, so the absolute path passes through.
    -- Cross-platform: the drive-letter check matches on Unix too.
    local diff = require("code-preview.diff")
    local closed = {}
    local orig = diff.close_for_file
    diff.close_for_file = function(p) table.insert(closed, p) end

    local abs = [[D:\proj\sub\README.md]]
    local patch = table.concat({
      "*** Begin Patch",
      "*** Update File: " .. abs,
      "@@",
      "-old",
      "+new",
      "*** End Patch",
    }, "\n")
    post_tool.handle(payload("ApplyPatch", { patch_text = patch }, [[D:\proj]]), "claudecode")
    diff.close_for_file = orig

    assert.are.same({ abs }, closed)
  end)
end)

describe("post_tool.handle (robustness)", function()
  it("missing tool_input does not raise", function()
    assert.has_no.errors(function()
      post_tool.handle({ tool_name = "Edit", cwd = "/proj" }, "claudecode")
    end)
  end)

  it("empty patch_text is a no-op", function()
    assert.has_no.errors(function()
      post_tool.handle(payload("ApplyPatch", { patch_text = "" }), "claudecode")
    end)
  end)

  it("unknown tool_name does not raise", function()
    assert.has_no.errors(function()
      post_tool.handle(payload("Read", { file_path = "/proj/x" }), "claudecode")
    end)
  end)
end)
