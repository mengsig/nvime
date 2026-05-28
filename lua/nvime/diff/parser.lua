-- nvime.diff.parser
--
-- Protocol/diff parsing: turns an agent response (NVIME_DIFF / NVIME_REPLACEMENT
-- / a unified diff, with optional RATIONALE:/VERIFY: lines and code fences) into
-- the hunk list that the block model builds from. Pure text transforms plus a
-- few buffer reads for anchoring; no render/registry/ops dependencies.

local shared = require("nvime.diff.shared")
local same_lines = shared.same_lines
local line_slice = shared.line_slice

local function normalize_file_key(path)
  if not path or path == "" then
    return nil
  end
  path = tostring(path):gsub("\\", "/")
  path = path:gsub('^"', ""):gsub('"$', "")
  path = path:gsub("^a/", ""):gsub("^b/", ""):gsub("^%./", "")
  return path
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
  return normalize_file_key(path)
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

-- Capture an optional `RATIONALE:` block emitted before the first NVIME_*
-- marker. The protocol allows a single rationale paragraph (one line, or
-- multi-line continuation lines indented by ≥2 spaces) so the patch worker
-- has to justify its change before the diff is shown to the user. We stop
-- collecting at the first NVIME_* marker or at any new top-level "tag" line
-- so a stray BENCH:/etc line in perf mode doesn't get absorbed.
local function extract_rationale(response)
  if type(response) ~= "string" or response == "" then
    return nil
  end
  local lines = split_lines(response)
  local out = {}
  local started = false
  for _, line in ipairs(lines) do
    if line:match("^%s*NVIME_[A-Z_]+%s*$") or line:match("^%s*```") then
      break
    end
    local rationale_start = line:match("^%s*RATIONALE:%s*(.*)$")
    if rationale_start then
      started = true
      if rationale_start ~= "" then
        out[#out + 1] = rationale_start
      end
    elseif started then
      if line:match("^%s*$") then
        -- Blank line ends the rationale paragraph.
        if #out > 0 then
          break
        end
      elseif line:match("^%s%s") then
        out[#out + 1] = vim.trim(line)
      else
        -- A non-indented, non-blank line after rationale starts is treated
        -- as the boundary; further lines aren't part of the rationale.
        break
      end
    end
  end
  if #out == 0 then
    return nil
  end
  return table.concat(out, " ")
end

-- Capture an optional single-line `VERIFY:` attestation emitted before the
-- first NVIME_* marker. Surfaced verbatim in the banner so the user can see
-- the agent's self-check before nvime re-runs the same checks on this end.
local function extract_verify_line(response)
  if type(response) ~= "string" or response == "" then
    return nil
  end
  for _, line in ipairs(split_lines(response)) do
    if line:match("^%s*NVIME_[A-Z_]+%s*$") or line:match("^%s*```") then
      return nil
    end
    local body = line:match("^%s*VERIFY:%s*(.*)$")
    if body and body ~= "" then
      return vim.trim(body)
    end
  end
  return nil
end

local M = {}
M.normalize_file_key = normalize_file_key
M.split_lines = split_lines
M.count_pattern = count_pattern
M.bracket_balance = bracket_balance
M.bracket_drift = bracket_drift
M.has_bracket_drift = has_bracket_drift
M.bracket_drift_summary = bracket_drift_summary
M.response_likely_truncated = response_likely_truncated
M.fence_marker = fence_marker
M.closing_fence_marker = closing_fence_marker
M.fenced_body = fenced_body
M.strip_fence = strip_fence
M.has_fence = has_fence
M.trim = trim
M.normalize_mode_boundaries = normalize_mode_boundaries
M.response_mode = response_mode
M.fenced_diff_body = fenced_diff_body
M.extract_unified = extract_unified
M.has_ranged_hunk = has_ranged_hunk
M.locate_sequence = locate_sequence
M.unranged_diff_lines = unranged_diff_lines
M.build_unranged_hunk = build_unranged_hunk
M.parse_hunks = parse_hunks
M.dedupe_hunks = dedupe_hunks
M.clean_diff_path = clean_diff_path
M.validate_current_file = validate_current_file
M.hunk_old_new_lines = hunk_old_new_lines
M.hunk_has_change = hunk_has_change
M.sequence_at = sequence_at
M.reanchor_hunks = reanchor_hunks
M.hunks_have_changes = hunks_have_changes
M.build_single_hunk = build_single_hunk
M.extract_rationale = extract_rationale
M.extract_verify_line = extract_verify_line
return M
