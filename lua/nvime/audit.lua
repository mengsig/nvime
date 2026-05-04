local state = require("nvime.state")

local M = {}

local function systemlist(cmd)
  local ok, result = pcall(vim.fn.systemlist, cmd)
  if not ok then
    return {}
  end
  return result or {}
end

local function git_root()
  local cwd = vim.loop.cwd()
  local result = systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 and result[1] and result[1] ~= "" then
    return result[1]
  end
  return nil
end

local function git_value(args)
  local root = git_root()
  if not root then
    return nil
  end
  local cmd = { "git", "-C", root }
  vim.list_extend(cmd, args)
  local result = systemlist(cmd)
  if vim.v.shell_error == 0 and result[1] and result[1] ~= "" then
    return result[1]
  end
  return nil
end

local function audit_path()
  local config = state.config or {}
  local audit = config.audit or {}
  if audit.path and audit.path ~= "" then
    return vim.fn.fnamemodify(audit.path, ":p")
  end

  local root = git_root()
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
  return copy
end

function M.path()
  return audit_path()
end

function M.write(event)
  local config = state.config or {}
  if config.audit and config.audit.enabled == false then
    return
  end

  event = redact(event or {})
  event.ts = event.ts or os.date("!%Y-%m-%dT%H:%M:%SZ")
  event.cwd = event.cwd or vim.loop.cwd()
  event.git_root = event.git_root or git_root()
  event.git_ref = event.git_ref or git_value({ "rev-parse", "--short", "HEAD" })
  event.git_branch = event.git_branch or git_value({ "branch", "--show-current" })
  event.nvim_pid = event.nvim_pid or vim.fn.getpid()

  local path = audit_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")

  local encoded = vim.json.encode(event)
  local fd = assert(io.open(path, "a"))
  fd:write(encoded)
  fd:write("\n")
  fd:close()
end

function M.open()
  vim.cmd.edit(vim.fn.fnameescape(audit_path()))
end

return M
