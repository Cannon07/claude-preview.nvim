-- pre_tool_shell_detect_spec.lua — Tier 1 shell-write + delete detection.
--
-- (Renamed from pre_tool_bash_detect_spec.lua when bash_detect → shell_detect.)
--
-- Two axes, tested as such (see shell_detect.lua's header):
--
--   * POSIX block — the historical bash rows, byte-for-byte. They pin
--     documented edge cases from real bugs; resist "obvious simplifications"
--     without reading them. They assume Unix path semantics (`/`-absolute,
--     $HOME, /dev/), so on Windows they are marked `pending` — the Unix CI
--     runners are the regression guard for POSIX behaviour.
--   * Windows block — git-bash-on-Windows POSIX commands AND PowerShell
--     commands, both with Windows paths. Inputs are the real STEP 0 samples
--     captured from Claude Code (the Haiku model emits `Remove-Item …` etc.
--     through a `PowerShell` tool). Marked `pending` off Windows.
--
-- New rows go at the bottom of the relevant block with a short comment.

local shell_detect = require("code-preview.pre_tool.shell_detect")

local IS_WIN = vim.fn.has("win32") == 1
local CWD = "/proj"
local HOME = os.getenv("HOME") or "/root"

local function sorted(t)
  local copy = {}
  for _, v in ipairs(t) do table.insert(copy, v) end
  table.sort(copy)
  return copy
end

-- ── POSIX grammar (Unix path semantics) ──────────────────────────

describe("shell_detect.detect_rm_paths (POSIX)", function()
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
      if IS_WIN then return pending("POSIX path semantics: Unix-only") end
      assert.are.same(sorted(c.expect), sorted(shell_detect.detect_rm_paths(c.cmd, CWD)))
    end)
  end
end)

describe("shell_detect.detect_write_paths (POSIX)", function()
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
      if IS_WIN then return pending("POSIX path semantics: Unix-only") end
      assert.are.same(sorted(c.expect), sorted(shell_detect.detect_write_paths(c.cmd, CWD)))
    end)
  end
end)

-- In-place editors (perl/ruby/awk) — write the trailing file(s) in place, like
-- sed -i. Require the in-place flag so read-only one-liners aren't flagged.
describe("shell_detect.detect_write_paths (in-place editors)", function()
  local cases = {
    -- The real codex sample: -0pi cluster, multi-statement substitution.
    { name = "perl -0pi real sample", cmd = [[perl -0pi -e 's/(<!-- a -->\n)/$1<!-- b -->\n/' README.md]], expect = { CWD .. "/README.md" } },
    { name = "perl -pi -e",           cmd = "perl -pi -e 's/a/b/' foo.txt",        expect = { CWD .. "/foo.txt" } },
    { name = "perl -i.bak backup",    cmd = "perl -i.bak -pe 's/a/b/' foo.txt",    expect = { CWD .. "/foo.txt" } },
    { name = "perl -pie bundled e",   cmd = "perl -pie 's/a/b/' foo.txt",          expect = { CWD .. "/foo.txt" } },
    -- `;` inside the single-quoted script must not split the command.
    { name = "perl multi-statement",  cmd = "perl -pi -e 's/a/b/; s/c/d/' foo.txt", expect = { CWD .. "/foo.txt" } },
    { name = "perl multiple files",   cmd = "perl -pi -e 's/a/b/' a.txt b.txt",    expect = { CWD .. "/a.txt", CWD .. "/b.txt" } },
    { name = "perl absolute target",  cmd = "perl -pi -e 's/a/b/' /etc/hosts",     expect = { "/etc/hosts" } },
    { name = "sudo perl",             cmd = "sudo perl -pi -e 's/a/b/' /etc/hosts", expect = { "/etc/hosts" } },
    -- Segment splitting: the cd is a separate command; only perl writes.
    { name = "perl after && chain",   cmd = "cd sub && perl -pi -e 's/a/b/' f.txt", expect = { CWD .. "/f.txt" } },
    { name = "ruby -i -pe",           cmd = [[ruby -i -pe 'gsub(/a/,"b")' foo.txt]], expect = { CWD .. "/foo.txt" } },
    { name = "gawk -i inplace",       cmd = "gawk -i inplace '{print}' data.txt",  expect = { CWD .. "/data.txt" } },
    -- Negatives: no in-place flag → read-only → nothing flagged.
    { name = "perl read-only -ne",    cmd = "perl -ne 'print' foo.txt",            expect = {} },
    { name = "awk read-only",         cmd = "awk '{print}' data.txt",              expect = {} },
    { name = "perl -e no file",       cmd = "perl -e 'print 1'",                   expect = {} },
  }
  for _, c in ipairs(cases) do
    it(c.name, function()
      if IS_WIN then return pending("POSIX path semantics: Unix-only") end
      assert.are.same(sorted(c.expect), sorted(shell_detect.detect_write_paths(c.cmd, CWD)))
    end)
  end
end)

