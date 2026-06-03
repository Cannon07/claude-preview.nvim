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

-- Claude Code's hook payload is already canonical ({tool_name, cwd, tool_input}),
-- so its normaliser is almost identity. The one translation is Windows-only: in
-- addition to `Bash`, Claude Code exposes a distinct `PowerShell` tool and routes
-- shell file ops through it (e.g. the Haiku model deletes via `Remove-Item …`,
-- moves via `Move-Item`, writes via `Set-Content`/`Out-File`). Semantically those
-- are shell proposals — Tier-1 indicator-only, `bash_*` origin prefix — identical
-- in handling to `Bash`. Folding `PowerShell` onto the canonical `Bash` tool here
-- means the dispatcher, emitters, and shell_detect need no awareness of a separate
-- tool: shell_detect's grammar is what tells PowerShell and POSIX commands apart.
-- (STEP 0 of the shell-detect work confirmed tool_name="PowerShell"; the hook
-- matcher gained `PowerShell` so the proposal reaches us at all.)
local function claudecode(raw)
  if raw and raw.tool_name == "PowerShell" then
    local out = {}
    for k, v in pairs(raw) do out[k] = v end
    out.tool_name = "Bash"
    return out
  end
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

-- Copilot tools as of 2026-05-21: apply_patch, edit, str_replace, create,
-- write, bash (plus view/glob/grep/ls/report_intent which the shim drops
-- before invoking us). `str_replace` and `edit` carry the same {path,
-- old_str, new_str} shape; both alias to Edit. `create` and `write` both
-- alias to Write (file_text vs content).
local COPILOT_TOOL_MAP = {
  apply_patch = "ApplyPatch",
  edit        = "Edit",
  str_replace = "Edit",
  create      = "Write",
  write       = "Write",
  bash        = "Bash",
}

-- Copilot delivers `toolArgs` as a JSON-encoded string in preToolUse and as
-- an object in postToolUse. For apply_patch the string IS the raw patch text
-- (not JSON). For every other tool the string contains a JSON object with
-- snake_case keys (path, old_str, new_str, file_text, command, ...).
--
-- Note: file paths are run through the shared `resolve_path`, which collapses
-- ../ and ./ segments via vim.fs.normalize. The old bash copilot shim did
-- not — paths were preserved verbatim. The change is deliberate and matches
-- opencode's contract: internal keys (active_diffs, changes registry) must
-- be canonical so logically-same files compare equal across backends.
local function copilot(raw)
  local tool = (raw and raw.toolName) or ""
  local cwd  = (raw and raw.cwd) or ""
  local args = raw and raw.toolArgs

  local canonical_tool = COPILOT_TOOL_MAP[tool]

  local args_string, args_table
  if type(args) == "string" then
    args_string = args
    if canonical_tool ~= "ApplyPatch" then
      local ok, decoded = pcall(vim.json.decode, args)
      if ok and type(decoded) == "table" then args_table = decoded end
    end
  elseif type(args) == "table" then
    args_table = args
    if canonical_tool == "ApplyPatch" then
      -- Unusual but possible in postToolUse: mirror the bash adapter which
      -- stringified the object via tojson so downstream parsing is uniform.
      args_string = vim.json.encode(args)
    end
  end
  args_table = args_table or {}

  -- Defensive: the old bash shim explicitly skipped Edit/Write with an empty
  -- file path and Bash with an empty command. Carry that contract forward —
  -- otherwise a `{path: ""}` payload reaches diff.show_diff with file_path=""
  -- and opens a broken diff tab. Drop the tool_name so the dispatcher no-ops.
  local function blank(s) return s == nil or s == "" end

  local tool_input = {}
  if canonical_tool == "ApplyPatch" then
    if blank(args_string) then
      return { tool_name = nil, cwd = cwd, tool_input = {} }
    end
    tool_input.patch_text = args_string
  elseif canonical_tool == "Bash" then
    if blank(args_table.command) then
      return { tool_name = nil, cwd = cwd, tool_input = {} }
    end
    tool_input.command = args_table.command
  elseif canonical_tool == "Edit" then
    local fp = resolve_path(args_table.path, cwd)
    if blank(fp) then
      return { tool_name = nil, cwd = cwd, tool_input = {} }
    end
    tool_input.file_path   = fp
    tool_input.old_string  = args_table.old_str or ""
    tool_input.new_string  = args_table.new_str or ""
    tool_input.replace_all = false
  elseif canonical_tool == "Write" then
    local fp = resolve_path(args_table.path, cwd)
    if blank(fp) then
      return { tool_name = nil, cwd = cwd, tool_input = {} }
    end
    tool_input.file_path = fp
    tool_input.content   = args_table.file_text or args_table.content or ""
  end

  return {
    tool_name  = canonical_tool,
    cwd        = cwd,
    tool_input = tool_input,
  }
