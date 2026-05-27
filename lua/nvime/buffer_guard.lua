local M = {}

local function copy_lines(lines)
  local copy = {}
  for index, line in ipairs(lines or {}) do
    copy[index] = line
  end
  return copy
end

local function lines_equal(left, right)
  if #left ~= #right then
    return false
  end
  for index, line in ipairs(left) do
    if line ~= right[index] then
      return false
    end
  end
  return true
end

function M.sync(bufnr, panel)
  if not panel or panel.bufnr ~= bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  panel.guard_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

function M.suspend(bufnr, fn)
  local was_suspended = vim.b[bufnr].nvime_guard_suspended == true
  vim.b[bufnr].nvime_guard_suspended = true
  local ok, result = pcall(fn)
  vim.b[bufnr].nvime_guard_suspended = was_suspended
  if not ok then
    error(result)
  end
  return result
end

function M.enforce(opts)
  local panel = opts.panel()
  local bufnr = opts.bufnr
  if not panel or panel.bufnr ~= bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if panel.guard_restoring or vim.b[bufnr].nvime_guard_suspended == true then
    return
  end

  local baseline = panel.guard_lines
  if not baseline then
    M.sync(bufnr, panel)
    return
  end

  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local prompt_lnum = opts.prompt_lnum(panel)
  local prefix = opts.prompt_prefix()

  -- Protect scrollback (lines above the prompt) from modification.
  -- Lines from the prompt onward are the user's input area and may
  -- span multiple lines (multi-line paste).
  local scrollback_ok = true
  local scrollback_end = math.min(prompt_lnum - 1, #baseline, #current)
  for i = 1, scrollback_end do
    if current[i] ~= baseline[i] then
      scrollback_ok = false
      break
    end
  end
  if #current < prompt_lnum then
    scrollback_ok = false
  end

  local prompt_line = current[prompt_lnum] or ""
  if not vim.startswith(prompt_line, prefix) then
    scrollback_ok = false
  end

  if scrollback_ok then
    panel.guard_lines = copy_lines(current)
    if opts.decorate then
      opts.decorate(bufnr)
    end
    return
  end

  -- Scrollback was damaged — restore it but preserve the input area.
  local input_lines = {}
  if prompt_lnum <= #current then
    for i = prompt_lnum, #current do
      input_lines[#input_lines + 1] = current[i]
    end
  end
  local restored = copy_lines(baseline)
  if #input_lines > 0 and vim.startswith(input_lines[1] or "", prefix) then
    for i = #restored + 1, prompt_lnum - 1 do
      restored[i] = ""
    end
    for i = prompt_lnum, prompt_lnum + #input_lines - 1 do
      restored[i] = input_lines[i - prompt_lnum + 1]
    end
    while #restored > prompt_lnum + #input_lines - 1 do
      restored[#restored] = nil
    end
  end

  panel.guard_restoring = true
  M.suspend(bufnr, function()
    local readonly = vim.bo[bufnr].readonly
    local modifiable = vim.bo[bufnr].modifiable
    vim.bo[bufnr].readonly = false
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, restored)
    vim.bo[bufnr].modifiable = modifiable
    vim.bo[bufnr].readonly = readonly
  end)
  panel.guard_restoring = false
  panel.guard_lines = copy_lines(restored)

  if opts.decorate then
    opts.decorate(bufnr)
  end
  if opts.set_locked then
    opts.set_locked(bufnr, not opts.in_input_window(panel))
  end
end

function M.attach(opts)
  local bufnr = opts.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local key = opts.key or "nvime_guard_attached"
  if vim.b[bufnr][key] == true then
    M.sync(bufnr, opts.panel())
    return
  end
  vim.b[bufnr][key] = true

  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      local panel = opts.panel()
      if not panel or panel.bufnr ~= bufnr then
        return
      end
      if panel.guard_pending or panel.guard_restoring or vim.b[bufnr].nvime_guard_suspended == true then
        return
      end
      panel.guard_pending = true
      vim.schedule(function()
        panel.guard_pending = false
        M.enforce(opts)
      end)
    end,
    on_detach = function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.b[bufnr][key] = false
      end
    end,
  })

  M.sync(bufnr, opts.panel())
end

return M
