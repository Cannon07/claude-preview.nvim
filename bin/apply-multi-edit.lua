#!/usr/bin/env -S nvim --headless -l
-- apply-multi-edit.lua — Headless-CLI shim around lua/code-preview/apply/multi_edit.lua.
--
-- Usage (via nvim --headless -l):
--   nvim --headless -l apply-multi-edit.lua <hook_json_string> <output_path>
--
-- The real implementation is in-process Lua at lua/code-preview/apply/multi_edit.lua.

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*)/")
vim.opt.runtimepath:prepend(script_dir .. "/..")

local apply_multi_edit = require("code-preview.apply.multi_edit")

local hook_json   = arg[1]
local output_path = arg[2]

local ok, input = pcall(vim.json.decode, hook_json)
if not ok then
  io.stderr:write("apply-multi-edit.lua: failed to parse JSON: " .. tostring(input) .. "\n")
  os.exit(1)
end

local content = apply_multi_edit.apply(input.tool_input.file_path, input.tool_input.edits or {})

local out = assert(io.open(output_path, "w"))
out:write(content)
out:close()

os.exit(0)
