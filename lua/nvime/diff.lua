local audit = require("nvime.audit")
local git = require("nvime.git")
local state = require("nvime.state")
local ui = require("nvime.ui")

local M = {}

local uv = vim.uv or vim.loop

-- Shared core: namespace, list helpers, block model, and the live-content
-- reconciliation / conflict-detection engine. Aliased back to the local names
-- the rest of this module still uses (parser/render/ops sections below).
local shared = require("nvime.diff.shared")

-- Parser: agent-response → hunk parsing. Aliased back to the local names the
-- session builder / start_session below still use.
local parser = require("nvime.diff.parser")
local normalize_file_key = parser.normalize_file_key
local bracket_balance = parser.bracket_balance
local bracket_drift = parser.bracket_drift
local has_bracket_drift = parser.has_bracket_drift
local bracket_drift_summary = parser.bracket_drift_summary
local response_likely_truncated = parser.response_likely_truncated
local has_fence = parser.has_fence
local trim = parser.trim
local response_mode = parser.response_mode
local extract_unified = parser.extract_unified
local has_ranged_hunk = parser.has_ranged_hunk
local build_unranged_hunk = parser.build_unranged_hunk
local parse_hunks = parser.parse_hunks
local dedupe_hunks = parser.dedupe_hunks
local validate_current_file = parser.validate_current_file
local reanchor_hunks = parser.reanchor_hunks
local hunks_have_changes = parser.hunks_have_changes
local build_single_hunk = parser.build_single_hunk
local extract_rationale = parser.extract_rationale
local extract_verify_line = parser.extract_verify_line

-- Session core: registry/queue + inline renderer + review workspace.
local session = require("nvime.diff.session")
local register_session = session.register_session
local original_lines = session.original_lines
local proposed_lines = session.proposed_lines
M.current_session = session.current_session

function M.start_session(selection, response, provider, prompt)
  local rationale = extract_rationale(response)
  local verify_attestation = extract_verify_line(response)
  local mode, body = response_mode(response)
  body = body or response

  if mode == "NVIME_NO_CHANGE" then
    return {
      status = "no_change",
      message = trim(body) ~= "" and trim(body) or "agent reported no change needed",
      rationale = rationale,
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
    path_key = normalize_file_key(selection.path),
    bufnr = nil,
    target_bufnr = selection.bufnr,
    selection = selection,
    original_lines = vim.api.nvim_buf_get_lines(selection.bufnr, 0, -1, false),
    original_changedtick = vim.api.nvim_buf_get_changedtick(selection.bufnr),
    header = header,
    hunks = hunks,
    provider = provider,
    prompt = prompt,
    rationale = rationale,
    verify_attestation = verify_attestation,
    applied = {},
    applied_history = {},
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

  local registry_status = register_session(session)
  return {
    status = "diff",
    session = session,
    queued = registry_status == "queued",
  }
end

-- Ops: accept/reject/undo/navigation + review-window ops.
local ops = require("nvime.diff.ops")
M.open_view = ops.open_view
M.focus_editable = ops.focus_editable
M.refresh_view = ops.refresh_view
M.close_view = ops.close_view
M.undo_last_accept = ops.undo_last_accept
M.accept_blocks = ops.accept_blocks
M.reject_blocks = ops.reject_blocks
M.accept_hunks = ops.accept_hunks
M.reject_hunks = ops.reject_hunks
M.accept_current = ops.accept_current
M.accept_selection = ops.accept_selection
M.reject_current = ops.reject_current
M.reject_selection = ops.reject_selection
M.accept_current_group = ops.accept_current_group
M.reject_current_group = ops.reject_current_group
M.accept_all = ops.accept_all
M.reject_all = ops.reject_all
M.next_change = ops.next_change
M.next_group = ops.next_group
M.prev_change = ops.prev_change
M.prev_group = ops.prev_group
M.remaining_text = ops.remaining_text
M.refresh_session = ops.refresh_session
M._proposed_lines = ops._proposed_lines
return M
