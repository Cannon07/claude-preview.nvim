-- apply_patch_spec.lua — path resolution for the GPT/Codex patch format.

local patch = require("code-preview.apply.patch")

local function update_patch(p)
  return "*** Begin Patch\n*** Update File: " .. p .. "\n@@\n-old\n+new\n*** End Patch\n"
end

-- Resolve the absolute path the parser assigns to the (single) file in a patch.
local function resolved_path(file_path, cwd)
  local files = patch.parse(update_patch(file_path), cwd)
  return files[1].path
end

describe("apply_patch path resolution", function()
  it("joins a relative path onto cwd", function()
    assert.equals("/home/u/app/lua/init.lua", resolved_path("lua/init.lua", "/home/u/app"))
  end)

  it("passes a Unix-absolute path through unchanged", function()
    assert.equals("/etc/hosts", resolved_path("/etc/hosts", "/home/u/app"))
  end)

  -- Regression: Codex emits Windows-absolute paths in apply_patch directives
  -- (`*** Update File: D:\proj\file`). Treating those as relative doubled them
  -- onto cwd (`D:\proj\D:\proj\file`), which fs_stats as missing — so an
  -- existing file was mis-marked "created", the diff opened at a bogus path,
  -- and a junk neo-tree node was injected. Absolute paths must pass through
  -- unchanged. Cross-platform: the drive-letter check matches on Unix too.
  it("passes a Windows drive-letter path through unchanged (backslash)", function()
    assert.equals(
      [[D:\proj\sub\file.txt]],
      resolved_path([[D:\proj\sub\file.txt]], [[D:\proj]])
    )
  end)

  it("passes a Windows drive-letter path through unchanged (forward slash)", function()
    assert.equals(
      "D:/proj/sub/file.txt",
      resolved_path("D:/proj/sub/file.txt", [[D:\proj]])
    )
  end)

  it("passes a Windows UNC path through unchanged", function()
    assert.equals(
      [[\\server\share\file.txt]],
      resolved_path([[\\server\share\file.txt]], [[D:\proj]])
    )
  end)
end)
