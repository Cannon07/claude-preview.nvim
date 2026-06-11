local M = {}

-- { [absolute_path] = "modified" | "created" | "deleted" }
-- Pure Lua key-value store, no external dependencies
local pending = {}

-- Normalize path: make absolute, canonicalize separators, strip trailing slash.
--
-- Separator canonicalization is load-bearing on Windows: neo-tree keys its tree
-- nodes by native (backslash) paths, and the BEFORE_RENDER handler looks our
-- status up by `node.path`. Backends that build a file path by joining cwd with
-- a relative patch/tool path (codex/opencode `apply_patch`, opencode/copilot
-- Edit) produce mixed separators like `D:\proj\sub/file.txt`, which never
-- compare equal to neo-tree's `D:\proj\sub\file.txt` — so the diff opens but the
-- tree marker is silently dropped. Folding to the OS-native separator makes the
-- registry key match. No-op on Unix (sep is "/"), and a no-op for the already
-- native backslash paths Claude Code sends.
local function normalize(filepath)
  local p = vim.fn.fnamemodify(filepath, ":p")
  if package.config:sub(1, 1) == "\\" then
    p = p:gsub("/", "\\")
    return (p:gsub("\\$", ""))   -- Windows: separators folded above; strip trailing "\"
  end
  -- Unix: byte-identical to the pre-Windows behaviour. Strip "/" only — a
  -- trailing backslash is a legal Unix filename character, not a separator.
  return (p:gsub("/$", ""))
end

function M.set(filepath, status)
  pending[normalize(filepath)] = status
end

function M.clear(filepath)
  pending[normalize(filepath)] = nil
end

function M.clear_all()
  pending = {}
end

function M.get(filepath)
  return pending[normalize(filepath)]
end

function M.get_all()
  return vim.deepcopy(pending)
end

function M.clear_by_status(status)
  for path, s in pairs(pending) do
    if s == status then
      pending[path] = nil
    end
  end
end

return M
