local state = require("nvime.state")

local M = {}

local ns = vim.api.nvim_create_namespace("nvime.diff.inline")

local function diff_config()
  return ((state.config or {}).diff or {})
end

local function max_visual_block_lines()
  return math.max(4, tonumber(diff_config().max_visual_block_lines) or 12)
end

local function split_lines(text)
  text = text or ""
  text = text:gsub("\r\n", "\n")
  local lines = vim.split(text, "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

local function strip_fence(text)
  local fenced = text:match("```[%w_-]*\n(.-)\n```")
  if fenced then
    return fenced
  end
  return text
end

local function has_fence(text)
  return (text or ""):match("```[%w_-]*\n.-\n```") ~= nil
end

local function trim(text)
  return vim.trim(text or "")
end

local function response_mode(text)
  text = text or ""
  local mode = text:match("^%s*(NVIME_[A-Z_]+)")
  if not mode then
    return nil, text
  end
  return mode, text:gsub("^%s*" .. mode .. "%s*", "", 1)
end

local function same_lines(left, right)
  if #left ~= #right then
    return false
  end
  for i = 1, #left do
    if left[i] ~= right[i] then
      return false
    end
  end
  return true
end

local function line_slice(lines, first, last)
  local out = {}
  for index = first, last do
    if lines[index] ~= nil then
      out[#out + 1] = lines[index]
    end
  end
  return out
end

local function extract_unified(text)
  local lines = split_lines(text)
  local start = nil
  for i, line in ipairs(lines) do
    if line:match("^diff %-%-git ") or line:match("^@@ ") or line:match("^%-%-%- ") then
      start = i
      break
    end
  end
  if not start then
    return nil
  end
  local out = {}
  for i = start, #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

local function parse_hunks(lines)
  local hunks = {}
  local current = nil
  local header = {}

  for _, line in ipairs(lines) do
    local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_start then
      current = {
        old_start = tonumber(old_start),
        old_count = tonumber(old_count ~= "" and old_count or "1"),
        new_start = tonumber(new_start),
        new_count = tonumber(new_count ~= "" and new_count or "1"),
        lines = { line },
        status = "pending",
      }
      hunks[#hunks + 1] = current
    elseif current then
      current.lines[#current.lines + 1] = line
    else
      header[#header + 1] = line
    end
  end

  return header, hunks
end

local function clean_diff_path(path)
  if not path then
    return nil
  end
  path = path:gsub('^"', ""):gsub('"$', "")
  path = path:gsub("^a/", ""):gsub("^b/", "")
  return path
end

local function validate_current_file(lines, expected)
  expected = clean_diff_path(expected)
  for _, line in ipairs(lines) do
    local a_path, b_path = line:match("^diff %-%-git a/(.-) b/(.+)$")
    if a_path and b_path then
      if clean_diff_path(a_path) ~= expected or clean_diff_path(b_path) ~= expected then
        return false, "agent proposed a diff outside the current file"
      end
    end

    local old_path = line:match("^%-%-%- (.+)$")
    if old_path and old_path ~= "/dev/null" and clean_diff_path(old_path) ~= expected then
      return false, "agent proposed a diff outside the current file"
    end

    local new_path = line:match("^%+%+%+ (.+)$")
    if new_path and new_path ~= "/dev/null" and clean_diff_path(new_path) ~= expected then
      return false, "agent proposed a diff outside the current file"
    end
  end
  return true, nil
end

local function hunk_old_new_lines(hunk)
  local old_lines = {}
  local new_lines = {}
  for i = 2, #hunk.lines do
    local line = hunk.lines[i]
    local prefix = line:sub(1, 1)
    if prefix == " " then
      old_lines[#old_lines + 1] = line:sub(2)
      new_lines[#new_lines + 1] = line:sub(2)
    elseif prefix == "-" then
      old_lines[#old_lines + 1] = line:sub(2)
    elseif prefix == "+" then
      new_lines[#new_lines + 1] = line:sub(2)
    end
  end
  return old_lines, new_lines
end

local function hunk_has_change(hunk)
  local old_lines, new_lines = hunk_old_new_lines(hunk)
  return not same_lines(old_lines, new_lines)
end

local function hunks_have_changes(hunks)
  for _, hunk in ipairs(hunks) do
    if hunk_has_change(hunk) then
      return true
    end
  end
  return false
end

local function group_summary(group)
  local first_id = group.blocks[1].id
  local last_id = group.blocks[#group.blocks].id
  local id_text = first_id == last_id and tostring(first_id) or (first_id .. "-" .. last_id)
  local old_total = 0
  local new_total = 0
  for _, block in ipairs(group.blocks) do
    old_total = old_total + block.old_count
    new_total = new_total + #block.new_lines
  end
  local range_text = group.first == group.last and ("line " .. group.first) or ("lines " .. group.first .. "-" .. group.last)
  local segment = ""
  if group.index and group.total and group.total > 1 then
    segment = string.format("block %d/%d  ", group.index, group.total)
  end
  return string.format("nvime %schange %s  %s  -%d +%d", segment, id_text, range_text, old_total, new_total)
end

local function parse_hunk_blocks(hunk, next_id)
  local blocks = {}
  local old_line = hunk.old_start
  local block = nil

  local function flush()
    if block and (#block.old_lines > 0 or #block.new_lines > 0) then
      local count = math.max(#block.old_lines, #block.new_lines)
      for index = 1, count do
        local old_line = block.old_lines[index]
        local new_line = block.new_lines[index]
        local old_start
        if old_line then
          old_start = block.old_start + index - 1
        elseif #block.old_lines == 0 then
          old_start = block.old_start
        else
          old_start = block.old_start + #block.old_lines
        end
        blocks[#blocks + 1] = {
          id = block.id + index - 1,
          old_start = old_start,
          old_lines = old_line and { old_line } or {},
          new_lines = new_line and { new_line } or {},
          old_count = old_line and 1 or 0,
          new_count = new_line and 1 or 0,
          status = "pending",
          hunk = hunk,
        }
      end
      next_id = next_id + count - 1
    end
    block = nil
  end

  local function ensure_block()
    if not block then
      block = {
        id = next_id,
        old_start = old_line,
        old_lines = {},
        new_lines = {},
      }
      next_id = next_id + 1
    end
    return block
  end

  for i = 2, #hunk.lines do
    local line = hunk.lines[i]
    local prefix = line:sub(1, 1)
    if prefix == " " then
      flush()
      old_line = old_line + 1
    elseif prefix == "-" then
      ensure_block().old_lines[#block.old_lines + 1] = line:sub(2)
      old_line = old_line + 1
    elseif prefix == "+" then
      ensure_block().new_lines[#block.new_lines + 1] = line:sub(2)
    end
  end
  flush()
  return blocks, next_id
end

local function build_blocks(session)
  local next_id = 1
  session.blocks = {}
  for _, hunk in ipairs(session.hunks) do
    local blocks
    blocks, next_id = parse_hunk_blocks(hunk, next_id)
    hunk.blocks = blocks
    for _, block in ipairs(blocks) do
      block.session = session
      session.blocks[#session.blocks + 1] = block
    end
  end
end

local function update_hunk_status(hunk)
  local pending = 0
  local accepted = 0
  local rejected = 0
  for _, block in ipairs(hunk.blocks or {}) do
    if block.status == "pending" then
      pending = pending + 1
    elseif block.status == "accepted" then
      accepted = accepted + 1
    elseif block.status == "rejected" then
      rejected = rejected + 1
    end
  end
  if pending > 0 then
    hunk.status = "pending"
  elseif accepted > 0 and rejected > 0 then
    hunk.status = "mixed"
  elseif accepted > 0 then
    hunk.status = "accepted"
  elseif rejected > 0 then
    hunk.status = "rejected"
  else
    hunk.status = "pending"
  end
end

local function target_line_count(session)
  return vim.api.nvim_buf_line_count(session.target_bufnr)
end

local function block_start_line(session, block)
  if block.mark_id then
    local mark = vim.api.nvim_buf_get_extmark_by_id(session.target_bufnr, ns, block.mark_id, {})
    if mark and mark[1] then
      return mark[1] + 1
    end
  end
  local offset = 0
  for _, applied in ipairs(session.applied) do
    if applied.old_start < block.old_start then
      offset = offset + applied.delta
    end
  end
  return block.old_start + offset
end

local function block_range(session, block)
  local start_line = block_start_line(session, block)
  local old_count = math.max(block.old_count, 1)
  return start_line, start_line + old_count - 1
end

local function current_file_window(bufnr)
  local fallback = nil
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
      fallback = fallback or winid
      if vim.api.nvim_win_get_config(winid).relative == "" then
        return winid
      end
    end
  end
  return fallback
end

local function focus_target(session)
  local winid = current_file_window(session.target_bufnr)
  if winid and vim.api.nvim_win_is_valid(winid) then
    vim.api.nvim_set_current_win(winid)
  else
    vim.api.nvim_set_current_buf(session.target_bufnr)
  end
end

local function install_buffer_maps(session)
  if session.maps_installed then
    return
  end
  session.maps_installed = true
  local opts = { buffer = session.target_bufnr, silent = true }
  vim.keymap.set("n", "]n", function()
    require("nvime.diff").next_change()
  end, opts)
  vim.keymap.set("n", "[n", function()
    require("nvime.diff").prev_change()
  end, opts)
  vim.keymap.set("n", "]b", function()
    require("nvime.diff").next_group()
  end, opts)
  vim.keymap.set("n", "[b", function()
    require("nvime.diff").prev_group()
  end, opts)
  vim.keymap.set("n", "ga", function()
    require("nvime.diff").accept_current_group()
  end, opts)
  vim.keymap.set("x", "ga", function()
    require("nvime.diff").accept_selection()
  end, opts)
  vim.keymap.set("n", "gb", function()
    require("nvime.diff").reject_current_group()
  end, opts)
  vim.keymap.set("x", "gb", function()
    require("nvime.diff").reject_selection()
  end, opts)
  vim.keymap.set("n", "gr", function()
    require("nvime.diff").reject_current()
  end, opts)
  vim.keymap.set("x", "gr", function()
    require("nvime.diff").reject_selection()
  end, opts)
  vim.keymap.set("n", "gA", function()
    require("nvime.diff").accept_all()
  end, opts)
  vim.keymap.set("n", "gB", function()
    require("nvime.diff").reject_all()
  end, opts)
  vim.keymap.set("n", "gR", function()
    require("nvime.diff").reject_all()
  end, opts)
  vim.keymap.set("n", "gX", function()
    require("nvime.diff").reject_current_group()
  end, opts)
  vim.keymap.set("n", "gc", function()
    require("nvime.edit").continue_remaining()
  end, opts)
end

local function block_visual_size(block)
  return math.max(block.old_count or 0, #(block.new_lines or {}), 1)
end

local function block_lines(block)
  local lines = {}
  for _, line in ipairs(block.old_lines or {}) do
    lines[#lines + 1] = line
  end
  for _, line in ipairs(block.new_lines or {}) do
    lines[#lines + 1] = line
  end
  return lines
end

local function block_has_blank_line(block)
  for _, line in ipairs(block_lines(block)) do
    if vim.trim(line) == "" then
      return true
    end
  end
  return false
end

local function first_nonblank_line(block)
  for _, line in ipairs(block_lines(block)) do
    if vim.trim(line) ~= "" then
      return line
    end
  end
  return ""
end

local function indent_width(line)
  local indent = (line or ""):match("^%s*") or ""
  return #indent
end

local function starts_section(block, base_indent)
  local line = first_nonblank_line(block)
  if line == "" then
    return false
  end
  local trimmed = vim.trim(line)
  if trimmed:match("^[%}%]%)]") then
    return true
  end
  return base_indent ~= nil and indent_width(line) <= base_indent
end

local function pending_visual_groups(session)
  local groups = {}
  local current = nil
  local blocks = {}
  for _, block in ipairs(session.blocks or {}) do
    if block.status == "pending" then
      blocks[#blocks + 1] = block
    end
  end
  table.sort(blocks, function(a, b)
    local a_line = block_start_line(session, a)
    local b_line = block_start_line(session, b)
    if a_line == b_line then
      return a.id < b.id
    end
    return a_line < b_line
  end)

  for _, block in ipairs(blocks) do
    local first, last = block_range(session, block)
    local size = block_visual_size(block)
    local max_size = max_visual_block_lines()
    local soft_size = math.max(4, math.floor(max_size * 0.65))
    local starts_new =
      not current
      or block.hunk ~= current.hunk
      or first > current.last + 1
      or current.size >= max_size
      or (current.size >= soft_size and (current.last_boundary or starts_section(block, current.base_indent)))

    if starts_new then
      current = {
        hunk = block.hunk,
        blocks = {},
        first = first,
        last = last,
        size = 0,
        base_indent = indent_width(first_nonblank_line(block)),
        last_boundary = false,
      }
      groups[#groups + 1] = current
    end
    current.blocks[#current.blocks + 1] = block
    current.first = math.min(current.first, first)
    current.last = math.max(current.last, last)
    current.size = current.size + size
    current.last_boundary = block_has_blank_line(block)
    local line = first_nonblank_line(block)
    if line ~= "" then
      current.base_indent = math.min(current.base_indent or indent_width(line), indent_width(line))
    end
  end
  for index, group in ipairs(groups) do
    group.index = index
    group.total = #groups
  end
  session.visual_groups = groups
  return groups
end

local function render_visual_group(session, group)
  local start_line = group.first
  local count = target_line_count(session)
  local anchor_row = math.max(0, math.min(start_line - 1, math.max(0, count - 1)))
  local virt_above = group.first <= count
  local new_lines = {}
  local old_line_rows = {}
  local has_old_lines = false

  local virt_lines = {
    { { group_summary(group), "NvimeDiffHunk" } },
    {
      {
        "  ]b/[b block  ga accept block  gA accept all  gb reject block  gB reject all  gc discuss",
        "NvimeMuted",
      },
    },
  }

  for _, block in ipairs(group.blocks) do
    for _, line in ipairs(block.new_lines) do
      new_lines[#new_lines + 1] = line
    end
    if block.old_count > 0 then
      has_old_lines = true
      local block_line = block_start_line(session, block)
      for i = 0, block.old_count - 1 do
        old_line_rows[#old_line_rows + 1] = block_line + i
      end
    end
  end

  if #new_lines > 0 then
    virt_lines[#virt_lines + 1] = { { "  proposed", "NvimeMuted" } }
  else
    virt_lines[#virt_lines + 1] = { { "  proposed: remove the highlighted line(s)", "NvimeMuted" } }
  end
  for _, line in ipairs(new_lines) do
    virt_lines[#virt_lines + 1] = { { "+ " .. line, "NvimeDiffAdd" } }
  end
  if has_old_lines then
    virt_lines[#virt_lines + 1] = { { "  current", "NvimeMuted" } }
  else
    virt_lines[#virt_lines + 1] = { { "  insertion point below", "NvimeMuted" } }
  end

  for _, line in ipairs(old_line_rows) do
    local row = line - 1
    if row >= 0 and row < count then
      vim.api.nvim_buf_set_extmark(session.target_bufnr, ns, row, 0, {
        line_hl_group = "NvimeDiffDelete",
      })
    end
  end

  for _, block in ipairs(group.blocks) do
    local row = math.max(0, math.min(block_start_line(session, block) - 1, count))
    block.mark_id = vim.api.nvim_buf_set_extmark(session.target_bufnr, ns, row, 0, {
      id = block.mark_id,
      right_gravity = false,
    })
  end

  group.mark_id = vim.api.nvim_buf_set_extmark(session.target_bufnr, ns, anchor_row, 0, {
    id = group.mark_id,
    right_gravity = false,
    virt_lines = virt_lines,
    virt_lines_above = virt_above,
  })
end

local function render_session(session)
  if not session.blocks then
    build_blocks(session)
  end
  vim.api.nvim_buf_clear_namespace(session.target_bufnr, ns, 0, -1)
  install_buffer_maps(session)
  focus_target(session)

  for _, hunk in ipairs(session.hunks) do
    update_hunk_status(hunk)
  end
  for _, group in ipairs(pending_visual_groups(session)) do
    render_visual_group(session, group)
  end

  local pending = 0
  for _, block in ipairs(session.blocks) do
    if block.status == "pending" then
      pending = pending + 1
    end
  end
  if pending == 0 then
    vim.notify("nvime diff: all proposed changes resolved", vim.log.levels.INFO)
  else
    vim.notify(
      "nvime diff: "
        .. pending
        .. " unresolved line change(s). Use ]b/[b to move, ga/gA to accept, gb/gB to reject, gc discuss.",
      vim.log.levels.INFO
    )
  end
end

local function build_single_hunk(selection, replacement_text)
  local original = vim.api.nvim_buf_get_lines(selection.bufnr, selection.line1 - 1, selection.line2, false)
  local replacement = split_lines(strip_fence(replacement_text))
  if same_lines(original, replacement) then
    return nil, "agent returned the same code; no change needed"
  end

  local prefix = 0
  while prefix < #original and prefix < #replacement and original[prefix + 1] == replacement[prefix + 1] do
    prefix = prefix + 1
  end

  local suffix = 0
  while suffix < (#original - prefix)
    and suffix < (#replacement - prefix)
    and original[#original - suffix] == replacement[#replacement - suffix]
  do
    suffix = suffix + 1
  end

  local changed_original = line_slice(original, prefix + 1, #original - suffix)
  local changed_replacement = line_slice(replacement, prefix + 1, #replacement - suffix)
  local old_count = #changed_original
  local new_count = #changed_replacement
  local start_line = selection.line1 + prefix
  local lines = {
    "--- a/" .. selection.path,
    "+++ b/" .. selection.path,
    string.format("@@ -%d,%d +%d,%d @@", start_line, old_count, start_line, new_count),
  }

  for _, line in ipairs(changed_original) do
    lines[#lines + 1] = "-" .. line
  end
  for _, line in ipairs(changed_replacement) do
    lines[#lines + 1] = "+" .. line
  end

  return lines
end

function M.start_session(selection, response, provider, prompt)
  local mode, body = response_mode(response)
  body = body or response

  if mode == "NVIME_NO_CHANGE" then
    return {
      status = "no_change",
      message = trim(body) ~= "" and trim(body) or "agent reported no change needed",
    }
  end

  local diff_lines = extract_unified(body)
  if not diff_lines then
    if not mode and not has_fence(body) then
      return {
        status = "no_change",
        message = "agent answered without returning a patch",
      }
    end
    local no_change_reason
    diff_lines, no_change_reason = build_single_hunk(selection, body)
    if not diff_lines then
      return {
        status = "no_change",
        message = no_change_reason,
      }
    end
  end

  local valid, validation_error = validate_current_file(diff_lines, selection.path)
  if not valid then
    error(validation_error)
  end

  local header, hunks = parse_hunks(diff_lines)
  if #hunks == 0 then
    error("nvime could not find any hunks in the proposed diff")
  end
  if not hunks_have_changes(hunks) then
    return {
      status = "no_change",
      message = "agent returned a diff with no changed lines",
    }
  end

  local session = {
    file = selection.path,
    bufnr = nil,
    target_bufnr = selection.bufnr,
    selection = selection,
    header = header,
    hunks = hunks,
    provider = provider,
    prompt = prompt,
    applied = {},
  }
  state.current_diff = session
  render_session(session)
  return {
    status = "diff",
    session = session,
  }
end

local function selected_lines()
  local mode = vim.fn.mode()
  if mode == "v" or mode == "V" or mode == "\22" then
    local anchor = vim.fn.getpos("v")[2]
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    if anchor and anchor > 0 and cursor and cursor > 0 then
      if anchor > cursor then
        anchor, cursor = cursor, anchor
      end
      vim.cmd.normal({ args = { "\27" }, bang = true })
      return anchor, cursor
    end
  end
  local start_line = vim.fn.line("'<")
  local end_line = vim.fn.line("'>")
  if start_line > end_line then
    start_line, end_line = end_line, start_line
  end
  if start_line > 0 and end_line > 0 then
    return start_line, end_line
  end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return line, line
end

local function pending_blocks(session)
  local blocks = {}
  for _, block in ipairs(session.blocks or {}) do
    if block.status == "pending" then
      blocks[#blocks + 1] = block
    end
  end
  table.sort(blocks, function(a, b)
    return block_start_line(session, a) < block_start_line(session, b)
  end)
  return blocks
end

local function blocks_in_range(session, first, last)
  local blocks = {}
  for _, block in ipairs(pending_blocks(session)) do
    local block_first, block_last = block_range(session, block)
    if block_first <= last and block_last >= first then
      blocks[#blocks + 1] = block
    end
  end
  return blocks
end

local function current_block(session)
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local blocks = blocks_in_range(session, line, line)
  if blocks[1] then
    return blocks[1]
  end

  local best = nil
  local best_distance = nil
  for _, block in ipairs(pending_blocks(session)) do
    local first, last = block_range(session, block)
    local distance
    if line < first then
      distance = first - line
    elseif line > last then
      distance = line - last
    else
      distance = 0
    end
    if not best_distance or distance < best_distance then
      best = block
      best_distance = distance
    end
  end
  return best
end

local function current_group(session)
  local block = current_block(session)
  if not block then
    return nil
  end
  for _, group in ipairs(pending_visual_groups(session)) do
    for _, group_block in ipairs(group.blocks) do
      if group_block == block then
        return group
      end
    end
  end
  return nil
end

local function apply_block(session, block, start_line_override)
  if not block or block.status ~= "pending" then
    return 0
  end
  local replacement = block.new_lines
  local start_line = start_line_override or block_start_line(session, block)
  local start_index = math.max(0, math.min(start_line - 1, target_line_count(session)))
  local end_index = math.max(start_index, math.min(start_index + block.old_count, target_line_count(session)))
  vim.api.nvim_buf_set_lines(
    session.target_bufnr,
    start_index,
    end_index,
    false,
    replacement
  )
  block.status = "accepted"
  session.applied[#session.applied + 1] = {
    old_start = block.old_start,
    delta = #block.new_lines - block.old_count,
  }
  update_hunk_status(block.hunk)
  return #block.new_lines - block.old_count
end

local function reject_block(block)
  if block and block.status == "pending" then
    block.status = "rejected"
    update_hunk_status(block.hunk)
  end
end

function M.accept_blocks(blocks)
  local session = state.current_diff
  if not session then
    vim.notify("No active nvime diff session", vim.log.levels.WARN)
    return
  end
  if not blocks or #blocks == 0 then
    vim.notify("No pending nvime line change selected", vim.log.levels.WARN)
    return
  end

  local plan = {}
  for _, block in ipairs(blocks) do
    if block and block.status == "pending" then
      plan[#plan + 1] = {
        block = block,
        start_line = block_start_line(session, block),
      }
    end
  end
  table.sort(plan, function(a, b)
    if a.start_line == b.start_line then
      return a.block.id < b.block.id
    end
    return a.start_line < b.start_line
  end)
  local offset = 0
  for _, item in ipairs(plan) do
    offset = offset + apply_block(session, item.block, item.start_line + offset)
  end
  render_session(session)
end

function M.reject_blocks(blocks)
  local session = state.current_diff
  if not session then
    vim.notify("No active nvime diff session", vim.log.levels.WARN)
    return
  end
  if not blocks or #blocks == 0 then
    vim.notify("No pending nvime line change selected", vim.log.levels.WARN)
    return
  end

  for _, block in ipairs(blocks) do
    reject_block(block)
  end
  render_session(session)
end

function M.accept_hunks(hunks)
  local session = state.current_diff
  if not session then
    vim.notify("No active nvime diff session", vim.log.levels.WARN)
    return
  end
  if not hunks or #hunks == 0 then
    vim.notify("No diff hunk selected", vim.log.levels.WARN)
    return
  end

  local blocks = {}
  for _, hunk in ipairs(hunks) do
    for _, block in ipairs(hunk.blocks or {}) do
      if block.status == "pending" then
        blocks[#blocks + 1] = block
      end
    end
  end
  M.accept_blocks(blocks)
end

function M.reject_hunks(hunks)
  local session = state.current_diff
  if not session or not hunks or #hunks == 0 then
    return
  end
  local blocks = {}
  for _, hunk in ipairs(hunks) do
    for _, block in ipairs(hunk.blocks or {}) do
      if block.status == "pending" then
        blocks[#blocks + 1] = block
      end
    end
  end
  M.reject_blocks(blocks)
end

function M.accept_current()
  local session = state.current_diff
  if not session then
    return
  end
  M.accept_blocks({ current_block(session) })
end

function M.accept_selection()
  local session = state.current_diff
  if not session then
    return
  end
  local first, last = selected_lines()
  M.accept_blocks(blocks_in_range(session, first, last))
end

function M.reject_current()
  local session = state.current_diff
  if not session then
    return
  end
  M.reject_blocks({ current_block(session) })
end

function M.reject_selection()
  local session = state.current_diff
  if not session then
    return
  end
  local first, last = selected_lines()
  M.reject_blocks(blocks_in_range(session, first, last))
end

function M.accept_current_group()
  local session = state.current_diff
  if not session then
    return
  end
  local group = current_group(session)
  if not group then
    vim.notify("No pending nvime change block selected", vim.log.levels.WARN)
    return
  end
  M.accept_blocks(group.blocks)
end

function M.reject_current_group()
  local session = state.current_diff
  if not session then
    return
  end
  local group = current_group(session)
  if not group then
    vim.notify("No pending nvime change block selected", vim.log.levels.WARN)
    return
  end
  M.reject_blocks(group.blocks)
end

function M.accept_all()
  local session = state.current_diff
  if not session then
    return
  end
  M.accept_blocks(pending_blocks(session))
end

function M.reject_all()
  local session = state.current_diff
  if not session then
    return
  end
  M.reject_blocks(pending_blocks(session))
end

local function jump_to_block(session, block)
  if not block then
    vim.notify("No unresolved nvime line change", vim.log.levels.INFO)
    return
  end
  focus_target(session)
  local line = math.max(1, math.min(block_start_line(session, block), target_line_count(session)))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end

local function jump_to_group(session, group)
  if not group then
    vim.notify("No unresolved nvime change block", vim.log.levels.INFO)
    return
  end
  focus_target(session)
  local line = math.max(1, math.min(group.first, target_line_count(session)))
  vim.api.nvim_win_set_cursor(0, { line, 0 })
end

function M.next_change()
  local session = state.current_diff
  if not session then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local blocks = pending_blocks(session)
  for _, block in ipairs(blocks) do
    if block_start_line(session, block) > cursor then
      jump_to_block(session, block)
      return
    end
  end
  jump_to_block(session, blocks[1])
end

function M.next_group()
  local session = state.current_diff
  if not session then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local groups = pending_visual_groups(session)
  for _, group in ipairs(groups) do
    if group.first > cursor then
      jump_to_group(session, group)
      return
    end
  end
  jump_to_group(session, groups[1])
end

function M.prev_change()
  local session = state.current_diff
  if not session then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local blocks = pending_blocks(session)
  for index = #blocks, 1, -1 do
    local block = blocks[index]
    if block_start_line(session, block) < cursor then
      jump_to_block(session, block)
      return
    end
  end
  jump_to_block(session, blocks[#blocks])
end

function M.prev_group()
  local session = state.current_diff
  if not session then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local groups = pending_visual_groups(session)
  for index = #groups, 1, -1 do
    local group = groups[index]
    if group.first < cursor then
      jump_to_group(session, group)
      return
    end
  end
  jump_to_group(session, groups[#groups])
end

local function block_state_lines(label, blocks)
  local lines = { label }
  if #blocks == 0 then
    lines[#lines + 1] = "(none)"
    return lines
  end
  for _, block in ipairs(blocks) do
    lines[#lines + 1] = string.format(
      "line %d (%s) at original line %d:",
      block.id,
      block.status,
      block.old_start
    )
    lines[#lines + 1] = "```diff"
    for _, line in ipairs(block.old_lines) do
      lines[#lines + 1] = "-" .. line
    end
    for _, line in ipairs(block.new_lines) do
      lines[#lines + 1] = "+" .. line
    end
    lines[#lines + 1] = "```"
  end
  return lines
end

function M.remaining_text()
  local session = state.current_diff
  if not session then
    return nil
  end
  local current = current_block(session)
  local accepted = {}
  local rejected = {}
  local pending = {}
  for _, block in ipairs(session.blocks or {}) do
    if block.status == "accepted" then
      accepted[#accepted + 1] = block
    elseif block.status == "rejected" then
      rejected[#rejected + 1] = block
    elseif block.status == "pending" then
      pending[#pending + 1] = block
    end
  end

  local lines = {}
  lines[#lines + 1] = "NVIME_DIFF_REVIEW_STATE"
  lines[#lines + 1] = "File: " .. session.file
  lines[#lines + 1] = "Original prompt:"
  lines[#lines + 1] = session.prompt or "(empty)"
  lines[#lines + 1] = ""
  if current then
    vim.list_extend(lines, block_state_lines("Current unresolved line:", { current }))
    lines[#lines + 1] = ""
  end
  vim.list_extend(lines, block_state_lines("Accepted lines:", accepted))
  lines[#lines + 1] = ""
  vim.list_extend(lines, block_state_lines("Rejected lines:", rejected))
  lines[#lines + 1] = ""
  vim.list_extend(lines, block_state_lines("Unresolved lines:", pending))
  return table.concat(lines, "\n")
end

return M
