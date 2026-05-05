local M = {}

local uv = vim.uv or vim.loop

function M.systemlist(cmd)
  local ok, result = pcall(vim.fn.systemlist, cmd)
  if not ok then
    return {}
  end
  return result or {}
end

function M.root(cwd)
  cwd = cwd or (uv and uv.cwd and uv.cwd()) or vim.fn.getcwd()
  local result = M.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 and result[1] and result[1] ~= "" then
    return vim.trim(result[1])
  end
  return nil
end

function M.repo_relative_path(name)
  if not name or name == "" then
    return nil
  end
  local abs = vim.fn.fnamemodify(name, ":p")
  local root = M.root(vim.fn.fnamemodify(name, ":h"))
  if root and root ~= "" then
    if vim.fs and vim.fs.relpath then
      local rel = vim.fs.relpath(root, abs)
      if rel then
        return rel
      end
    end
    if abs:sub(1, #root + 1) == root .. "/" then
      return abs:sub(#root + 2)
    end
  end
  return abs
end

return M
