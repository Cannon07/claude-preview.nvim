#!/usr/bin/env -S nvim --headless -l
-- apply-edit.lua — Headless-CLI shim around lua/code-preview/apply/edit.lua.
--
-- Usage (via nvim --headless -l):
--   nvim --headless -l apply-edit.lua <file_path> <old_string> <new_string> <replace_all> <output_path>
--
-- replace_all: "true" or "false"
--
-- The real implementation is in-process Lua at lua/code-preview/apply/edit.lua.
-- This shim survives only for external callers (legacy hooks, tests invoking
-- the script directly). After issue #47 phase 3, pre_tool.lua calls the module
-- directly without spawning a second nvim.

local script_dir = debug.getinfo(1, "S").source:sub(2):match("(.*)/")
vim.opt.runtimepath:prepend(script_dir .. "/..")

local apply_edit = require("code-preview.apply.edit")

local file_path   = arg[1]
local old_string  = arg[2]
local new_string  = arg[3]
local replace_all = arg[4] == "true"
local output_path = arg[5]

local content = apply_edit.apply(file_path, old_string, new_string, replace_all)

local out = assert(io.open(output_path, "w"))
out:write(content)
out:close()

os.exit(0)
