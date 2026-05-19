#!/usr/bin/env -S nvim --headless -l
-- apply-patch.lua — Headless-CLI shim around lua/code-preview/apply/patch.lua.
--
-- Usage: nvim --headless -l apply-patch.lua <patch_json> <cwd> <output_dir>
--
-- Reads the patch text from a JSON file ({"patch_text": "..."}), parses via
-- the in-process module, writes per-file results to output_dir:
--
--   <output_dir>/files.json   — list of {path, rel_path, action, orig, prop}
--   <output_dir>/<NN>-orig    — original content
--   <output_dir>/<NN>-prop    — proposed content
--
-- The real implementation is in-process Lua at lua/code-preview/apply/patch.lua.

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*)/")
vim.opt.runtimepath:prepend(script_dir .. "/..")

local apply_patch = require("code-preview.apply.patch")

local patch_json_path = arg[1]
local cwd = arg[2]
local output_dir = arg[3]

if not patch_json_path or not cwd or not output_dir then
  io.stderr:write("Usage: nvim --headless -l apply-patch.lua <patch_json> <cwd> <output_dir>\n")
  vim.cmd("cquit! 1")
  return
end

local f = io.open(patch_json_path, "r")
if not f then
  io.stderr:write("Cannot open patch JSON: " .. patch_json_path .. "\n")
  vim.cmd("cquit! 1")
  return
end
local json_str = f:read("*a")
f:close()

local ok, data = pcall(vim.json.decode, json_str)
if not ok or not data.patch_text then
  io.stderr:write("Invalid patch JSON or missing patch_text\n")
  vim.cmd("cquit! 1")
  return
end

local function write_lines(path, lines)
  local fh = io.open(path, "w")
  if not fh then return false end
  for i, line in ipairs(lines) do
    fh:write(line)
    if i < #lines then fh:write("\n") end
  end
  if #lines > 0 then fh:write("\n") end
  fh:close()
  return true
end

local files = apply_patch.parse(data.patch_text, cwd)
local results = {}

for i, file in ipairs(files) do
  local tag = string.format("%02d", i)
  local orig_out = output_dir .. "/" .. tag .. "-orig"
  local prop_out = output_dir .. "/" .. tag .. "-prop"
  write_lines(orig_out, file.orig)
  write_lines(prop_out, file.prop)
  table.insert(results, {
    path = file.path,
    rel_path = file.rel_path,
    action = file.action,
    orig = orig_out,
    prop = prop_out,
  })
end

local results_path = output_dir .. "/files.json"
local rf = io.open(results_path, "w")
if rf then
  rf:write(vim.json.encode(results))
  rf:close()
end

vim.cmd("qall!")
