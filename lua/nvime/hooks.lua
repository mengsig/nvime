-- nvime.hooks
--
-- Git hook installer. Currently manages one hook —
-- `prepare-commit-msg` — which routes through `scripts/nvime-commit-msg`
-- to inject `Co-authored-by:` trailers from the attribution ledger.
--
-- The installer is idempotent and preserves any existing hook by chaining
-- (existing first, then nvime). The marker line `# nvime:prepare-commit-msg`
-- identifies the hook we own so subsequent install/uninstall don't touch
-- user-authored sections.

local git = require("nvime.git")
local state = require("nvime.state")

local M = {}

local MARKER = "# nvime:prepare-commit-msg"

local function repo_root()
  local cwd = (vim.uv or vim.loop).cwd()
  return git.root(cwd) or cwd
end

local function hook_path()
  local root = repo_root()
  if not root or root == "" then
    return nil
  end
  return root .. "/.git/hooks/prepare-commit-msg"
end

local function script_path()
  local rt = vim.api.nvim_get_runtime_file("scripts/nvime-commit-msg", false)[1]
  if rt and rt ~= "" then
    return vim.fn.fnamemodify(rt, ":p")
  end
  return nil
end

local function read_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil
  end
  return lines
end

local function write_file(path, lines, mode)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd, err = io.open(path, "w")
  if not fd then
    return false, err
  end
  for _, line in ipairs(lines) do
    fd:write(line .. "\n")
  end
  fd:close()
  if mode then
    local uv = vim.uv or vim.loop
    pcall(uv.fs_chmod, path, mode)
  end
  return true
end

local function ensure_executable(path)
  local uv = vim.uv or vim.loop
  pcall(uv.fs_chmod, path, tonumber("755", 8))
end

-- Public: install the prepare-commit-msg hook. Chains under any existing
-- hook the user has authored (existing first, nvime second).
function M.install()
  local hook = hook_path()
  if not hook then
    return false, "no git root"
  end
  local source = script_path()
  if not source then
    return false, "scripts/nvime-commit-msg not on runtimepath"
  end

  ensure_executable(source)

  local existing = read_file(hook) or {}
  -- Detect whether we already own the file; if so, reinstall in place.
  local owns_file = (#existing >= 2 and existing[2] == MARKER) or (#existing == 0)
  if owns_file then
    local lines = {
      "#!/usr/bin/env sh",
      MARKER,
      "exec " .. vim.fn.shellescape(source) .. ' "$@"',
    }
    local ok, err = write_file(hook, lines, tonumber("755", 8))
    if not ok then
      return false, err
    end
    return true
  end
  -- Chain: write a wrapper that calls existing first, then ours. We move
  -- the user's hook aside.
  local saved = hook .. ".nvime-prev"
  os.rename(hook, saved)
  ensure_executable(saved)
  local lines = {
    "#!/usr/bin/env sh",
    MARKER,
    "set -e",
    vim.fn.shellescape(saved) .. ' "$@"',
    "exec " .. vim.fn.shellescape(source) .. ' "$@"',
  }
  local ok, err = write_file(hook, lines, tonumber("755", 8))
  if not ok then
    return false, err
  end
  return true
end

function M.uninstall()
  local hook = hook_path()
  if not hook or vim.fn.filereadable(hook) ~= 1 then
    return true
  end
  local lines = read_file(hook) or {}
  if not (lines[2] and lines[2] == MARKER) then
    return false, "hook is not nvime-owned; leaving it alone"
  end
  vim.fn.delete(hook)
  local saved = hook .. ".nvime-prev"
  if vim.fn.filereadable(saved) == 1 then
    os.rename(saved, hook)
  end
  return true
end

function M.status()
  local hook = hook_path()
  if not hook then
    return { installed = false, reason = "no git root" }
  end
  if vim.fn.filereadable(hook) ~= 1 then
    return { installed = false, reason = "no hook present" }
  end
  local lines = read_file(hook) or {}
  local owned = lines[2] == MARKER
  return {
    installed = owned,
    hook_path = hook,
    chained = owned and vim.fn.filereadable(hook .. ".nvime-prev") == 1,
  }
end

M._marker = MARKER

return M
