local audit = require("nvime.audit")
local state = require("nvime.state")

local M = {}

local blocked_bins = {
  claude = true,
  codex = true,
}

local dangerous_patterns = {
  "%-%-dangerously%-skip%-permissions",
  "%-%-allow%-dangerously%-skip%-permissions",
  "%-%-permission%-mode%s+bypassPermissions",
  "%-%-permission%-mode=bypassPermissions",
  "%-%-dangerously%-bypass%-approvals%-and%-sandbox",
  "%-%-sandbox%s+danger%-full%-access",
  "%-%-sandbox=danger%-full%-access",
  "%-s%s+danger%-full%-access",
}

local function flatten(cmd)
  if type(cmd) == "string" then
    return cmd
  end
  if type(cmd) == "table" then
    local parts = {}
    for _, part in ipairs(cmd) do
      parts[#parts + 1] = tostring(part)
    end
    return table.concat(parts, " ")
  end
  return tostring(cmd)
end

local function shell_words(cmd)
  if type(cmd) == "table" then
    return cmd
  end
  local words = {}
  for word in tostring(cmd):gmatch("%S+") do
    words[#words + 1] = word:gsub("^['\"]", ""):gsub("['\"]$", "")
  end
  return words
end

local function basename(value)
  value = tostring(value or "")
  value = value:gsub("^env$", "")
  return vim.fn.fnamemodify(value, ":t")
end

local function is_left_boundary(prev_char)
  return prev_char == "" or prev_char:match("[^%w_./-]") ~= nil
end

local function is_right_boundary(next_char)
  return next_char == "" or next_char:match("[^%w_-]") ~= nil
end

local function contains_bin(text, name)
  local start = 1
  while true do
    local i, j = text:find(name, start, true)
    if not i then
      return false
    end
    local prev_char = i > 1 and text:sub(i - 1, i - 1) or ""
    local next_char = j < #text and text:sub(j + 1, j + 1) or ""
    if is_left_boundary(prev_char) and is_right_boundary(next_char) then
      return true
    end
    start = j + 1
  end
end

function M.detect(cmd)
  local text = flatten(cmd)
  local words = shell_words(cmd)
  local bin = nil

  for _, word in ipairs(words) do
    local name = basename(word)
    if blocked_bins[name] then
      bin = name
      break
    end
  end

  if not bin then
    for name, _ in pairs(blocked_bins) do
      if contains_bin(text, name) then
        bin = name
        break
      end
    end
  end

  if not bin then
    return nil
  end

  local dangerous = nil
  for _, pattern in ipairs(dangerous_patterns) do
    if text:match(pattern) then
      dangerous = pattern
      break
    end
  end

  return {
    bin = bin,
    text = text,
    dangerous = dangerous,
  }
end

function M.should_block(cmd)
  local config = state.config or {}
  if not config.guard or config.guard.enabled == false then
    return false, nil
  end
  if state.trusted_depth > 0 then
    return false, nil
  end

  local detected = M.detect(cmd)
  if not detected then
    return false, nil
  end

  local reason = "direct " .. detected.bin .. " invocation must go through nvime"
  if detected.dangerous then
    reason = reason .. "; dangerous flag detected"
  end
  return true, reason, detected
end

local function notify_block(surface, reason)
  local config = state.config or {}
  if config.guard and config.guard.notify == false then
    return
  end
  vim.schedule(function()
    vim.notify("nvime blocked " .. surface .. ": " .. reason, vim.log.levels.WARN)
  end)
end

function M.record_block(surface, cmd, reason, detected)
  audit.write({
    event = "blocked",
    surface = surface,
    decision = "deny",
    reason = reason,
    tool = detected and detected.bin or nil,
    argv = flatten(cmd),
  })
  notify_block(surface, reason)
end

function M.with_trusted(fn)
  state.trusted_depth = state.trusted_depth + 1
  local ok, result, extra = pcall(fn)
  state.trusted_depth = state.trusted_depth - 1
  if not ok then
    error(result)
  end
  return result, extra
end

local function blocked_system_obj(reason, on_exit)
  local result = {
    code = 126,
    signal = 0,
    stdout = "",
    stderr = "nvime blocked command: " .. reason,
  }
  local obj = {
    pid = -1,
    wait = function()
      return result
    end,
    kill = function() end,
    write = function() end,
    is_closing = function()
      return true
    end,
  }
  if on_exit then
    vim.schedule(function()
      on_exit(result)
    end)
  end
  return obj
end

local function install_system_wrapper()
  if state.raw.vim_system or not vim.system then
    return
  end
  state.raw.vim_system = vim.system
  vim.system = function(cmd, opts, on_exit)
    local block, reason, detected = M.should_block(cmd)
    if block then
      M.record_block("vim.system", cmd, reason, detected)
      return blocked_system_obj(reason, on_exit)
    end
    return state.raw.vim_system(cmd, opts, on_exit)
  end
end

local function install_jobstart_wrapper()
  if state.raw.jobstart then
    return
  end
  state.raw.jobstart = vim.fn.jobstart
  vim.fn.jobstart = function(cmd, opts)
    local block, reason, detected = M.should_block(cmd)
    if block then
      M.record_block("jobstart", cmd, reason, detected)
      return -1
    end
    return state.raw.jobstart(cmd, opts)
  end
end

local function install_termopen_wrapper()
  if state.raw.termopen then
    return
  end
  state.raw.termopen = vim.fn.termopen
  vim.fn.termopen = function(cmd, opts)
    local block, reason, detected = M.should_block(cmd)
    if block then
      M.record_block("termopen", cmd, reason, detected)
      return -1
    end
    return state.raw.termopen(cmd, opts)
  end
end

local function install_system_function_wrappers()
  if state.raw.system then
    return
  end
  state.raw.system = vim.fn.system
  state.raw.systemlist = vim.fn.systemlist

  vim.fn.system = function(cmd, input)
    local block, reason, detected = M.should_block(cmd)
    if block then
      M.record_block("system", cmd, reason, detected)
      return "nvime blocked command: " .. reason
    end
    return state.raw.system(cmd, input)
  end

  vim.fn.systemlist = function(cmd, input)
    local block, reason, detected = M.should_block(cmd)
    if block then
      M.record_block("systemlist", cmd, reason, detected)
      return { "nvime blocked command: " .. reason }
    end
    return state.raw.systemlist(cmd, input)
  end
end

local function install_uv_wrapper()
  local uv = vim.uv or vim.loop
  if not uv or state.raw.uv_spawn then
    return
  end
  state.raw.uv_spawn = uv.spawn
  uv.spawn = function(path, opts, on_exit)
    local cmd = { path }
    if opts and opts.args then
      vim.list_extend(cmd, opts.args)
    end
    local block, reason, detected = M.should_block(cmd)
    if block then
      M.record_block("uv.spawn", cmd, reason, detected)
      return nil, "nvime blocked command: " .. reason, "EPERM"
    end
    return state.raw.uv_spawn(path, opts, on_exit)
  end
end

local function install_terminal_detector()
  local group = vim.api.nvim_create_augroup("NvimeGuard", { clear = true })
  vim.api.nvim_create_autocmd("TermOpen", {
    group = group,
    callback = function(args)
      local name = vim.api.nvim_buf_get_name(args.buf)
      local block, reason, detected = M.should_block(name)
      if not block then
        return
      end

      M.record_block("terminal", name, reason, detected)
      if state.config.guard.kill_blocked_terminals and vim.b[args.buf].terminal_job_id then
        pcall(vim.fn.jobstop, vim.b[args.buf].terminal_job_id)
        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(args.buf) then
            pcall(vim.api.nvim_buf_delete, args.buf, { force = true })
          end
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("CmdlineLeave", {
    group = group,
    callback = function()
      if not state.config.guard.block_cmdline then
        return
      end
      local line = vim.fn.getcmdline()
      if line == "" then
        return
      end
      local block, reason, detected = M.should_block(line)
      if block then
        M.record_block("cmdline", line, reason, detected)
        pcall(function()
          vim.v.event.abort = true
        end)
      end
    end,
  })
end

function M.install()
  if state.guard_installed then
    return
  end

  local guard = (state.config or {}).guard or {}
  if guard.wrap_vim_system then
    install_system_wrapper()
  end
  if guard.wrap_jobstart then
    install_jobstart_wrapper()
  end
  if guard.wrap_termopen then
    install_termopen_wrapper()
  end
  if guard.wrap_system_functions then
    install_system_function_wrappers()
  end
  if guard.wrap_uv_spawn then
    install_uv_wrapper()
  end
  install_terminal_detector()

  state.guard_installed = true
end

return M