describe("shell_detect.detect combined (POSIX)", function()
  it("returns both rm and write paths", function()
    if IS_WIN then return pending("POSIX path semantics: Unix-only") end
    local r = shell_detect.detect("rm old.txt && echo x > new.txt", CWD)
    assert.are.same({ CWD .. "/old.txt" }, r.rm_paths)
    assert.are.same({ CWD .. "/new.txt" }, r.write_paths)
  end)
end)

-- ── Windows paths: git-bash POSIX commands + PowerShell commands ──
--
-- cwd is a backslash drive path (Claude Code's hook payload form on Windows).
-- Expected outputs are canonical backslash paths — the form the changes
-- registry keys on (matching Edit/Write), so the neo-tree indicator lands.

local WCWD = [[C:\proj]]

describe("shell_detect.detect_rm_paths (Windows)", function()
  local cases = {
    -- git-bash POSIX rm with a relative path → resolved against the backslash cwd.
    { name = "bash rm relative",            cmd = [[rm foo.txt]],                       expect = { [[C:\proj\foo.txt]] } },
    -- The original STEP 0 bug: a Windows-absolute path was treated as relative
    -- and the cwd was prepended, producing garbage. It must stay absolute now.
    { name = "bash rm windows-absolute",    cmd = [[rm -f "D:\other\cp-src.txt"]],      expect = { [[D:\other\cp-src.txt]] } },
    -- PowerShell delete — the real Haiku sample.
    { name = "Remove-Item -Path relative",  cmd = [[Remove-Item -Path ".step0\del.txt" -Force]], expect = { [[C:\proj\.step0\del.txt]] } },
    { name = "Remove-Item windows-absolute",cmd = [[Remove-Item -Path "D:\proj\x.txt"]], expect = { [[D:\proj\x.txt]] } },
    { name = "Remove-Item comma-list",      cmd = [[Remove-Item -Path "a.txt","b.txt" -Force]], expect = { [[C:\proj\a.txt]], [[C:\proj\b.txt]] } },
    -- Real Haiku multi-delete: a comma-list with a SPACE after the comma, which
    -- naive tokenising splits into "a", + a stray "b" positional. Both files
    -- must register (regression: only the first was marked).
    { name = "Remove-Item comma-list with spaces", cmd = [[Remove-Item -Path "D:\proj\temp1.txt", "D:\proj\temp2.txt" -Force]], expect = { [[D:\proj\temp1.txt]], [[D:\proj\temp2.txt]] } },
    { name = "Remove-Item multiple positionals", cmd = [[Remove-Item a.txt b.txt]], expect = { [[C:\proj\a.txt]], [[C:\proj\b.txt]] } },
    { name = "Remove-Item switches before positional", cmd = [[Remove-Item -Recurse -Force build]], expect = { [[C:\proj\build]] } },
    { name = "del alias positional",        cmd = [[del bad.txt]],                      expect = { [[C:\proj\bad.txt]] } },
    { name = "ri alias",                    cmd = [[ri ".step0\gone.log"]],             expect = { [[C:\proj\.step0\gone.log]] } },
    -- Non-delete cmdlets must not register.
    { name = "Get-Content ignored",         cmd = [[Get-Content "x.txt"]],              expect = {} },
  }
  for _, c in ipairs(cases) do
    it(c.name, function()
      if not IS_WIN then return pending("Windows path semantics: Windows-only") end
      assert.are.same(sorted(c.expect), sorted(shell_detect.detect_rm_paths(c.cmd, WCWD)))
    end)
  end
end)

describe("shell_detect.detect_write_paths (Windows)", function()
  local cases = {
    -- git-bash POSIX redirect (forward slash relative) resolved to backslash.
    { name = "bash redirect relative",      cmd = [[echo x > out.txt]],                 expect = { [[C:\proj\out.txt]] } },
    { name = "bash redirect dotdir",        cmd = [[echo x > .step0/new.txt]],          expect = { [[C:\proj\.step0\new.txt]] } },
    { name = "bash redirect windows-abs",   cmd = [[echo x > "D:\logs\y.txt"]],         expect = { [[D:\logs\y.txt]] } },
    -- PowerShell writes — real samples.
    { name = "Set-Content -Path",           cmd = [[Set-Content -Path ".step0\new.txt" -Value "hi"]], expect = { [[C:\proj\.step0\new.txt]] } },
    { name = "Set-Content here-string",     cmd = 'Set-Content -Path ".step0\\ps-pswrite.txt" -Value @"\nLine 1\nLine 2\n"@', expect = { [[C:\proj\.step0\ps-pswrite.txt]] } },
    { name = "Add-Content",                 cmd = [[Add-Content -Path ".step0\ps-existing.txt" -Value "appended"]], expect = { [[C:\proj\.step0\ps-existing.txt]] } },
    { name = "Out-File -FilePath",          cmd = [[Out-File -FilePath "log.txt"]],     expect = { [[C:\proj\log.txt]] } },
    { name = "Out-File via pipeline positional", cmd = [[Get-ChildItem | Out-File "list.txt"]], expect = { [[C:\proj\list.txt]] } },
    { name = "Move-Item destination",       cmd = [[Move-Item -Path ".step0\a" -Destination ".step0\b.txt" -Force]], expect = { [[C:\proj\.step0\b.txt]] } },
    { name = "Copy-Item destination",       cmd = [[Copy-Item -Path ".step0\a" -Destination ".step0\c.txt" -Force]], expect = { [[C:\proj\.step0\c.txt]] } },
    { name = "Move-Item windows-abs dest",  cmd = [[Move-Item -Path "a" -Destination "D:\dst\b.txt"]], expect = { [[D:\dst\b.txt]] } },
    { name = "UNC destination",             cmd = [[Set-Content -Path "\\srv\share\f.txt" -Value x]], expect = { [[\\srv\share\f.txt]] } },
    -- Look-alikes that must NOT be flagged as writes.
    { name = "Out-Null not a write",        cmd = [[New-Item -ItemType Directory d | Out-Null]], expect = {} },
    { name = "Out-String not a write",      cmd = [[Get-Process | Out-String]],         expect = {} },
    { name = "transient .tmp filtered",     cmd = [[Set-Content -Path "scratch.tmp" -Value x]], expect = {} },
    { name = "FD redirect skipped",         cmd = [[some-exe 2>&1]],                     expect = {} },
  }
  for _, c in ipairs(cases) do
    it(c.name, function()
      if not IS_WIN then return pending("Windows path semantics: Windows-only") end
      assert.are.same(sorted(c.expect), sorted(shell_detect.detect_write_paths(c.cmd, WCWD)))
    end)
  end
end)

describe("shell_detect.detect combined (Windows)", function()
  it("PowerShell delete + write in one ;-separated command", function()
    if not IS_WIN then return pending("Windows path semantics: Windows-only") end
    local r = shell_detect.detect(
      [[Remove-Item -Path "old.txt" -Force; Set-Content -Path "new.txt" -Value "x"]], WCWD)
    assert.are.same({ [[C:\proj\old.txt]] }, r.rm_paths)
    assert.are.same({ [[C:\proj\new.txt]] }, r.write_paths)
  end)
end)
