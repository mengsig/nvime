local git = require("nvime.git")
local state = require("nvime.state")

local M = {}

local GIT_CACHE_TTL = 30
local root_cache = {}
local ref_cache = {}

local function now()
  return os.time()
end

local function cached_git_root(cwd)
  cwd = cwd or vim.loop.cwd()
  local cached = root_cache[cwd]
  if cached and cached.expires_at > now() then
    return cached.value
  end
  local value = git.root(cwd)
  root_cache[cwd] = {
    value = value,
    expires_at = now() + GIT_CACHE_TTL,
  }
  return value
end

local function git_value(root, args)
  if not root then
    return nil
  end
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local result = git.systemlist(cmd)
  if vim.v.shell_error == 0 and result[1] and result[1] ~= "" then
    return result[1]
  end
  return nil
end

local function cached_git_meta(root)
  if not root then
    return nil, nil
  end
  local cached = ref_cache[root]
  if cached and cached.expires_at > now() then
    return cached.ref, cached.branch
  end
  local ref = git_value(root, { "rev-parse", "--short", "HEAD" })
  local branch = git_value(root, { "branch", "--show-current" })
  ref_cache[root] = {
    ref = ref,
    branch = branch,
    expires_at = now() + GIT_CACHE_TTL,
  }
  return ref, branch
end

local function audit_path()
  local config = state.config or {}
  local audit = config.audit or {}
  if audit.path and audit.path ~= "" then
    return vim.fn.fnamemodify(audit.path, ":p")
  end

  local root = cached_git_root(vim.loop.cwd())
  if root then
    return root .. "/.nvime/audit.jsonl"
  end

  return vim.fn.stdpath("state") .. "/nvime/audit.jsonl"
end

local function redact(event)
  if state.config and state.config.audit and state.config.audit.log_prompts then
    return event
  end

  local copy = vim.deepcopy(event)
  copy.prompt = nil
  copy.input = nil
  copy.response = nil
  if copy.argv then
    local tool = tostring(copy.tool or ""):match("%S+") or ""
    local tool_name = vim.fn.fnamemodify(tool, ":t")
    local argv = tostring(copy.argv)
    if tool_name == "claude" or tool_name == "codex" or argv:find("claude", 1, true) or argv:find("codex", 1, true) then
      copy.argv = (tool ~= "" and tool or (argv:match("^%S+") or "agent")) .. " [redacted]"
    end
  end
  return copy
end

local function disable_writes(reason)
  state.audit_write_disabled = true
  if state.audit_write_warned then
    return
  end
  state.audit_write_warned = true
  vim.schedule(function()
    vim.notify("nvime audit disabled for this session: " .. tostring(reason), vim.log.levels.WARN)
  end)
end

function M.path()
  return audit_path()
end

function M.clear_cache()
  root_cache = {}
  ref_cache = {}
end

function M.write(event)
  local config = state.config or {}
  if config.audit and config.audit.enabled == false then
    return
  end
  if state.audit_write_disabled then
    return
  end

  event = redact(event or {})
  event.ts = event.ts or os.date("!%Y-%m-%dT%H:%M:%SZ")
  event.cwd = event.cwd or vim.loop.cwd()
  event.git_root = event.git_root or cached_git_root(event.cwd)
  local git_ref, git_branch = cached_git_meta(event.git_root)
  event.git_ref = event.git_ref or git_ref
  event.git_branch = event.git_branch or git_branch
  event.nvim_pid = event.nvim_pid or vim.fn.getpid()

  local path = audit_path()
  local mkdir_ok, mkdir_err = pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
  if not mkdir_ok then
    disable_writes(mkdir_err)
    return
  end

  local encoded_ok, encoded = pcall(vim.json.encode, event)
  if not encoded_ok then
    disable_writes(encoded)
    return
  end

  local fd, open_err = io.open(path, "a")
  if not fd then
    disable_writes(open_err)
    return
  end

  local write_ok, write_err = pcall(function()
    local ok, err = fd:write(encoded)
    if not ok then
      error(err or "write failed")
    end
    ok, err = fd:write("\n")
    if not ok then
      error(err or "write failed")
    end
  end)
  local close_pcall_ok, closed, close_err = pcall(function()
    return fd:close()
  end)
  if not write_ok then
    disable_writes(write_err)
  elseif not close_pcall_ok then
    disable_writes(closed)
  elseif not closed then
    disable_writes(close_err)
  end
end

function M.open()
  vim.cmd.edit(vim.fn.fnameescape(audit_path()))
end

return M
