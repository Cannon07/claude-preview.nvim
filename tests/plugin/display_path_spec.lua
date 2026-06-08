-- display_path_spec.lua — diff-tab label: cwd-relative, separator-insensitive.

local pre_tool = require("code-preview.pre_tool")
local display_path = pre_tool.display_path

describe("pre_tool.display_path", function()
  it("strips the cwd prefix to a relative label", function()
    assert.equals("sub/file.lua", display_path("/home/u/app/sub/file.lua", "/home/u/app"))
  end)

  it("keeps the absolute path when the file is not under cwd", function()
    assert.equals("/etc/hosts", display_path("/etc/hosts", "/home/u/app"))
  end)

  it("returns the path unchanged when cwd is empty/nil", function()
    assert.equals("/a/b.lua", display_path("/a/b.lua", ""))
    assert.equals("/a/b.lua", display_path("/a/b.lua", nil))
  end)

  -- Regression: on Windows file_path is backslashed but cwd was compared as
  -- `cwd .. "/"`, so the prefix never matched and the tab fell back to the full
  -- absolute path. The fold makes the prefix test separator-insensitive; the
  -- sliced result keeps native separators. Windows-gated: on Unix a backslash is
  -- a legal filename character, so the fold must not run there.
  it("strips a backslashed cwd prefix on Windows", function()
    if package.config:sub(1, 1) ~= "\\" then
      return -- Windows-only behaviour
    end
    assert.equals(
      [[sub\file.lua]],
      display_path([[D:\proj\sub\file.lua]], [[D:\proj]])
    )
    -- not under cwd → unchanged
    assert.equals(
      [[E:\other\file.lua]],
      display_path([[E:\other\file.lua]], [[D:\proj]])
    )
  end)
end)

describe("pre_tool.handle ApplyPatch label", function()
  -- Regression: handle_apply_patch labelled the diff tab with file.rel_path —
  -- the literal path from the `*** Update File:` directive. Some codex models
  -- (GPT 5.3) write an ABSOLUTE path there, so the tab rendered `D:\...` instead
  -- of a cwd-relative label. The label must derive from the resolved path via
  -- display_path. Windows-gated: relativising a drive-letter path only happens
  -- on Windows.
  it("labels with a cwd-relative path even when the model emits an absolute path", function()
    if package.config:sub(1, 1) ~= "\\" then
      return -- Windows-only behaviour
    end
    local diff = require("code-preview.diff")
    local changes = require("code-preview.changes")
    local captured
    local orig = diff.show_diff
    diff.show_diff = function(_orig, _prop, display) captured = display end

    local abs = [[D:\proj\sub\README.md]]
    local cmd = "*** Begin Patch\n*** Update File: " .. abs .. "\n@@\n-old\n+new\n*** End Patch\n"
    pre_tool.handle({ tool_name = "apply_patch", cwd = [[D:\proj]], tool_input = { command = cmd } }, "codex")

    diff.show_diff = orig
    changes.clear_all()

    assert.equals([[sub\README.md]], captured)
  end)
end)
