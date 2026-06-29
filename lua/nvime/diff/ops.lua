-- nvime.diff.ops
--
-- Accept/reject/undo operations, block & group selection, the conflict-guarded
-- apply path, navigation, remaining-text, and the review-window open/refresh/
-- close ops. The public accept/reject/nav surface lives here and drives the
-- renderer in diff.session after every mutation. Lazy-requires verify / risk /
-- policy_rules / attribution at call time for the accept gate + provenance.

local audit = require("nvime.audit")
local state = require("nvime.state")
local shared = require("nvime.diff.shared")
local parser = require("nvime.diff.parser")
local session = require("nvime.diff.session")
local M = {}

-- Unified accept policy (S1). The three advisory pre-accept signals (critic
-- verdict, risk level, external verify findings) historically had inconsistent
-- teeth: verify blocked on a parse regression, risk only confirmed inside the
-- force branch, the critic never gated at all. diff.accept_policy maps each
-- signal to off|warn|confirm|block so they apply consistently on the COMMON
-- ga/gA path, not just gA!. Defaults are all "off" (backward compatible). The
-- tree-sitter parse gate keeps its own dedicated block (verify gate, below).
local ACCEPT_POLICY_RANK = { off = 0, warn = 1, confirm = 2, block = 3 }

local function accept_policy_cfg()
  local diff_cfg = (state.config or {}).diff or {}
  if type(diff_cfg.accept_policy) ~= "table" then
    return {}
  end
  return diff_cfg.accept_policy
end

-- True when at least one accept-policy signal is set to a non-"off" action.
-- The common (default) path has every signal "off", so this lets the accept
-- gate skip all of risk.score / critic / verify work entirely.
local function any_policy_signal_enabled(policy)
  for _, action in pairs(policy) do
    if type(action) == "string" and action ~= "off" then
      return true
    end
  end
  return false
end

