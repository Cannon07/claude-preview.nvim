-- apply/edit.lua — Apply a single Edit (old_string → new_string) to a file.
--
-- Pure function: reads the file, applies a literal (non-pattern) replacement,
-- returns the resulting content as a string. Empty old_string is treated as
-- "prepend new_string" to match the historical bin/apply-edit.lua behaviour.

local M = {}

--- @param file_path string  absolute path to the file (may not exist)
--- @param old_string string  literal text to find
--- @param new_string string  literal replacement text
--- @param replace_all boolean  if true, replace every occurrence
--- @return string  the resulting file content
function M.apply(file_path, old_string, new_string, replace_all)
  local content = ""
  local fh = io.open(file_path, "r")
  if fh then
    content = fh:read("*a")
    fh:close()
  end

  if replace_all then
    if old_string == "" then
      return new_string .. content
    end
    local parts = {}
    local search_start = 1
    while true do
      local s, e = string.find(content, old_string, search_start, true)
      if not s then
        table.insert(parts, content:sub(search_start))
        break
      end
      table.insert(parts, content:sub(search_start, s - 1))
      table.insert(parts, new_string)
      search_start = e + 1
    end
    return table.concat(parts)
  else
    if old_string == "" then
      return new_string .. content
    end
    local s, e = string.find(content, old_string, 1, true)
    if s then
      return content:sub(1, s - 1) .. new_string .. content:sub(e + 1)
    end
    return content
  end
end

return M
