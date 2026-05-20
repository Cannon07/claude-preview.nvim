-- pre_tool/normalisers.lua — Per-backend hook payload normalisation.
--
-- Every backend passes the raw hook payload (parsed from JSON) and a backend
-- name; the matching normaliser returns the canonical shape consumed by
-- pre_tool.handle:
--
--   { tool_name = "Edit"|"Write"|"MultiEdit"|"Bash"|"ApplyPatch",
--     cwd       = "/abs/path",
--     tool_input = { file_path, ..., (tool-specific fields) } }
--
-- Claude Code's hook format is already canonical, so its entry is identity.
-- OpenCode fires hooks with lowercase tool names and camelCase argument keys,
-- so the opencode normaliser maps both into the canonical shape. New backends
-- slot in by adding a function to the table.

local M = {}

local function identity(raw)
  return raw
end

-- OpenCode tools as of 2026-05-19: edit, write, multiedit, bash, apply_patch
-- (plus read, glob, grep, which the TS-side allowlist filters out before they
-- ever reach this normaliser). Update this map when OpenCode adds a tool the
-- plugin should preview.
local OPENCODE_TOOL_MAP = {
  edit        = "Edit",
  write       = "Write",
  multiedit   = "MultiEdit",
  bash        = "Bash",
  apply_patch = "ApplyPatch",
}

-- Resolve a possibly-relative filePath against cwd, then collapse ".."/"."
-- segments so internal keys (active_diffs, changes registry) are canonical.
-- Matches Node's path.resolve semantics the old TS plugin used; without it
-- opencode keys could be raw "/proj/../escape.txt" strings that don't
-- compare equal to claudecode-shaped keys for the same logical file.
local function resolve_path(p, cwd)
  if not p or p == "" then return p end
  local abs = p
  if p:sub(1, 1) ~= "/" and cwd and cwd ~= "" then
    abs = cwd .. "/" .. p
  end
  return vim.fs.normalize(abs)
end

local function opencode(raw)
  local tool = raw and raw.tool or ""
  local args = (raw and raw.args) or {}
  local cwd  = (raw and raw.cwd) or ""

  local tool_input = {}

  if args.filePath ~= nil then
    tool_input.file_path = resolve_path(args.filePath, cwd)
  end
  if args.oldString  ~= nil then tool_input.old_string  = args.oldString  end
  if args.newString  ~= nil then tool_input.new_string  = args.newString  end
  if args.replaceAll ~= nil then tool_input.replace_all = args.replaceAll end
  if args.content    ~= nil then tool_input.content     = args.content    end
  if args.command    ~= nil then tool_input.command     = args.command    end

  if type(args.edits) == "table" then
    local edits = {}
    for i, e in ipairs(args.edits) do
      edits[i] = {
        old_string = e.oldString,
        new_string = e.newString,
      }
    end
    tool_input.edits = edits
  end

  -- ApplyPatch field name varies across models (`patch` vs `patchText`).
  if args.patchText ~= nil then tool_input.patch_text = args.patchText end
  if args.patch     ~= nil then tool_input.patch_text = args.patch     end

  return {
    tool_name  = OPENCODE_TOOL_MAP[tool],
    cwd        = cwd,
    tool_input = tool_input,
  }
end

M.normalisers = {
  claudecode = identity,
  opencode   = opencode,
  -- codex / copilot / gemini will land their own normalisers as they flip.
}

--- @param raw table  decoded hook payload
--- @param backend string  CODE_PREVIEW_BACKEND value
--- @return table  { tool_name, cwd, tool_input }
function M.normalise(raw, backend)
  local fn = M.normalisers[backend] or identity
  return fn(raw)
end

return M
