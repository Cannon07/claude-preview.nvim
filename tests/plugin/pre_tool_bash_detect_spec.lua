-- pre_tool_bash_detect_spec.lua — Tier 1 shell-write + rm detection.
--
-- Table-driven. Each row pins a documented edge case from the historical
-- bin/core-pre-tool.sh detection logic. New rows go at the bottom with a
-- short comment explaining the case. Resist "obvious simplifications" to
-- bash_detect.lua without first reading these rows.

local bash_detect = require("code-preview.pre_tool.bash_detect")

local CWD = "/proj"
local HOME = os.getenv("HOME") or "/root"

local function sorted(t)
  local copy = {}
  for _, v in ipairs(t) do table.insert(copy, v) end
  table.sort(copy)
  return copy
end

describe("bash_detect.detect_rm_paths", function()
  local cases = {
    { name = "plain rm",                   cmd = "rm foo.txt",                  expect = { CWD .. "/foo.txt" } },
    { name = "rm with flags",              cmd = "rm -rf build",                expect = { CWD .. "/build" } },
    { name = "sudo rm absolute",           cmd = "sudo rm /etc/foo",            expect = { "/etc/foo" } },
    { name = "rm with home tilde",         cmd = "rm ~/.config/x",              expect = { HOME .. "/.config/x" } },
    { name = "apostrophe in filename",     cmd = "rm \"it's-mine.txt\"",        expect = { CWD .. "/it's-mine.txt" } },
    { name = "compound with &&",           cmd = "rm a && rm b",                expect = { CWD .. "/a", CWD .. "/b" } },
    { name = "compound with ;",            cmd = "rm a ; rm b",                 expect = { CWD .. "/a", CWD .. "/b" } },
    { name = "/tmp not filtered for rm",   cmd = "rm /tmp/foo",                 expect = { "/tmp/foo" } },
    { name = "trailing CR stripped",       cmd = "rm a.txt\r",                  expect = { CWD .. "/a.txt" } },
    { name = "non-rm command ignored",     cmd = "echo rm foo",                 expect = {} },
    -- Real-world case: Claude Code escapes apostrophes in unquoted filenames.
    { name = "backslash-escaped apostrophe", cmd = "rm it\\'s-mine.txt",        expect = { CWD .. "/it's-mine.txt" } },
    -- Backslash-escaped spaces (`rm my\ file.txt`) would need a real shell
    -- tokeniser to split correctly; documented as a Tier 1 limitation.
  }
  for _, c in ipairs(cases) do
    it(c.name, function()
      assert.are.same(sorted(c.expect), sorted(bash_detect.detect_rm_paths(c.cmd, CWD)))
    end)
  end
end)

describe("bash_detect.detect_write_paths", function()
  local cases = {
    { name = "single > redirect",          cmd = "echo x > foo.txt",            expect = { CWD .. "/foo.txt" } },
    { name = "append >> redirect",         cmd = "echo x >> log.txt",           expect = { CWD .. "/log.txt" } },
    { name = "absolute redirect",          cmd = "echo x > /var/log/y",         expect = { "/var/log/y" } },
    { name = "/tmp not filtered for writes", cmd = "echo x > /tmp/real",        expect = { "/tmp/real" } },
    { name = "FD redirection 2>&1 skipped",cmd = "cmd 2>&1",                    expect = {} },
    { name = "/dev/null filtered",         cmd = "cmd > /dev/null",             expect = {} },
    { name = "/dev/stderr filtered",       cmd = "cmd > /dev/stderr",           expect = {} },
    { name = "mv writes destination",      cmd = "mv a.tmp b",                  expect = { CWD .. "/b" } },
    { name = "cp writes destination",      cmd = "cp a b",                      expect = { CWD .. "/b" } },
    { name = "tee target",                 cmd = "echo x | tee foo.txt",        expect = { CWD .. "/foo.txt" } },
    { name = "tee -a target",              cmd = "echo x | tee -a foo.txt",     expect = { CWD .. "/foo.txt" } },
    { name = "sed -i target",              cmd = "sed -i 's/x/y/' foo.txt",     expect = { CWD .. "/foo.txt" } },
    { name = "transient .tmp filtered",    cmd = "echo x > scratch.tmp",        expect = {} },
    { name = "transient ~ filtered",       cmd = "echo x > foo~",               expect = {} },
    { name = "home tilde expanded",        cmd = "echo x > ~/notes.md",         expect = { HOME .. "/notes.md" } },
    -- The HTML-comment false positive: the redirect regex picks up the `>`
    -- in `-->`, but looks_like_path rejects the resulting token because it
    -- contains a backslash (leaked from inside a quoted string).
    { name = "html comment false positive", cmd = "printf '<!-- note -->\\n\\n'", expect = {} },
    { name = "dedup duplicates",           cmd = "echo a > x.txt && echo b > x.txt", expect = { CWD .. "/x.txt" } },
    -- Apostrophe-escaped paths in redirects (companion to the rm case).
    { name = "backslash-escaped apostrophe in redirect", cmd = "echo x > it\\'s.txt", expect = { CWD .. "/it's.txt" } },
  }
  for _, c in ipairs(cases) do
    it(c.name, function()
      assert.are.same(sorted(c.expect), sorted(bash_detect.detect_write_paths(c.cmd, CWD)))
    end)
  end
end)

describe("bash_detect.detect (combined)", function()
  it("returns both rm and write paths", function()
    local r = bash_detect.detect("rm old.txt && echo x > new.txt", CWD)
    assert.are.same({ CWD .. "/old.txt" }, r.rm_paths)
    assert.are.same({ CWD .. "/new.txt" }, r.write_paths)
  end)
end)
