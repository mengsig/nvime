local audit = require("nvime.audit")
local state = require("nvime.state")
local ui = require("nvime.ui")

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

local function count_pattern(text, pattern)
  if type(text) ~= "string" or text == "" then
    return 0
  end
  local _, n = text:gsub(pattern, "")
  return n
end

local function bracket_balance(lines)
  local text = table.concat(lines or {}, "\n")
  return {
    brace = count_pattern(text, "{") - count_pattern(text, "}"),
    paren = count_pattern(text, "%(") - count_pattern(text, "%)"),
    bracket = count_pattern(text, "%[") - count_pattern(text, "%]"),
  }
end

local function bracket_drift(before, after)
  before = before or {}
  after = after or {}
  return {
    brace = (after.brace or 0) - (before.brace or 0),
    paren = (after.paren or 0) - (before.paren or 0),
    bracket = (after.bracket or 0) - (before.bracket or 0),
  }
end

local function has_bracket_drift(drift)
  return drift and (drift.brace ~= 0 or drift.paren ~= 0 or drift.bracket ~= 0)
end

local function bracket_drift_summary(drift)
  if not drift then
    return nil
  end
  local parts = {}
  if drift.brace ~= 0 then
    parts[#parts + 1] = string.format("{}: %+d", drift.brace)
  end
  if drift.paren ~= 0 then
    parts[#parts + 1] = string.format("(): %+d", drift.paren)
  end
  if drift.bracket ~= 0 then
    parts[#parts + 1] = string.format("[]: %+d", drift.bracket)
  end
  if #parts == 0 then
    return nil
  end
  return table.concat(parts, "  ")
end

local function response_likely_truncated(response)
  if type(response) ~= "string" or response == "" then
    return false
  end
  local first_marker = response:find("NVIME_[A-Z_]+")
  if not first_marker then
    return false
  end
  local tail = response:sub(first_marker)
  local fence_count = 0
  local search_pos = 1
  while true do
    local s = tail:find("```", search_pos, true)
    if not s then
      break
    end
    fence_count = fence_count + 1
    search_pos = s + 3
  end
  if fence_count == 0 then
    return false
  end
  return fence_count % 2 == 1
end

local function fence_marker(line)
  local marker, rest = (line or ""):match("^%s*([`~]+)(.*)$")
  if not marker or #marker < 3 then
    return nil
  end
  local char = marker:sub(1, 1)
  if marker ~= string.rep(char, #marker) then
    return nil
  end
  if rest ~= "" and not rest:match("^%s*[%w_-]*%s*$") then
    return nil
  end
  return marker
end

local function closing_fence_marker(line, opening)
  local marker, rest = (line or ""):match("^%s*([`~]+)(.*)$")
  if not marker or rest:match("%S") then
    return false
  end
  local char = opening:sub(1, 1)
  return marker == string.rep(char, #marker) and #marker >= #opening
end

local function fenced_body(text)
  local lines = split_lines(text)
  local open_index = nil
  local opening = nil
  for index, line in ipairs(lines) do
    if line:match("%S") then
      opening = fence_marker(line)
      if not opening then
        return nil
      end
      open_index = index
      break
    end
  end
  if not open_index or not opening then
    return nil
  end
  for index = open_index + 1, #lines do
    if closing_fence_marker(lines[index], opening) then
      local body = {}
      for body_index = open_index + 1, index - 1 do
        body[#body + 1] = lines[body_index]
      end
      return table.concat(body, "\n")
    end
  end
  return nil
end

local function strip_fence(text)
  local fenced = fenced_body(text)
  if fenced then
    return fenced
  end
  return text
end

local function has_fence(text)
  return fenced_body(text) ~= nil
end

local function trim(text)
  return vim.trim(text or "")
end

local function normalize_mode_boundaries(text)
  return (text or ""):gsub("([`~][`~][`~]+)(NVIME_[A-Z_]+)", "%1\n%2")
end

local RESPONSE_MODES = {
  NVIME_NO_CHANGE = true,
  NVIME_REPLACEMENT = true,
  NVIME_DIFF = true,
}

local function response_mode(text)
  text = normalize_mode_boundaries(text)
  local lines = split_lines(text)
  for index, line in ipairs(lines) do
    local mode, rest = line:match("^%s*(NVIME_[A-Z_]+)%s*(.*)$")
    if mode and RESPONSE_MODES[mode] then
      local body = {}
      rest = vim.trim(rest or "")
      if rest ~= "" then
        body[#body + 1] = rest
      end
      for body_index = index + 1, #lines do
        body[#body + 1] = lines[body_index]
      end
      return mode, table.concat(body, "\n")
    end
  end
  return nil, text
end

local function fenced_diff_body(text)
  local lines = split_lines(normalize_mode_boundaries(text))
  for index, line in ipairs(lines) do
    local marker, lang = line:match("^%s*([`~][`~][`~]+)%s*([%w_-]*)%s*$")
    if marker and (lang == "" or lang == "diff" or lang == "patch") then
      for close_index = index + 1, #lines do
        if closing_fence_marker(lines[close_index], marker) then
          local body = {}
          for body_index = index + 1, close_index - 1 do
            body[#body + 1] = lines[body_index]
          end
          return table.concat(body, "\n")
        end
      end
    end
  end
  return nil
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

local function copy_lines(lines)
  local out = {}
  for _, line in ipairs(lines or {}) do
    out[#out + 1] = line
  end
  return out
end

local function is_unresolved(block)
  return block and (block.status == "pending" or block.status == "conflict")
end

local function extract_unified(text)
  text = normalize_mode_boundaries(text)
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
    if i > start and lines[i]:match("^%s*NVIME_[A-Z_]+%s*$") then
      break
    end
    out[#out + 1] = lines[i]
  end
  return out
end

local function has_ranged_hunk(lines)
  for _, line in ipairs(lines or {}) do
    if line:match("^@@ %-%d+,?%d* %+%d+,?%d* @@") then
      return true
    end
  end
  return false
end

local function locate_sequence(haystack, needle)
  if #needle == 0 then
    return 1
  end
  if #needle > #haystack then
    return nil
  end
  for start = 1, #haystack - #needle + 1 do
    local matched = true
    for offset = 1, #needle do
      if haystack[start + offset - 1] ~= needle[offset] then
        matched = false
        break
      end
    end
    if matched then
      return start
    end
  end
  return nil
end

local function unranged_diff_lines(text)
  local lines = split_lines(strip_fence(text))
  local out = {}
  local saw_marker = false
  for _, line in ipairs(lines) do
    if line:match("^@@%s*$") or line:match("^@@ .*$") then
      saw_marker = true
    elseif line:match("^%-%-%- ") or line:match("^%+%+%+ ") or line:match("^diff %-%-git ") then
      -- Ignore incomplete file headers; nvime will rebuild them for the current file.
    elseif line:sub(1, 1) == " " or line:sub(1, 1) == "-" or line:sub(1, 1) == "+" then
      saw_marker = true
      out[#out + 1] = line
    elseif saw_marker and vim.trim(line) == "" then
      out[#out + 1] = " "
    end
  end
  return out
end

local function build_unranged_hunk(selection, text)
  local diff_body = unranged_diff_lines(text)
  if #diff_body == 0 then
    return nil, "agent returned NVIME_DIFF without a unified diff"
  end

  local old_lines = {}
  local new_lines = {}
  local saw_change = false
  for _, line in ipairs(diff_body) do
    local prefix = line:sub(1, 1)
    local value = line:sub(2)
    if prefix == " " then
      old_lines[#old_lines + 1] = value
      new_lines[#new_lines + 1] = value
    elseif prefix == "-" then
      old_lines[#old_lines + 1] = value
      saw_change = true
    elseif prefix == "+" then
      new_lines[#new_lines + 1] = value
      saw_change = true
    end
  end
  if not saw_change then
    return nil, "agent returned a diff with no changed lines"
  end

  local selected = vim.api.nvim_buf_get_lines(selection.bufnr, selection.line1 - 1, selection.line2, false)
  local offset = locate_sequence(selected, old_lines)
  if not offset then
    return nil, "agent returned an unranged diff that could not be anchored in the selected range"
  end

  local start_line = selection.line1 + offset - 1
  local hunk = {
    "--- a/" .. selection.path,
    "+++ b/" .. selection.path,
    string.format("@@ -%d,%d +%d,%d @@", start_line, #old_lines, start_line, #new_lines),
  }
  vim.list_extend(hunk, diff_body)
  return hunk
end

local function parse_hunks(lines)
  -- Be lenient about hunk @@ counts. Both Claude and Codex regularly miscount
  -- +new_count when emitting many added lines (off by 1-2). The previous
  -- strict count enforcement silently truncated the body, which corrupted
  -- the patched file. We now keep counting for context tracking but only
  -- close the hunk on a clear file-level/response terminator, or on a fence
  -- marker AFTER the declared counts have been met (so a fence appearing as
  -- content is treated as a context line).
  local hunks = {}
  local current = nil
  local header = {}
  local old_seen = 0
  local new_seen = 0

  local function recount(hunk)
    local olds, news = 0, 0
    for i = 2, #hunk.lines do
      local prefix = hunk.lines[i]:sub(1, 1)
      if prefix == " " or prefix == "-" then
        olds = olds + 1
      end
      if prefix == " " or prefix == "+" then
        news = news + 1
      end
    end
    -- Replace the declared counts with what we actually consumed; this makes
    -- a miscounted header from the agent harmless.
    if olds > 0 or news > 0 then
      hunk.old_count = olds
      hunk.new_count = news
    end
  end

  for _, line in ipairs(lines) do
    local old_start, old_count, new_start, new_count = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if old_start then
      if current then
        recount(current)
      end
      current = {
        old_start = tonumber(old_start),
        old_count = tonumber(old_count ~= "" and old_count or "1"),
        new_start = tonumber(new_start),
        new_count = tonumber(new_count ~= "" and new_count or "1"),
        lines = { line },
        status = "pending",
      }
      hunks[#hunks + 1] = current
      old_seen = 0
      new_seen = 0
    elseif current then
      local prefix = line:sub(1, 1)
      local old_done = old_seen >= current.old_count
      local new_done = new_seen >= current.new_count
      local is_file_header = line:match("^diff %-%-git ")
        or line:match("^%-%-%- [ab]/")
        or line:match("^%+%+%+ [ab]/")
        or line:match("^%-%-%- /dev/null")
        or line:match("^%+%+%+ /dev/null")
        or line:match("^%s*NVIME_[A-Z_]+%s*$")
        or ((old_done and new_done) and fence_marker(line))
      if is_file_header then
        recount(current)
        current = nil
      elseif prefix == " " or prefix == "-" or prefix == "+" or prefix == "\\" then
        current.lines[#current.lines + 1] = line
        if prefix == " " or prefix == "-" then
          old_seen = old_seen + 1
        end
        if prefix == " " or prefix == "+" then
          new_seen = new_seen + 1
        end
      else
        current.lines[#current.lines + 1] = " " .. line
        old_seen = old_seen + 1
        new_seen = new_seen + 1
      end
    else
      header[#header + 1] = line
    end
  end

  if current then
    recount(current)
  end

  return header, hunks
end

local function dedupe_hunks(hunks)
  local out = {}
  local seen = {}
  for _, hunk in ipairs(hunks or {}) do
    local key = table.concat({
      tostring(hunk.old_start),
      tostring(hunk.old_count),
      tostring(hunk.new_start),
      tostring(hunk.new_count),
      table.concat(hunk.lines or {}, "\n"),
    }, "\0")
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = hunk
    end
  end
  return out
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

local function sequence_at(lines, start, needle)
  if start < 1 or #needle == 0 or start + #needle - 1 > #lines then
    return false
  end
  for index = 1, #needle do
    if lines[start + index - 1] ~= needle[index] then
      return false
    end
  end
  return true
end

local function reanchor_hunks(selection, hunks)
  local all_lines = vim.api.nvim_buf_get_lines(selection.bufnr, 0, -1, false)
  local selected = vim.api.nvim_buf_get_lines(selection.bufnr, selection.line1 - 1, selection.line2, false)
  for _, hunk in ipairs(hunks or {}) do
    local old_lines = hunk_old_new_lines(hunk)
    if #old_lines > 0 and not sequence_at(all_lines, hunk.old_start, old_lines) then
      local offset = locate_sequence(selected, old_lines)
      local start_line = offset and (selection.line1 + offset - 1) or locate_sequence(all_lines, old_lines)
      if start_line then
        hunk.old_start = start_line
        hunk.new_start = start_line
      end
    end
  end
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
  local has_conflict = false
  for _, block in ipairs(group.blocks) do
    old_total = old_total + block.old_count
    new_total = new_total + #block.new_lines
    has_conflict = has_conflict or block.status == "conflict"
  end
  local range_text = group.first == group.last and ("line " .. group.first)
    or ("lines " .. group.first .. "-" .. group.last)
  local segment = ""
  if group.index and group.total and group.total > 1 then
    segment = string.format("block %d/%d  ", group.index, group.total)
  end
  local kind = has_conflict and "conflict" or "change"
  return string.format("nvime %s%s %s  %s  -%d +%d", segment, kind, id_text, range_text, old_total, new_total)
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
  local conflict = 0
  for _, block in ipairs(hunk.blocks or {}) do
    if block.status == "pending" then
      pending = pending + 1
    elseif block.status == "accepted" then
      accepted = accepted + 1
    elseif block.status == "rejected" then
      rejected = rejected + 1
    elseif block.status == "conflict" then
      conflict = conflict + 1
    end
  end
  if conflict > 0 then
    hunk.status = "conflict"
  elseif pending > 0 then
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
  local review = session and session.review
  if review and review.target_winid and vim.api.nvim_win_is_valid(review.target_winid) then
    vim.api.nvim_set_current_win(review.target_winid)
    return
  end
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
  vim.keymap.set("n", "gA!", function()
    require("nvime.diff").accept_all({ force = true })
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
    if is_unresolved(block) then
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
    local starts_new = not current
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

local function count_block_statuses(session)
  local counts = {
    pending = 0,
    accepted = 0,
    rejected = 0,
    conflict = 0,
    mixed = 0,
    total = 0,
  }
  for _, block in ipairs(session.blocks or {}) do
    local status = block.status or "pending"
    counts[status] = (counts[status] or 0) + 1
    counts.total = counts.total + 1
  end
  return counts
end

local function set_lines_unlocked(bufnr, lines, locked)
  vim.bo[bufnr].readonly = false
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines or {})
  vim.bo[bufnr].modifiable = locked == false
  vim.bo[bufnr].readonly = locked ~= false
end

local function apply_blocks_to_lines(base_lines, blocks, include)
  local lines = copy_lines(base_lines)
  local plan = {}
  for _, block in ipairs(blocks or {}) do
    if include(block) then
      plan[#plan + 1] = block
    end
  end
  table.sort(plan, function(a, b)
    if a.old_start == b.old_start then
      return a.id < b.id
    end
    return a.old_start < b.old_start
  end)

  local offset = 0
  for _, block in ipairs(plan) do
    local start_index = math.max(0, math.min(block.old_start - 1 + offset, #lines))
    local end_index = math.max(start_index, math.min(start_index + block.old_count, #lines))
    local replacement = copy_lines(block.new_lines)
    for _ = start_index + 1, end_index do
      table.remove(lines, start_index + 1)
    end
    for index, line in ipairs(replacement) do
      table.insert(lines, start_index + index, line)
    end
    offset = offset + #replacement - block.old_count
  end
  return lines
end

local function original_lines(session)
  if session.original_lines then
    return session.original_lines
  end
  if session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr) then
    return vim.api.nvim_buf_get_lines(session.target_bufnr, 0, -1, false)
  end
  return {}
end

local function proposed_lines(session)
  if not session.blocks then
    build_blocks(session)
  end
  return apply_blocks_to_lines(original_lines(session), session.blocks, function(block)
    return block.status ~= "rejected"
  end)
end

local function review_name(session, kind)
  session.review_id = session.review_id or tostring(vim.loop.hrtime())
  return "nvime://diff/" .. kind .. "/" .. session.review_id .. "/" .. tostring(session.file or "buffer")
end

local function configure_review_buffer(bufnr, lines, filetype)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype or "text"
  set_lines_unlocked(bufnr, lines, true)
end

local function ensure_review_buffer(session, kind, lines)
  session.review = session.review or {}
  local key = kind .. "_bufnr"
  local bufnr = session.review[key]
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = vim.api.nvim_create_buf(false, true)
    pcall(vim.api.nvim_buf_set_name, bufnr, review_name(session, kind))
    session.review[key] = bufnr
  end
  configure_review_buffer(bufnr, lines, vim.bo[session.target_bufnr].filetype)
  return bufnr
end

local function set_review_winbar(winid, label, session)
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return
  end
  local counts = count_block_statuses(session)
  local file = vim.fn.fnamemodify(session.file or "", ":t")
  local warn = ""
  if session and session.warnings and #session.warnings > 0 then
    warn = "  " .. ui.icon("warning") .. " truncation suspected"
  end
  local conflict = ""
  if (counts.conflict or 0) > 0 then
    conflict = string.format("  %s %d", ui.icon("warning"), counts.conflict)
  end
  vim.wo[winid].winbar = string.format(
    " nvime.nvim  %s  %s  %s %d  %s %d  %s %d%s %s",
    label,
    file,
    ui.icon("pending"),
    counts.pending or 0,
    ui.icon("success"),
    counts.accepted or 0,
    ui.icon("error"),
    counts.rejected or 0,
    conflict,
    warn
  )
end

local function configure_review_window(winid, label, session)
  vim.wo[winid].number = true
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].wrap = false
  vim.wo[winid].sidescrolloff = 0
  vim.wo[winid].spell = false
  vim.wo[winid].cursorbind = true
  vim.wo[winid].scrollbind = true
  vim.wo[winid].foldenable = false
  vim.wo[winid].winfixwidth = true
  vim.wo[winid].winhighlight =
    "WinBar:NvimeTitle,WinSeparator:NvimeBorder,DiffAdd:NvimeDiffAdd,DiffDelete:NvimeDiffDelete,DiffChange:NvimeDiffHunk"
  set_review_winbar(winid, label, session)
end

local function valid_review(session)
  local review = session and session.review
  return review
    and review.tabpage
    and vim.api.nvim_tabpage_is_valid(review.tabpage)
    and review.proposed_winid
    and vim.api.nvim_win_is_valid(review.proposed_winid)
    and review.target_winid
    and vim.api.nvim_win_is_valid(review.target_winid)
end

local function set_review_widths(session)
  if not valid_review(session) then
    return
  end
  local total = math.max(42, vim.o.columns)
  local width = math.floor((total - 2) / 2)
  width = math.max(total >= 90 and 40 or 18, width)
  pcall(vim.api.nvim_win_set_width, session.review.proposed_winid, width)
  pcall(vim.api.nvim_win_set_width, session.review.target_winid, width)
end

local function target_review_text_width(session)
  local winid = valid_review(session) and session.review.target_winid or current_file_window(session.target_bufnr)
  if winid and vim.api.nvim_win_is_valid(winid) then
    return math.max(8, vim.api.nvim_win_get_width(winid) - 6)
  end
  return math.max(8, vim.o.columns - 10)
end

local function clip_review_text(session, text)
  return ui.truncate(text, target_review_text_width(session))
end

local function refresh_review_view(session)
  if not valid_review(session) then
    return
  end
  local current_tab = vim.api.nvim_get_current_tabpage()
  local current_win = vim.api.nvim_get_current_win()
  ensure_review_buffer(session, "proposed", proposed_lines(session))
  set_review_winbar(session.review.proposed_winid, "proposed", session)
  set_review_winbar(session.review.target_winid, "editable", session)
  set_review_widths(session)
  pcall(vim.api.nvim_set_current_tabpage, session.review.tabpage)
  pcall(vim.cmd, "diffupdate")
  if vim.api.nvim_tabpage_is_valid(current_tab) then
    pcall(vim.api.nvim_set_current_tabpage, current_tab)
    if vim.api.nvim_win_is_valid(current_win) then
      pcall(vim.api.nvim_set_current_win, current_win)
    end
  end
end

local function install_review_maps(bufnr)
  local opts = { buffer = bufnr, silent = true }
  vim.keymap.set("n", "]b", function()
    require("nvime.diff").next_group()
  end, opts)
  vim.keymap.set("n", "[b", function()
    require("nvime.diff").prev_group()
  end, opts)
  vim.keymap.set("n", "]n", function()
    require("nvime.diff").next_change()
  end, opts)
  vim.keymap.set("n", "[n", function()
    require("nvime.diff").prev_change()
  end, opts)
  vim.keymap.set("n", "ga", function()
    require("nvime.diff").accept_current_group()
  end, opts)
  vim.keymap.set("n", "gb", function()
    require("nvime.diff").reject_current_group()
  end, opts)
  vim.keymap.set("n", "gA", function()
    require("nvime.diff").accept_all()
  end, opts)
  vim.keymap.set("n", "gA!", function()
    require("nvime.diff").accept_all({ force = true })
  end, opts)
  vim.keymap.set("n", "gB", function()
    require("nvime.diff").reject_all()
  end, opts)
  vim.keymap.set("n", "gc", function()
    require("nvime.edit").continue_remaining()
  end, opts)
  vim.keymap.set("n", "e", function()
    require("nvime.diff").focus_editable()
  end, opts)
  vim.keymap.set("n", "r", function()
    require("nvime.diff").refresh_view()
  end, opts)
  vim.keymap.set("n", "q", function()
    require("nvime.diff").close_view()
  end, opts)
end

local function render_visual_group(session, group)
  local start_line = group.first
  local count = target_line_count(session)
  local anchor_row = math.max(0, math.min(start_line - 1, math.max(0, count - 1)))
  local virt_above = group.first <= count
  local new_lines = {}
  local old_line_rows = {}
  local has_old_lines = false

  local virt_lines = {}
  if session.warnings and #session.warnings > 0 and (group.index or 1) == 1 then
    for _, msg in ipairs(session.warnings) do
      virt_lines[#virt_lines + 1] = {
        { clip_review_text(session, "  " .. ui.icon("warning") .. " " .. msg), "NvimeError" },
      }
    end
  end
  virt_lines[#virt_lines + 1] = { { clip_review_text(session, group_summary(group)), "NvimeDiffHunk" } }
  virt_lines[#virt_lines + 1] = {
    {
      clip_review_text(session, "  ]b/[b move  ga accept  gb reject  gA/gB all  gA! force all  gc discuss  q close"),
      "NvimeMuted",
    },
  }

  local has_conflict = false
  for _, block in ipairs(group.blocks) do
    has_conflict = has_conflict or block.status == "conflict"
    for _, line in ipairs(block.new_lines) do
      new_lines[#new_lines + 1] = line
    end
    if block.old_count > 0 then
      has_old_lines = true
      local block_line = block_start_line(session, block)
      for i = 0, block.old_count - 1 do
        old_line_rows[#old_line_rows + 1] = {
          line = block_line + i,
          hl = block.status == "conflict" and "NvimeConflict" or "NvimeDiffDelete",
        }
      end
    end
  end

  if has_conflict then
    virt_lines[#virt_lines + 1] = {
      {
        clip_review_text(
          session,
          "  " .. ui.icon("warning") .. " conflict: live text changed; use :NvimeAccept! or gA! to force"
        ),
        "NvimeConflict",
      },
    }
  end
  if #new_lines > 0 then
    virt_lines[#virt_lines + 1] = { { "  proposed", "NvimeMuted" } }
  else
    virt_lines[#virt_lines + 1] =
      { { clip_review_text(session, "  proposed: remove highlighted line(s)"), "NvimeMuted" } }
  end
  for _, line in ipairs(new_lines) do
    virt_lines[#virt_lines + 1] = { { clip_review_text(session, "+ " .. line), "NvimeDiffAdd" } }
  end
  if has_old_lines then
    virt_lines[#virt_lines + 1] = { { "  current", "NvimeMuted" } }
  else
    virt_lines[#virt_lines + 1] = { { "  insertion point below", "NvimeMuted" } }
  end

  for _, item in ipairs(old_line_rows) do
    local row = item.line - 1
    if row >= 0 and row < count then
      vim.api.nvim_buf_set_extmark(session.target_bufnr, ns, row, 0, {
        line_hl_group = item.hl,
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

local function render_session(session, opts)
  opts = opts or {}
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
    if is_unresolved(block) then
      pending = pending + 1
    end
  end
  if not opts.silent then
    if pending == 0 then
      local hint = session.review and "  press q to close" or ""
      vim.notify("nvime diff: resolved" .. hint, vim.log.levels.INFO)
    else
      vim.notify("nvime diff: " .. pending .. " pending  ]b/[b ga gb gA gB gc  q close", vim.log.levels.INFO)
    end
    if session.warnings and #session.warnings > 0 and not session.warnings_announced then
      session.warnings_announced = true
      vim.notify(
        "nvime diff: SUSPICIOUS PATCH — "
          .. table.concat(session.warnings, "; ")
          .. ". Review carefully before accepting.",
        vim.log.levels.ERROR
      )
    end
  end
  refresh_review_view(session)
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
  while
    suffix < (#original - prefix)
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

  local diff_lines = nil
  if mode == "NVIME_REPLACEMENT" then
    local no_change_reason
    diff_lines, no_change_reason = build_single_hunk(selection, body)
    if not diff_lines then
      return {
        status = "no_change",
        message = no_change_reason,
      }
    end
  else
    diff_lines = extract_unified(body)
    if mode == "NVIME_DIFF" and (not diff_lines or not has_ranged_hunk(diff_lines)) then
      local anchor_error
      diff_lines, anchor_error = build_unranged_hunk(selection, body)
      if not diff_lines then
        return {
          status = "no_change",
          message = anchor_error,
        }
      end
    elseif not diff_lines then
      if mode == "NVIME_DIFF" then
        return {
          status = "no_change",
          message = "agent returned NVIME_DIFF without a unified diff",
        }
      end
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
  end

  local valid, validation_error = validate_current_file(diff_lines, selection.path)
  if not valid then
    error(validation_error)
  end

  local header, hunks = parse_hunks(diff_lines)
  hunks = dedupe_hunks(hunks)
  if #hunks == 0 then
    error("nvime could not find any hunks in the proposed diff")
  end
  reanchor_hunks(selection, hunks)
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
    original_lines = vim.api.nvim_buf_get_lines(selection.bufnr, 0, -1, false),
    original_changedtick = vim.api.nvim_buf_get_changedtick(selection.bufnr),
    header = header,
    hunks = hunks,
    provider = provider,
    prompt = prompt,
    applied = {},
  }

  local warnings = {}
  local before_balance = bracket_balance(session.original_lines)
  session.original_balance = before_balance
  local proposed_ok, proposed = pcall(proposed_lines, session)
  if proposed_ok and proposed then
    local after_balance = bracket_balance(proposed)
    local drift = bracket_drift(before_balance, after_balance)
    if has_bracket_drift(drift) then
      session.bracket_drift = drift
      warnings[#warnings + 1] = "delimiter imbalance — " .. (bracket_drift_summary(drift) or "?")
    end
  end
  if response_likely_truncated(response) then
    session.response_truncated = true
    warnings[#warnings + 1] = "agent response did not close its diff fence; output may be truncated"
  end
  session.warnings = warnings

  state.current_diff = session
  render_session(session)
  return {
    status = "diff",
    session = session,
  }
end

local function install_target_close_map(session)
  if not session.target_bufnr or not vim.api.nvim_buf_is_valid(session.target_bufnr) then
    return
  end
  if session.review_close_map_installed then
    return
  end
  pcall(vim.keymap.set, "n", "q", function()
    require("nvime.diff").close_view()
  end, {
    buffer = session.target_bufnr,
    silent = true,
    desc = "close nvime diff review",
  })
  session.review_close_map_installed = true
end

local function uninstall_target_close_map(session)
  if not session or not session.review_close_map_installed then
    return
  end
  if session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr) then
    pcall(vim.keymap.del, "n", "q", { buffer = session.target_bufnr })
  end
  session.review_close_map_installed = false
end

function M.open_view()
  local session = state.current_diff
  if not session then
    vim.notify("No active nvime diff session", vim.log.levels.WARN)
    return
  end
  if not (session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr)) then
    vim.notify("The nvime diff target buffer is no longer valid", vim.log.levels.WARN)
    return
  end
  if not session.blocks then
    build_blocks(session)
  end

  local proposed_bufnr = ensure_review_buffer(session, "proposed", proposed_lines(session))
  install_review_maps(proposed_bufnr)

  if valid_review(session) then
    vim.api.nvim_set_current_tabpage(session.review.tabpage)
    refresh_review_view(session)
    install_target_close_map(session)
    focus_target(session)
    pcall(vim.cmd, "diffupdate")
    return
  end

  session.review_caller_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tabnew")
  local tabpage = vim.api.nvim_get_current_tabpage()
  local proposed_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(proposed_winid, proposed_bufnr)

  vim.cmd("rightbelow vsplit")
  local target_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(target_winid, session.target_bufnr)

  session.review = vim.tbl_extend("force", session.review or {}, {
    tabpage = tabpage,
    proposed_winid = proposed_winid,
    target_winid = target_winid,
  })

  configure_review_window(proposed_winid, "proposed", session)
  configure_review_window(target_winid, "editable", session)
  vim.api.nvim_set_current_win(proposed_winid)
  vim.cmd("diffthis")
  vim.api.nvim_set_current_win(target_winid)
  vim.cmd("diffthis")
  pcall(vim.cmd, "wincmd =")
  set_review_widths(session)
  install_target_close_map(session)
  vim.api.nvim_set_current_win(target_winid)
  render_session(session, { silent = true })
end

function M.focus_editable()
  local session = state.current_diff
  if not session then
    return
  end
  if valid_review(session) then
    vim.api.nvim_set_current_tabpage(session.review.tabpage)
    vim.api.nvim_set_current_win(session.review.target_winid)
    return
  end
  focus_target(session)
end

function M.refresh_view()
  local session = state.current_diff
  if not session then
    return
  end
  render_session(session)
end

function M.close_view()
  local session = state.current_diff
  local review = session and session.review
  if not review then
    return
  end
  uninstall_target_close_map(session)
  if review.tabpage and vim.api.nvim_tabpage_is_valid(review.tabpage) then
    pcall(vim.api.nvim_set_current_tabpage, review.tabpage)
    pcall(vim.cmd, "tabclose")
  end
  local proposed_bufnr = review.proposed_bufnr
  if proposed_bufnr and vim.api.nvim_buf_is_valid(proposed_bufnr) then
    pcall(vim.api.nvim_buf_delete, proposed_bufnr, { force = true })
  end
  session.review = nil
  local caller_tab = session.review_caller_tab
  session.review_caller_tab = nil
  if caller_tab and vim.api.nvim_tabpage_is_valid(caller_tab) then
    pcall(vim.api.nvim_set_current_tabpage, caller_tab)
  end
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
    if is_unresolved(block) then
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

local function mark_conflict(session, block, start_index, end_index, live_lines)
  block.status = "conflict"
  block.conflict = {
    start_line = start_index + 1,
    expected = copy_lines(block.old_lines),
    actual = copy_lines(live_lines),
  }
  update_hunk_status(block.hunk)
  audit.write({
    event = "block_conflict",
    file = session.file,
    block_id = block.id,
    start_line = start_index + 1,
    end_line = end_index,
  })
  vim.notify("nvime diff conflict: live text changed; use :NvimeAccept! or gA! to force", vim.log.levels.WARN)
end

local function live_block_matches(session, block, start_index, end_index)
  if
    session.original_changedtick
    and vim.api.nvim_buf_get_changedtick(session.target_bufnr) == session.original_changedtick
  then
    return true
  end
  local live_lines = vim.api.nvim_buf_get_lines(session.target_bufnr, start_index, end_index, false)
  if same_lines(live_lines, block.old_lines or {}) then
    return true
  end
  return false, live_lines
end

local function apply_block(session, block, start_line_override, opts)
  opts = opts or {}
  if not block or (block.status ~= "pending" and not (opts.force and block.status == "conflict")) then
    return 0
  end
  local replacement = block.new_lines
  local start_line = start_line_override or block_start_line(session, block)
  local start_index = math.max(0, math.min(start_line - 1, target_line_count(session)))
  local end_index = math.max(start_index, math.min(start_index + block.old_count, target_line_count(session)))
  if not opts.force then
    local matches, live_lines = live_block_matches(session, block, start_index, end_index)
    if not matches then
      mark_conflict(session, block, start_index, end_index, live_lines)
      return 0
    end
  else
    audit.write({
      event = "block_force_applied",
      file = session.file,
      block_id = block.id,
      start_line = start_index + 1,
      end_line = end_index,
    })
  end
  vim.api.nvim_buf_set_lines(session.target_bufnr, start_index, end_index, false, replacement)
  block.status = "accepted"
  block.conflict = nil
  session.applied[#session.applied + 1] = {
    old_start = block.old_start,
    delta = #block.new_lines - block.old_count,
  }
  update_hunk_status(block.hunk)
  return #block.new_lines - block.old_count
end

local function reject_block(block)
  if is_unresolved(block) then
    block.status = "rejected"
    block.conflict = nil
    update_hunk_status(block.hunk)
  end
end

function M.accept_blocks(blocks, opts)
  opts = opts or {}
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
    if block and (block.status == "pending" or (opts.force and block.status == "conflict")) then
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
    offset = offset + apply_block(session, item.block, item.start_line + offset, opts)
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

function M.accept_hunks(hunks, opts)
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
      if is_unresolved(block) then
        blocks[#blocks + 1] = block
      end
    end
  end
  M.accept_blocks(blocks, opts)
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

function M.accept_current_group(opts)
  local session = state.current_diff
  if not session then
    return
  end
  local group = current_group(session)
  if not group then
    vim.notify("No pending nvime change block selected", vim.log.levels.WARN)
    return
  end
  M.accept_blocks(group.blocks, opts)
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

function M.accept_all(opts)
  opts = opts or {}
  local session = state.current_diff
  if not session then
    return
  end
  if session.warnings and #session.warnings > 0 and not session.warnings_overridden and not opts.force then
    local choice = vim.fn.confirm(
      "nvime diff has truncation warnings:\n  - "
        .. table.concat(session.warnings, "\n  - ")
        .. "\n\nAccept all anyway?",
      "&Accept all\n&Cancel",
      2
    )
    if choice ~= 1 then
      vim.notify("nvime accept-all cancelled (truncation warning)", vim.log.levels.INFO)
      return
    end
    session.warnings_overridden = true
  end
  M.accept_blocks(pending_blocks(session), opts)
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
    lines[#lines + 1] = string.format("line %d (%s) at original line %d:", block.id, block.status, block.old_start)
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