-- Collect the configured-on signals worried about this diff, as a list of
-- { signal, action, reason }. Signals set to "off" / absent are skipped.
local function collect_accept_concerns(diff_session)
  local policy = accept_policy_cfg()
  local concerns = {}
  if not any_policy_signal_enabled(policy) then
    return concerns
  end
  local function consider(signal, present, reason)
    if not present then
      return
    end
    local action = policy[signal]
    if type(action) ~= "string" or action == "off" then
      return
    end
    concerns[#concerns + 1] = { signal = signal, action = action, reason = reason }
  end

  local verdict = diff_session.verdict
  if type(verdict) == "table" then
    if verdict.decision == "REJECT" then
      consider("critic_reject", true, "critic REJECT: " .. (verdict.justification or ""))
    elseif verdict.decision == "FLAG" then
      consider("critic_flag", true, "critic FLAG: " .. (verdict.justification or ""))
    end
  end

  local ok_risk, risk = pcall(require, "nvime.risk")
  if ok_risk and risk and type(risk.score) == "function" then
    local r = risk.score(diff_session)
    if r and r.level == "high" then
      local reason = "risk high"
      if type(risk.explain_level) == "function" then
        local why = risk.explain_level(r)
        if type(why) == "table" and #why > 0 then
          reason = reason .. ": " .. table.concat(why, ", ")
        end
      end
      consider("risk_high", true, reason)
    end
  end

  local ok_verify, verify = pcall(require, "nvime.verify")
  if ok_verify and verify and type(verify.has_tool_error) == "function" then
    local has, detail = verify.has_tool_error(diff_session)
    consider("verify_tool_error", has, "verify tool error" .. (detail and (" (" .. detail .. ")") or ""))
  end

  return concerns
end

local function strongest_action(concerns)
  local best = "off"
  for _, c in ipairs(concerns) do
    if (ACCEPT_POLICY_RANK[c.action] or 0) > (ACCEPT_POLICY_RANK[best] or 0) then
      best = c.action
    end
  end
  return best
end

local function concern_fields(concerns)
  local signals, reasons = {}, {}
  for _, c in ipairs(concerns) do
    signals[#signals + 1] = c.signal
    reasons[#reasons + 1] = c.reason
  end
  return signals, reasons
end

-- Evaluate the unified accept policy. Returns true to proceed, false to abort.
-- On force (gA!) the gate is bypassed but every worried signal is audited as a
-- forced bypass, mirroring the verify parse-error force path.
local function enforce_accept_policy(diff_session, opts)
  local concerns = collect_accept_concerns(diff_session)
  if #concerns == 0 then
    return true
  end
  local action = strongest_action(concerns)
  local signals, reasons = concern_fields(concerns)
  if opts.force then
    audit.write({
      event = "accept_policy_force",
      file = diff_session.file,
      action = action,
      signals = signals,
      reasons = reasons,
    })
    return true
  end
  if action == "block" then
    vim.notify(
      "nvime accept blocked: " .. table.concat(reasons, "; ") .. " — use gA!/:NvimeAccept! to force",
      vim.log.levels.WARN
    )
    audit.write({ event = "accept_policy_block", file = diff_session.file, signals = signals, reasons = reasons })
    return false
  end
  if action == "confirm" then
    local choice = vim.fn.confirm(
      "nvime accept policy flagged this diff:\n  - " .. table.concat(reasons, "\n  - ") .. "\n\nAccept anyway?",
      "&Accept\n&Cancel",
      2
    )
    if choice ~= 1 then
      vim.notify("nvime accept cancelled (accept policy)", vim.log.levels.INFO)
      audit.write({ event = "accept_policy_cancelled", file = diff_session.file, signals = signals, reasons = reasons })
      return false
    end
    audit.write({ event = "accept_policy_confirmed", file = diff_session.file, signals = signals, reasons = reasons })
    return true
  end
  -- warn
  vim.notify("nvime accept warning: " .. table.concat(reasons, "; "), vim.log.levels.WARN)
  audit.write({ event = "accept_policy_warn", file = diff_session.file, signals = signals, reasons = reasons })
  return true
end

-- Recompute verify against the new proposed content after a partial
-- accept/reject (S3). Cheap no-op when nothing changed (signature guard).
local function refresh_verify(diff_session)
  local ok_verify, verify = pcall(require, "nvime.verify")
  if ok_verify and verify and type(verify.refresh) == "function" then
    pcall(verify.refresh, diff_session)
  end
end

local same_lines = shared.same_lines
local copy_lines = shared.copy_lines
local lines_match_at = shared.lines_match_at
local is_unresolved = shared.is_unresolved
local build_blocks = shared.build_blocks
local update_hunk_status = shared.update_hunk_status
local target_line_count = shared.target_line_count
local mark_model_synced = shared.mark_model_synced
local reconcile_live_state = shared.reconcile_live_state
local block_start_line = shared.block_start_line
local block_range = shared.block_range
local trim = parser.trim
local focus_target = session.focus_target
local session_is_active = session.session_is_active
local set_active_session = session.set_active_session
local session_for_action = session.session_for_action
local pending_visual_groups = session.pending_visual_groups
local apply_blocks_to_lines = session.apply_blocks_to_lines
local proposed_lines = session.proposed_lines
local ensure_review_buffer = session.ensure_review_buffer
local configure_review_window = session.configure_review_window
local valid_review = session.valid_review
local set_review_widths = session.set_review_widths
local refresh_review_view = session.refresh_review_view
local install_review_maps = session.install_review_maps
local render_session = session.render_session

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
  local session = session_for_action()
  if not session then
    vim.notify("No active nvime diff for the current buffer", vim.log.levels.WARN)
    return
  end
  if not (session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr)) then
    vim.notify("The nvime diff target buffer is no longer valid", vim.log.levels.WARN)
    return
  end
  if not session.blocks then
    build_blocks(session)
  end
  reconcile_live_state(session)

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
  local session = session_for_action()
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
  local session = session_for_action()
  if not session then
    return
  end
  render_session(session)
end

function M.close_view()
  local session = session_for_action()
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
  local live_lines = vim.api.nvim_buf_get_lines(session.target_bufnr, 0, -1, false)
  if #replacement > 0 and lines_match_at(live_lines, start_index, replacement) then
    block.status = "accepted"
    block.was_forced = block.was_forced or opts.force == true
    block.conflict = nil
    update_hunk_status(block.hunk)
    return 0
  end
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
  local old_snapshot = vim.api.nvim_buf_get_lines(session.target_bufnr, start_index, end_index, false)
  vim.api.nvim_buf_set_lines(session.target_bufnr, start_index, end_index, false, replacement)
  block.status = "accepted"
  -- Record whether this block bypassed the live-content guard so the plan.md
  -- changelog and the digest's force-review can flag it.
  block.was_forced = opts.force == true
  block.conflict = nil
  session.applied[#session.applied + 1] = {
    block_id = block.id,
    old_start = block.old_start,
    delta = #block.new_lines - block.old_count,
  }
  session.applied_history = session.applied_history or {}
  session.applied_history[#session.applied_history + 1] = {
    block = block,
    block_id = block.id,
    start_index = start_index,
    old_lines = copy_lines(old_snapshot),
    new_lines = copy_lines(replacement),
  }
  -- Record per-block attribution. Anchored to the final accepted text in the
  -- file so a later edit that shifts line numbers doesn't lose the link.
  local ok_attr, attribution = pcall(require, "nvime.attribution")
  if ok_attr and attribution and #replacement > 0 then
    -- Compact snapshot of the pre-accept verify gate, so the permanent ledger
    -- records what the gate found (and whether it was force-bypassed) rather
    -- than discarding it. nil when verify never ran for this session, so a
    -- missing field reads as "n/a", not a fabricated clean result.
    local v = session.verify
    local verify_snapshot = nil
    if v then
      local checks = {}
      for name, c in pairs(v.by_check or {}) do
        checks[name] = (c and c.count) or 0
      end
      verify_snapshot = {
        status = v.status,
        parse_ok = not v.parse_error,
        -- "forced" here means this accept bypassed the verify gate (gA!) — a
        -- different force from the top-level `forced` (live-content conflict
        -- bypass). Kept distinct so a reviewer is never misled.
        forced = (opts.force == true) and (v.parse_error == true),
        checks = checks,
      }
    end
    pcall(attribution.record, {
      file = session.file,
      line1 = start_index + 1,
      line2 = start_index + #replacement,
      lines = replacement,
      rationale = session.rationale,
      user_rationale = session.user_rationale,
      verdict = session.verdict,
      verify = verify_snapshot,
      provider = session.provider,
      plan_id = session.plan_id,
      step_id = session.plan_step_id,
      forced = opts.force == true,
      diff_session_id = session.review_id,
    })
  end
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

local function remove_last_applied_delta(session, entry)
  for index = #(session.applied or {}), 1, -1 do
    local applied = session.applied[index]
    if
      applied
      and (applied.block_id == entry.block_id or applied.old_start == (entry.block and entry.block.old_start))
    then
      table.remove(session.applied, index)
      return
    end
  end
end

function M.undo_last_accept()
  local session = session_for_action()
  if not session then
    vim.notify("No active nvime diff for the current buffer", vim.log.levels.WARN)
    return
  end
  local history = session.applied_history or {}
  local entry = table.remove(history)
  if not entry then
    vim.notify("No accepted nvime block to undo", vim.log.levels.INFO)
    return
  end
  if not (session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr)) then
    vim.notify("The nvime diff target buffer is no longer valid", vim.log.levels.WARN)
    history[#history + 1] = entry
    return
  end
  reconcile_live_state(session)
  history = session.applied_history or {}
  if not entry.block or entry.block.status ~= "accepted" then
    entry = table.remove(history)
    if not entry then
      vim.notify("No accepted nvime block to undo", vim.log.levels.INFO)
      return
    end
  end

  local start_index = math.max(0, math.min(entry.start_index or 0, target_line_count(session)))
  local end_index = math.max(start_index, math.min(start_index + #(entry.new_lines or {}), target_line_count(session)))
  local live_lines = vim.api.nvim_buf_get_lines(session.target_bufnr, start_index, end_index, false)
  if not same_lines(live_lines, entry.new_lines or {}) then
    history[#history + 1] = entry
    vim.notify("Cannot undo nvime block because the accepted text changed", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_buf_set_lines(session.target_bufnr, start_index, end_index, false, entry.old_lines or {})
  local block = entry.block
  if block then
    block.status = "pending"
    block.conflict = nil
    update_hunk_status(block.hunk)
  end
  if not session_is_active(session) then
    set_active_session(session)
  end
  remove_last_applied_delta(session, entry)
  audit.write({
    event = "block_undo_applied",
    file = session.file,
    block_id = entry.block_id,
    start_line = start_index + 1,
  })
  mark_model_synced(session)
  render_session(session)
end

function M.accept_blocks(blocks, opts)
  opts = opts or {}
  local session = (blocks and blocks[1] and blocks[1].session) or session_for_action()
  if not session then
    vim.notify("No active nvime diff for the current buffer", vim.log.levels.WARN)
    return
  end
  reconcile_live_state(session)
  if not blocks or #blocks == 0 then
    vim.notify("No pending nvime line change selected", vim.log.levels.WARN)
    return
  end

  -- Pre-accept verify gate. A parse error in the proposed file refuses
  -- silent ga/gA; gA!/`:NvimeAccept!` still works and logs a
  -- verify_force audit event so the digest can surface it.
  local ok_verify, verify = pcall(require, "nvime.verify")
  if ok_verify and verify and type(verify.should_block_accept) == "function" then
    local should_block, reason = verify.should_block_accept(session)
    if should_block and not opts.force then
      vim.notify("nvime verify: " .. (reason or "blocked"), vim.log.levels.WARN)
      audit.write({
        event = "verify_block",
        file = session.file,
        reason = reason,
      })
      return
    end
    if should_block and opts.force then
      audit.write({
        event = "verify_force",
        file = session.file,
        reason = reason,
      })
    end
  end

  -- Unified accept policy (S1): critic verdict / risk level / external verify
  -- findings, each gated per diff.accept_policy. Defaults are all "off", so
  -- this is inert unless a user opts a signal into warn/confirm/block.
  if not enforce_accept_policy(session, opts) then
    return
  end

  -- High-risk force-accept confirmation. Only fires when (1) opts.force is
  -- set (gA!), (2) the risk score is `high`, and (3) the user has not
  -- disabled the confirm. Writes a `risk_force` audit event on proceed.
  if opts.force then
    local ok_risk, risk = pcall(require, "nvime.risk")
    if ok_risk and risk and type(risk.confirm_force_accept) == "function" then
      if not risk.confirm_force_accept(session) then
        vim.notify("nvime risk: force-accept cancelled", vim.log.levels.INFO)
        return
      end
    end
  end

  -- Per-path policy gate at accept time. The lane entry points already
  -- gate, but a paste-in patch or chat-driven diff can sidestep that;
  -- re-evaluate here against the proposed change size so max_changed_lines
  -- and `require_human` rules still apply.
  local ok_policy_accept, policy_rules_accept = pcall(require, "nvime.policy_rules")
  if ok_policy_accept and policy_rules_accept and type(policy_rules_accept.guard) == "function" then
    local changed_lines = 0
    for _, block_entry in ipairs(blocks) do
      local block_obj = block_entry
      changed_lines = changed_lines + (block_obj.old_count or 0) + #(block_obj.new_lines or {})
    end
    if not policy_rules_accept.guard(session.file, "accept", { changed_lines = changed_lines }) then
      return
    end
    -- require_rationale_typed_by_user: when the matched rule asks for one,
    -- prompt the user to type a sentence-shaped justification and store it
    -- on the session. It is later attached to every attribution entry for
    -- these blocks. Skip the prompt if the session already captured one
    -- (multi-block accepts shouldn't re-prompt) or in non-interactive mode.
    local eval = policy_rules_accept.evaluate(session.file, "accept", { changed_lines = changed_lines })
    if eval.require_rationale_typed_by_user and not session.user_rationale then
      if opts.user_rationale and opts.user_rationale ~= "" then
        session.user_rationale = opts.user_rationale
      elseif vim.env.NVIME_NONINTERACTIVE == "1" then
        vim.notify(
          "nvime policy: this path requires a user rationale; pass opts.user_rationale or run interactively",
          vim.log.levels.WARN
        )
        audit.write({
          event = "policy_rationale_missing",
          file = session.file,
          rule = eval.rule and eval.rule.match,
        })
        return
      else
        local typed = vim.fn.input({
          prompt = string.format("nvime policy (%s): one-line rationale: ", eval.rule and eval.rule.match or "?"),
          cancelreturn = "",
        })
        if not typed or vim.trim(typed) == "" then
          vim.notify("nvime policy: rationale required; accept cancelled", vim.log.levels.WARN)
          audit.write({
            event = "policy_rationale_missing",
            file = session.file,
            rule = eval.rule and eval.rule.match,
          })
          return
        end
        session.user_rationale = vim.trim(typed)
      end
      audit.write({
        event = "policy_rationale_recorded",
        file = session.file,
        rule = eval.rule and eval.rule.match,
        rationale = session.user_rationale,
      })
    end
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
  mark_model_synced(session)
  refresh_verify(session)
  render_session(session)
end

function M.reject_blocks(blocks)
  local session = (blocks and blocks[1] and blocks[1].session) or session_for_action()
  if not session then
    vim.notify("No active nvime diff for the current buffer", vim.log.levels.WARN)
    return
  end
  reconcile_live_state(session)
  if not blocks or #blocks == 0 then
    vim.notify("No pending nvime line change selected", vim.log.levels.WARN)
    return
  end

  for _, block in ipairs(blocks) do
    reject_block(block)
  end
  mark_model_synced(session)
  refresh_verify(session)
  render_session(session)
end

function M.accept_hunks(hunks, opts)
  local session = (hunks and hunks[1] and hunks[1].blocks and hunks[1].blocks[1] and hunks[1].blocks[1].session)
    or session_for_action()
  if not session then
    vim.notify("No active nvime diff for the current buffer", vim.log.levels.WARN)
    return
  end
  if not hunks or #hunks == 0 then
    vim.notify("No diff hunk selected", vim.log.levels.WARN)
    return
  end

  local blocks = {}
  reconcile_live_state(session)
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
  local session = (hunks and hunks[1] and hunks[1].blocks and hunks[1].blocks[1] and hunks[1].blocks[1].session)
    or session_for_action()
  if not session or not hunks or #hunks == 0 then
    return
  end
  local blocks = {}
  reconcile_live_state(session)
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
  local session = session_for_action()
  if not session then
    return
  end
  reconcile_live_state(session)
  M.accept_blocks({ current_block(session) })
end

function M.accept_selection()
  local session = session_for_action()
  if not session then
    return
  end
  reconcile_live_state(session)
  local first, last = selected_lines()
  M.accept_blocks(blocks_in_range(session, first, last))
end

function M.reject_current()
  local session = session_for_action()
  if not session then
    return
  end
  reconcile_live_state(session)
  M.reject_blocks({ current_block(session) })
end

function M.reject_selection()
  local session = session_for_action()
  if not session then
    return
  end
  reconcile_live_state(session)
  local first, last = selected_lines()
  M.reject_blocks(blocks_in_range(session, first, last))
end

function M.accept_current_group(opts)
  local session = session_for_action()
  if not session then
    return
  end
  reconcile_live_state(session)
  local group = current_group(session)
  if not group then
    vim.notify("No pending nvime change block selected", vim.log.levels.WARN)
    return
  end
  M.accept_blocks(group.blocks, opts)
end

function M.reject_current_group()
  local session = session_for_action()
  if not session then
    return
  end
  reconcile_live_state(session)
  local group = current_group(session)
  if not group then
    vim.notify("No pending nvime change block selected", vim.log.levels.WARN)
    return
  end
  M.reject_blocks(group.blocks)
end

function M.accept_all(opts)
  opts = opts or {}
  local session = session_for_action()
  if not session then
    return
  end
  reconcile_live_state(session)
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
  local session = session_for_action()
  if not session then
    return
  end
  reconcile_live_state(session)
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
  local session = session_for_action()
  if not session then
    return
  end
  reconcile_live_state(session)
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
  local session = session_for_action()
  if not session then
    return
  end
  reconcile_live_state(session)
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
  local session = session_for_action()
  if not session then
    return
  end
  reconcile_live_state(session)
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
  local session = session_for_action()
  if not session then
    return
  end
  reconcile_live_state(session)
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

-- Verify-finding navigation (S3). Findings carry line/col; jump the cursor to
-- the next/previous one (relative to the cursor) in the target buffer and echo
-- the finding so the reviewer can act on it. Wraps around like next_change.
local map_proposed_line = session.map_proposed_line

-- Verify findings carry *proposed*-content line numbers; the diff target buffer
-- holds the live (partially-accepted) file, so the two diverge while blocks are
-- pending. Remap each finding's line into target coordinates before navigation
-- so ]v/[v land on the right line. Returns findings sorted by target line.
local function verify_findings(diff_session)
  local ok_verify, verify = pcall(require, "nvime.verify")
  if not (ok_verify and verify and type(verify.findings) == "function") then
    return {}
  end
  local findings = verify.findings(diff_session) or {}
  local out = {}
  for _, f in ipairs(findings) do
    local mapped = map_proposed_line(diff_session, f.line) or f.line
    out[#out + 1] = vim.tbl_extend("force", {}, f, { line = mapped })
  end
  table.sort(out, function(a, b)
    if a.line == b.line then
      return (a.col or 1) < (b.col or 1)
    end
    return a.line < b.line
  end)
  return out
end

-- ]v/[v are installed in both the target buffer and the proposed/review buffer.
-- verify_findings() returns finding.line in TARGET coordinates, so when nav is
-- pressed from the proposed buffer the cursor (in proposed coordinates) must be
-- remapped proposed->target before the comparison, or the first jump mixes
-- coordinate systems and can skip the nearest finding.
local function target_cursor_line(session)
  local cursor = vim.api.nvim_win_get_cursor(0)[1]
  local review = session.review
  if review and review.proposed_bufnr == vim.api.nvim_get_current_buf() then
    return map_proposed_line(session, cursor) or cursor
  end
  return cursor
end

local function jump_to_finding(session, finding)
  if not finding then
    vim.notify("No located nvime verify finding", vim.log.levels.INFO)
    return
  end
  focus_target(session)
  local line = math.max(1, math.min(finding.line, target_line_count(session)))
  vim.api.nvim_win_set_cursor(0, { line, math.max(0, (finding.col or 1) - 1) })
  local level = (finding.severity == "error") and vim.log.levels.WARN or vim.log.levels.INFO
  vim.notify(string.format("verify [%s] L%d: %s", finding.source or "?", finding.line, finding.message or ""), level)
end

function M.next_finding()
  local session = session_for_action()
  if not session then
    return
  end
  local findings = verify_findings(session)
  if #findings == 0 then
    vim.notify("No nvime verify findings to navigate", vim.log.levels.INFO)
    return
  end
  local cursor = target_cursor_line(session)
  for _, finding in ipairs(findings) do
    if finding.line > cursor then
      jump_to_finding(session, finding)
      return
    end
  end
  jump_to_finding(session, findings[1])
end

function M.prev_finding()
  local session = session_for_action()
  if not session then
    return
  end
  local findings = verify_findings(session)
  if #findings == 0 then
    vim.notify("No nvime verify findings to navigate", vim.log.levels.INFO)
    return
  end
  local cursor = target_cursor_line(session)
  for index = #findings, 1, -1 do
    if findings[index].line < cursor then
      jump_to_finding(session, findings[index])
      return
    end
  end
  jump_to_finding(session, findings[#findings])
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
  local session = session_for_action()
  if not session then
    return nil
  end
  reconcile_live_state(session)
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

-- Re-render an arbitrary session (used by the critic lane after its async
-- verdict lands so the diff banner gains a verdict badge).
function M.refresh_session(session)
  if session and session.target_bufnr and vim.api.nvim_buf_is_valid(session.target_bufnr) then
    render_session(session, { silent = true, focus = false })
  end
end

-- Internal: exposed so nvime.verify can read the post-accept proposed file
-- content without duplicating apply_blocks_to_lines. Underscore-prefixed
-- because it is not part of the public diff API.
function M._proposed_lines(session)
  return proposed_lines(session)
end

return M