end

-- Codex's hook payload is almost canonical: top-level {tool_name, cwd,
-- tool_input}. The only real translation is apply_patch → ApplyPatch with
-- tool_input.command (the raw `*** Begin Patch ... *** End Patch` text)
-- moved to tool_input.patch_text. Edit/Write/Bash/ApplyPatch are otherwise
-- passthrough — codex models route all edits through apply_patch today,
-- but the Edit/Write/Bash branches exist defensively in case a future
-- codex version (or an MCP server) emits those names with Claude-Code-
-- style field shapes.
--
-- Note: file paths are run through the shared `resolve_path`, which collapses
-- ../ and ./ segments via vim.fs.normalize. The old bash codex shim did not —
-- paths were preserved verbatim. The change is deliberate and matches the
-- opencode/copilot contract: internal keys (active_diffs, changes registry)
-- must be canonical so logically-same files compare equal across backends.
--
-- The canonical-ApplyPatch branch (uppercase) below also fixes a dormant
-- bug in the old shim: its `ApplyPatch|Edit|Write` case blank-checked
-- tool_input.file_path, which canonical ApplyPatch doesn't carry, so any
-- such payload would have been silently dropped. Nothing emits canonical
-- ApplyPatch today, but the new branch checks patch_text correctly.
local function codex(raw)
  local tool = (raw and raw.tool_name) or ""
  local cwd  = (raw and raw.cwd) or ""
  local args = (raw and raw.tool_input) or {}

  local function blank(s) return s == nil or s == "" end

  if tool == "apply_patch" then
    if blank(args.command) then
      return { tool_name = nil, cwd = cwd, tool_input = {} }
    end
    return {
      tool_name  = "ApplyPatch",
      cwd        = cwd,
      tool_input = { patch_text = args.command },
    }
  elseif tool == "ApplyPatch" then
    if blank(args.patch_text) then
      return { tool_name = nil, cwd = cwd, tool_input = {} }
    end
    return { tool_name = "ApplyPatch", cwd = cwd, tool_input = args }
  elseif tool == "Edit" or tool == "Write" then
    local fp = resolve_path(args.file_path, cwd)
    if blank(fp) then
      return { tool_name = nil, cwd = cwd, tool_input = {} }
    end
    local out = {}
    for k, v in pairs(args) do out[k] = v end
    out.file_path = fp
    return { tool_name = tool, cwd = cwd, tool_input = out }
  elseif tool == "Bash" then
    if blank(args.command) then
      return { tool_name = nil, cwd = cwd, tool_input = {} }
    end
    return { tool_name = "Bash", cwd = cwd, tool_input = args }
  end

  return { tool_name = nil, cwd = cwd, tool_input = {} }
end

M.normalisers = {
  claudecode = claudecode,
  opencode   = opencode,
  copilot    = copilot,
  codex      = codex,
  -- gemini will land its own normaliser when it flips.
}

--- @param raw table  decoded hook payload
--- @param backend string  CODE_PREVIEW_BACKEND value
--- @return table  { tool_name, cwd, tool_input }
function M.normalise(raw, backend)
  local fn = M.normalisers[backend] or identity
  return fn(raw)
end

return M
