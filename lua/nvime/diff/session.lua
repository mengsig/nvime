-- nvime.diff.session
--
-- The interactive diff-session subsystem: the per-file session registry + queue
-- (state.diffs / state.current_diff), the inline extmark renderer, the two-pane
-- review workspace, and visual-block grouping. registry and render are mutually
-- recursive (activate_session -> render_session -> complete_resolved_session ->
-- promote -> activate), so they live together here and the forward-declared
-- `render_session` ties the knot. Pure parsing is in diff.parser, the block
-- model + conflict engine in diff.shared, and accept/reject ops in diff.ops.

local audit = require("nvime.audit")
local git = require("nvime.git")
local keyhelp = require("nvime.keyhelp")
local state = require("nvime.state")
local ui = require("nvime.ui")

local uv = vim.uv or vim.loop
local M = {}

local shared = require("nvime.diff.shared")
local ns = shared.ns
local copy_lines = shared.copy_lines
local is_unresolved = shared.is_unresolved
local group_summary = shared.group_summary
local build_blocks = shared.build_blocks
local update_hunk_status = shared.update_hunk_status
local target_line_count = shared.target_line_count
local reconcile_live_state = shared.reconcile_live_state
local block_start_line = shared.block_start_line
local block_range = shared.block_range

-- Parser: agent-response → hunk parsing. Aliased back to the local names the
-- session builder / start_session below still use.
local parser = require("nvime.diff.parser")
local normalize_file_key = parser.normalize_file_key
local trim = parser.trim
local reanchor_hunks = parser.reanchor_hunks

local function diff_config()
  return ((state.config or {}).diff or {})
end

local function max_visual_block_lines()
  return math.max(4, tonumber(diff_config().max_visual_block_lines) or 12)
end

local render_session

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

local function diff_registry()
  state.diffs = state.diffs or {}
  state.diffs.active_by_bufnr = state.diffs.active_by_bufnr or {}
  state.diffs.active_by_path = state.diffs.active_by_path or {}
  state.diffs.queue_by_path = state.diffs.queue_by_path or {}
  return state.diffs
end

local function session_path_key(session)
  if not session then
    return nil
  end
  session.path_key = session.path_key or normalize_file_key(session.file)
  return session.path_key
end

