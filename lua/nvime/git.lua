local M = {}

local uv = vim.uv or vim.loop

function M.systemlist(cmd)
  local ok, result = pcall(vim.fn.systemlist, cmd)
  if not ok then
    return {}
  end
  return result or {}
end

local root_cache = {}

local function clear_root_cache()
  root_cache = {}
end

vim.api.nvim_create_autocmd("DirChanged", {
  group = vim.api.nvim_create_augroup("NvimeGitRootCache", { clear = true }),
  callback = clear_root_cache,
})

function M.clear_root_cache()
  clear_root_cache()
end

function M.root(cwd)
  cwd = cwd or (uv and uv.cwd and uv.cwd()) or vim.fn.getcwd()
  local cached = root_cache[cwd]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end
  local result = M.systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 and result[1] and result[1] ~= "" then
    local resolved = vim.trim(result[1])
    root_cache[cwd] = resolved
    return resolved
  end
  -- Negative cache to avoid re-spawning git for non-repo dirs on hot paths.
  root_cache[cwd] = false
  return nil
end

-- The "either git root or cwd" idiom that 6+ modules duplicated. Returns a
-- definite directory regardless of whether `cwd` is inside a git repo.
function M.repo_root(cwd)
  cwd = cwd or (uv and uv.cwd and uv.cwd()) or vim.fn.getcwd()
  return M.root(cwd) or cwd
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
