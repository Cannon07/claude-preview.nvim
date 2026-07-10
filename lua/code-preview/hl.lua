-- hl.lua — normalizes a highlights-config value into an nvim_set_hl-compatible
-- table. A bare highlight-group-name string links to that group; a table
-- passes through (optionally merged with an override table). Extracted from
-- near-duplicate resolve_hl (diff.lua) / define_hl (neo_tree.lua) helpers.
--
-- IMPORTANT: never set `default = true` here. nvim_set_hl's `default` flag is
-- sticky for the life of the process (once a group has ANY definition in a
-- namespace, a later `default = true` call is silently ignored) — that
-- staleness is exactly the bug this module fixes. Do not reintroduce it.
local M = {}

--- @param hl table|string|nil  a highlights-config value
--- @param opts table|nil      optional overrides merged on top (force)
--- @return table|nil          nvim_set_hl-compatible table, or nil if hl is
---                            neither a string nor a table (caller decides
---                            the fallback, e.g. `resolve(hl) or {...}`)
function M.resolve(hl, opts)
  if type(hl) == "string" then
    hl = { link = hl }
  elseif type(hl) ~= "table" then
    return nil
  end
  if opts then
    return vim.tbl_extend("force", hl, opts)
  end
  return hl
end

return M