local function buffer_file_key(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == "" or name:match("^nvime://") then
    return nil
  end
  return normalize_file_key(git.repo_relative_path(name) or name)
end

local function session_pending_count(session)
  if not session then
    return 0
  end
  if not session.blocks then
    build_blocks(session)
  end
  local pending = 0
  for _, block in ipairs(session.blocks or {}) do
    if is_unresolved(block) then
      pending = pending + 1
    end
  end
  return pending
end

local function session_is_active(session)
  if not session then
    return false
  end
  local registry = diff_registry()
  local key = session_path_key(session)
  return (key and registry.active_by_path[key] == session)
    or (session.target_bufnr and registry.active_by_bufnr[session.target_bufnr] == session)
end

local function unregister_session(session, opts)
  opts = opts or {}
  if not session then
    return
  end
  local registry = diff_registry()
  local key = session_path_key(session)
  if key and registry.active_by_path[key] == session then
    registry.active_by_path[key] = nil
  end
  if session.target_bufnr and registry.active_by_bufnr[session.target_bufnr] == session then
    registry.active_by_bufnr[session.target_bufnr] = nil
  end
  session.active = false
  if state.current_diff == session and not opts.keep_current then
    state.current_diff = nil
  end
end

local function set_active_session(session, opts)
  opts = opts or {}
  local key = session_path_key(session)
  local registry = diff_registry()
  if key then
    registry.active_by_path[key] = session
  end
  if session.target_bufnr then
    registry.active_by_bufnr[session.target_bufnr] = session
  end
  session.active = true
  session.queued = false
  if opts.make_current ~= false then
    state.current_diff = session
  end
end

local function queued_count(key)
  local queue = key and diff_registry().queue_by_path[key] or nil
  return queue and #queue or 0
end

local function reset_session_render_model(session)
  session.blocks = nil
  session.visual_groups = nil
  session.applied = {}
  for _, hunk in ipairs(session.hunks or {}) do
    hunk.blocks = nil
    hunk.status = "pending"
  end
end

local function activate_session(session, opts)
  opts = opts or {}
  if opts.reanchor then
    reanchor_hunks(session.selection, session.hunks)
    reset_session_render_model(session)
  end
  set_active_session(session, opts)
  -- Kick off the pre-accept verify lane on first activation. Queued sessions
  -- skip verify at start_session time (their blocks aren't built yet, and
  -- building them early would touch the shared buffer's extmark state used
  -- by the currently active diff); we run it here when they promote.
  if not session.verify_started then
    local ok_verify, verify = pcall(require, "nvime.verify")
    if ok_verify and verify and type(verify.start) == "function" then
      session.verify_started = true
      pcall(verify.start, session)
    end
  end
  render_session(session, {
    focus = opts.focus,
    silent = opts.silent,
  })
end

local function promote_queued_session(key)
  local registry = diff_registry()
  local queue = key and registry.queue_by_path[key] or nil
  while queue and #queue > 0 do
    local next_session = table.remove(queue, 1)
    if next_session and next_session.target_bufnr and vim.api.nvim_buf_is_valid(next_session.target_bufnr) then
      local current_bufnr = vim.api.nvim_get_current_buf()
      local make_current = current_bufnr == next_session.target_bufnr or state.current_diff == nil
      activate_session(next_session, {
        reanchor = true,
        focus = current_bufnr == next_session.target_bufnr,
        make_current = make_current,
      })
      vim.notify("nvime diff: next queued diff active for " .. tostring(next_session.file), vim.log.levels.INFO)
      return next_session
    end
  end
  if key then
    registry.queue_by_path[key] = nil
  end
  return nil
end

local function complete_resolved_session(session)
  local key = session_path_key(session)
  unregister_session(session, { keep_current = true })
  if key then
    promote_queued_session(key)
  end
end

local function active_session_for_bufnr(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local registry = diff_registry()
  local session = registry.active_by_bufnr[bufnr]
  if session and session_pending_count(session) > 0 then
    return session
  elseif session then
    unregister_session(session)
  end

  local key = buffer_file_key(bufnr)
  session = key and registry.active_by_path[key] or nil
  if session and session_pending_count(session) > 0 then
    return session
  elseif session then
    unregister_session(session)
  end
  return nil
end

local function session_for_context(opts)
  opts = opts or {}
  local current_bufnr = vim.api.nvim_get_current_buf()
  local session = active_session_for_bufnr(current_bufnr)
  if session then
    state.current_diff = session
    return session
  end

  local current_winid = vim.api.nvim_get_current_win()
  for _, active in pairs(diff_registry().active_by_path) do
    local review = active and active.review
    if
      review
      and (review.proposed_bufnr == current_bufnr or review.proposed_winid == current_winid or review.target_winid == current_winid)
      and session_pending_count(active) > 0
    then
      state.current_diff = active
      return active
    end
  end

  if not buffer_file_key(current_bufnr) and state.current_diff and session_is_active(state.current_diff) then
    return state.current_diff
  end
  if
    opts.include_resolved
    and state.current_diff
    and (
      state.current_diff.target_bufnr == current_bufnr
      or not buffer_file_key(current_bufnr)
      or (
        state.current_diff.review
        and (
          state.current_diff.review.proposed_bufnr == current_bufnr
          or state.current_diff.review.proposed_winid == current_winid
          or state.current_diff.review.target_winid == current_winid
        )
      )
    )
  then
    return state.current_diff
  end
  return nil
end

function M.current_session()
  return session_for_context()
end

local function session_for_action()
  return session_for_context({ include_resolved = true })
end

local function register_session(session)
  local key = session_path_key(session)
  local registry = diff_registry()
  local existing = key and registry.active_by_path[key] or nil
  if existing and existing ~= session and session_pending_count(existing) == 0 then
    unregister_session(existing)
    existing = nil
  end

  if existing and existing ~= session then
    local queue = registry.queue_by_path[key] or {}
    registry.queue_by_path[key] = queue
    session.queued = true
    table.insert(queue, session)
    vim.notify(
      string.format("nvime diff: queued for %s (%d waiting)", tostring(session.file), queued_count(key)),
      vim.log.levels.INFO
    )
    return "queued"
  end

  local current_bufnr = vim.api.nvim_get_current_buf()
  local focus = current_bufnr == session.target_bufnr or active_session_for_bufnr(current_bufnr) == nil
  activate_session(session, {
    focus = focus,
    make_current = focus or state.current_diff == nil,
  })
  if not focus then
    vim.notify(
      "nvime diff: active for " .. tostring(session.file) .. "; switch to that buffer to review",
      vim.log.levels.INFO
    )
  end
  return "active"
end

-- The g? cheat-sheet for the diff review. `review` selects the dual-pane
-- workspace variant (adds the pane keys, drops the inline-only undo); the
-- inline variant documents the same canonical accept/reject verbs that live in
-- the file buffer. Aliases (gr/gR/gX) are intentionally omitted so the card
-- shows one obvious key per action.
local function diff_help_sections(review)
  local resolve_rows = {
    { "ga", "accept the block (visual: the selection)" },
    { "ga!", "force-accept (override a conflict)" },
    { "gb", "reject the block (visual: the selection)" },
  }
  if not review then
    resolve_rows[#resolve_rows + 1] = { "gu", "undo the last accept" }
  end
  resolve_rows[#resolve_rows + 1] = { "gc", "discuss the rest with the agent" }

  local window_rows = {}
  if review then
    window_rows[#window_rows + 1] = { "e", "focus the editable pane" }
    window_rows[#window_rows + 1] = { "r", "refresh the review" }
    window_rows[#window_rows + 1] = { "q", "close the review" }
  end
  window_rows[#window_rows + 1] = { "g?", "toggle this help" }

  return {
    {
      heading = "Navigate",
      rows = {
        { "]b  [b", "next / previous change block" },
        { "]n  [n", "next / previous change line" },
      },
    },
    { heading = "Resolve", rows = resolve_rows },
    {
      heading = "All blocks",
      rows = {
        { "gA", "accept all" },
        { "gA!", "force-accept all" },
        { "gB", "reject all" },
      },
    },
    { heading = "Window", rows = window_rows },
  }
end

local function install_buffer_maps(session)
  if session.maps_installed then
    return
  end
  session.maps_installed = true
  local opts = { buffer = session.target_bufnr, silent = true }
  vim.keymap.set("n", "g?", function()
    keyhelp.toggle({
      title = "diff keys",
      sections = diff_help_sections(false),
      parent_winid = current_file_window(session.target_bufnr),
    })
  end, opts)
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
  vim.keymap.set("n", "ga!", function()
    require("nvime.diff").accept_current_group({ force = true })
  end, opts)
  vim.keymap.set("x", "ga", function()
    require("nvime.diff").accept_selection()
  end, opts)
  vim.keymap.set("n", "gb", function()
    require("nvime.diff").reject_current_group()
  end, opts)
  vim.keymap.set("n", "gu", function()
    require("nvime.diff").undo_last_accept()
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
  session.review_id = session.review_id or tostring(uv.hrtime())
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
  -- Per-pane semantics for the dual-pane review (`<leader>nv`):
  --   proposed pane (LEFT)  → unique lines = ABOUT TO BE ADDED, paint green
  --   editable pane (RIGHT) → unique lines = ABOUT TO BE REMOVED, paint red
  -- Vim's diff mode is symmetric (both panes use `DiffAdd` for their own
  -- unique lines), so without this per-pane flip the right pane shows the
  -- to-be-deleted code in green, which is the exact confusion reported.
  -- DiffText (the column-level diff inside a partially-changed line) gets
  -- the same per-pane colour so character-level changes also read green
  -- on the proposed side and red on the editable side.
  -- DiffDelete (the `~` filler placeholder where one side has lines the
  -- other doesn't) stays neutral via NvimeDiffHunk — the colored lines on
  -- the other pane already say what's happening, no need to echo here.
  local diff_hl
  if label == "editable" then
    diff_hl = "DiffAdd:NvimeDiffDelete,DiffDelete:NvimeDiffHunk,DiffChange:NvimeDiffHunk,DiffText:NvimeDiffDelete"
  else
    diff_hl = "DiffAdd:NvimeDiffAdd,DiffDelete:NvimeDiffHunk,DiffChange:NvimeDiffHunk,DiffText:NvimeDiffAdd"
  end
  vim.wo[winid].winhighlight = "WinBar:NvimeTitle,WinSeparator:NvimeBorder," .. diff_hl
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
  vim.keymap.set("n", "ga!", function()
    require("nvime.diff").accept_current_group({ force = true })
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
  vim.keymap.set("n", "g?", function()
    keyhelp.toggle({
      title = "diff review keys",
      sections = diff_help_sections(true),
      parent_winid = vim.api.nvim_get_current_win(),
    })
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
  if (group.index or 1) == 1 and session.rationale and session.rationale ~= "" then
    -- Show the agent's self-rationalization once per session, on the first
    -- visual group, so the user has the "why" before they hit ga.
    local rationale_text = "  " .. ui.icon("review") .. " rationale: " .. session.rationale
    virt_lines[#virt_lines + 1] = {
      { clip_review_text(session, rationale_text), "NvimeQuote" },
    }
  end
  if (group.index or 1) == 1 and session.verify then
    -- Pre-accept verify lane: tree-sitter parse + configured lint/type
    -- checks against the proposed full-file content. A parse error in
    -- the proposed content blocks silent ga/gA (force via gA!).
    local ok_verify, verify = pcall(require, "nvime.verify")
    if ok_verify and verify and type(verify.banner_rows) == "function" then
      for _, row in ipairs(verify.banner_rows(session, ui.icon) or {}) do
        virt_lines[#virt_lines + 1] = {
          { clip_review_text(session, row[1]), row[2] },
        }
      end
    end
  end
  if (group.index or 1) == 1 and session.verify_attestation and session.verify_attestation ~= "" then
    virt_lines[#virt_lines + 1] = {
      {
        clip_review_text(session, "  agent VERIFY: " .. session.verify_attestation),
        "NvimeMuted",
      },
    }
  end
  if (group.index or 1) == 1 then
    -- Blast-radius badge: lines, bracket drift, ai-share, sensitive tags.
    -- Advisory only; the `gA!` confirmation lives in accept_blocks.
    local ok_risk, risk = pcall(require, "nvime.risk")
    if ok_risk and risk and type(risk.banner_row) == "function" then
      local row = risk.banner_row(session, ui.icon)
      if row then
        virt_lines[#virt_lines + 1] = {
          { clip_review_text(session, row[1]), row[2] },
        }
      end
    end
    -- Hunk @@-count drift: the agent declared one line count and emitted
    -- another. Advisory; apply still uses the corrected counts.
    local ok_hm, hunkmeta = pcall(require, "nvime.diff.hunkmeta")
    if ok_hm and hunkmeta and type(hunkmeta.banner_row) == "function" then
      local row = hunkmeta.banner_row(session, ui.icon)
      if row then
        virt_lines[#virt_lines + 1] = {
          { clip_review_text(session, row[1]), row[2] },
        }
      end
    end
  end
  if (group.index or 1) == 1 and session.verdict_pending then
    virt_lines[#virt_lines + 1] = {
      { clip_review_text(session, "  " .. ui.icon("pending") .. " critic reviewing patch…"), "NvimeMuted" },
    }
  end
  if (group.index or 1) == 1 and session.verdict then
    local d = session.verdict.decision or "FLAG"
    local hl = (d == "APPROVE" and "NvimeStatusSuccess") or (d == "REJECT" and "NvimeStatusError") or "NvimeStatusWarn"
    local text = string.format("  critic %s: %s", d, session.verdict.justification or "")
    virt_lines[#virt_lines + 1] = {
      { clip_review_text(session, text), hl },
    }
  end
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
      clip_review_text(session, "  ]b/[b move  ga accept  gb reject  gA/gB all  gc discuss  g? keys"),
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

render_session = function(session, opts)
  opts = opts or {}
  if not session.blocks then
    build_blocks(session)
  end
  if opts.reconcile ~= false then
    reconcile_live_state(session)
  end
  vim.api.nvim_buf_clear_namespace(session.target_bufnr, ns, 0, -1)
  install_buffer_maps(session)
  if opts.focus ~= false then
    focus_target(session)
  end

  for _, hunk in ipairs(session.hunks) do
    update_hunk_status(hunk)
  end
  for _, group in ipairs(pending_visual_groups(session)) do
    render_visual_group(session, group)
  end

  local pending = 0
  local accepted = 0
  for _, block in ipairs(session.blocks) do
    if is_unresolved(block) then
      pending = pending + 1
    elseif block.status == "accepted" then
      accepted = accepted + 1
    end
  end
  -- Fire on_resolved exactly once when all blocks have been decided. This is
  -- the hook the plan executor uses to auto-run the step's tests and offer
  -- to mark it done. Pass the pre-patch snapshot so the caller can offer a
  -- rollback if the post-acceptance tests fail.
  local resolved_now = false
  if pending == 0 and not session.on_resolved_fired then
    resolved_now = true
    session.on_resolved_fired = true
    local payload = {
      accepted = accepted,
      total = #session.blocks,
      original_lines = session.original_lines,
      target_bufnr = session.target_bufnr,
      path = session.file,
      session = session,
      rationale = session.rationale,
      verdict = session.verdict,
      provider = session.provider,
      applied_history = session.applied_history,
      plan_id = session.plan_id,
      plan_step_id = session.plan_step_id,
    }
    if type(session.on_resolved) == "function" then
      pcall(session.on_resolved, payload)
    end
    audit.write({
      event = "diff_resolved",
      path = payload.path,
      accepted = payload.accepted,
      total = payload.total,
      provider = payload.provider,
      plan_id = payload.plan_id,
      plan_step_id = payload.plan_step_id,
      rationale = payload.rationale,
      verdict = payload.verdict,
    })
    -- Fire global post-resolve hooks (e.g. nvime.test_loop). Listed in
    -- state.diff_post_resolve_hooks so each module can register itself
    -- once at setup() and stay decoupled from per-session callers.
    for _, hook in ipairs(state.diff_post_resolve_hooks or {}) do
      pcall(hook, payload)
    end
  end
  if not opts.silent then
    if pending == 0 then
      local hint = session.review and "  press q to close" or ""
      vim.notify("nvime diff: resolved" .. hint, vim.log.levels.INFO)
    else
      vim.notify("nvime diff: " .. pending .. " pending  ]b/[b move  ga gb resolve  g? keys", vim.log.levels.INFO)
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
    if session.rationale and session.rationale ~= "" and not session.rationale_announced then
      session.rationale_announced = true
      vim.notify("nvime rationale — " .. session.rationale, vim.log.levels.INFO)
    end
  end
  -- Audit hunk @@-count drift once per session (outside the silent guard so it
  -- is recorded even for non-interactive sessions). One event per session, not
  -- per hunk, to avoid noise.
  if not session.hunk_count_audited then
    session.hunk_count_audited = true
    local ok_hm, hunkmeta = pcall(require, "nvime.diff.hunkmeta")
    if ok_hm and hunkmeta then
      local mism = hunkmeta.mismatches(session.hunks or {})
      if #mism > 0 then
        require("nvime.audit").write({
          event = "hunk_count_mismatch",
          file = session.file,
          hunks = mism,
        })
      end
    end
  end
  refresh_review_view(session)
  if resolved_now then
    complete_resolved_session(session)
  end
end

M.diff_config = diff_config
M.max_visual_block_lines = max_visual_block_lines
M.current_file_window = current_file_window
M.focus_target = focus_target
M.diff_registry = diff_registry
M.session_path_key = session_path_key
M.buffer_file_key = buffer_file_key
M.session_pending_count = session_pending_count
M.session_is_active = session_is_active
M.unregister_session = unregister_session
M.set_active_session = set_active_session
M.queued_count = queued_count
M.reset_session_render_model = reset_session_render_model
M.activate_session = activate_session
M.promote_queued_session = promote_queued_session
M.complete_resolved_session = complete_resolved_session
M.active_session_for_bufnr = active_session_for_bufnr
M.session_for_context = session_for_context
M.session_for_action = session_for_action
M.register_session = register_session
M.install_buffer_maps = install_buffer_maps
M.block_visual_size = block_visual_size
M.block_lines = block_lines
M.block_has_blank_line = block_has_blank_line
M.first_nonblank_line = first_nonblank_line
M.indent_width = indent_width
M.starts_section = starts_section
M.pending_visual_groups = pending_visual_groups
M.count_block_statuses = count_block_statuses
M.set_lines_unlocked = set_lines_unlocked
M.apply_blocks_to_lines = apply_blocks_to_lines
M.original_lines = original_lines
M.proposed_lines = proposed_lines
M.review_name = review_name
M.configure_review_buffer = configure_review_buffer
M.ensure_review_buffer = ensure_review_buffer
M.set_review_winbar = set_review_winbar
M.configure_review_window = configure_review_window
M.valid_review = valid_review
M.set_review_widths = set_review_widths
M.target_review_text_width = target_review_text_width
M.clip_review_text = clip_review_text
M.refresh_review_view = refresh_review_view
M.install_review_maps = install_review_maps
M.render_visual_group = render_visual_group
M.render_session = render_session
return M
