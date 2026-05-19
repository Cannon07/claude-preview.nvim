-- pre_tool_normaliser_spec.lua — Per-backend hook payload normalisation.
--
-- Today every supported backend pre-normalises on its own side (Claude Code's
-- hook format is already canonical; OpenCode's TS plugin maps camelCase →
-- snake_case before invoking us), so the entries here are identity. The
-- value of this spec is locking the *contract* — a future backend that
-- doesn't pre-normalise will add a non-identity entry and a row here.

local normalisers = require("code-preview.pre_tool.normalisers")

describe("normalisers.normalise", function()
  local canonical = {
    tool_name = "Edit",
    cwd       = "/proj",
    tool_input = { file_path = "/proj/foo.lua", old_string = "a", new_string = "b" },
  }

  it("claudecode is identity", function()
    assert.are.same(canonical, normalisers.normalise(canonical, "claudecode"))
  end)

  it("opencode is identity (pre-normalised by TS plugin)", function()
    assert.are.same(canonical, normalisers.normalise(canonical, "opencode"))
  end)

  it("unknown backend falls back to identity", function()
    assert.are.same(canonical, normalisers.normalise(canonical, "future-agent"))
  end)
end)
