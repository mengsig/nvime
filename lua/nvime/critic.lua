local agents = require("nvime.agents")
local audit = require("nvime.audit")
local state = require("nvime.state")

local M = {}

-- Verdict shape: { decision = "APPROVE"|"FLAG"|"REJECT", justification = "..." }

local CRITIC_PROMPT_HEADER = table.concat({
  "NVIME PATCH CRITIC MODE.",
  "",
  "You are a critical reviewer of a proposed patch produced by a constrained patch worker.",
  "Your job is NOT to be agreeable. Find genuine reasons the patch should not land.",
  "You are read-only: you may use Read/Grep/Glob/LS to inspect the repository, but you cannot edit anything.",
  "",
  "Apply this critical lens, in order:",
  "  1. Does the patch actually solve the stated problem?",
  "  2. Does it introduce a new bug, break adjacent behavior, or violate a documented contract?",
  "  3. Is there a clearly simpler change that achieves the same goal?",
  "  4. Did the patch worker overreach (add defensive code, type checks, comments, or speculative changes outside the bug)?",
  "",
  "Output FORMAT (mandatory — the parser only reads the first verdict line):",
  "  - The FIRST non-empty line of your response MUST start with one of:",
  "      APPROVE",
  "      FLAG",
  "      REJECT",
  "    followed by a colon, a hyphen, or whitespace, then a one-sentence justification.",
  "  - Plain ASCII only on the verdict line. No markdown bold (**, __), no",
  "    backticks, no list markers (- / 1.), no headers (#), no blockquote (>).",
  "    Just `APPROVE: ...` / `FLAG: ...` / `REJECT: ...` flush left.",
  "  - One line. No multi-line essays. The parser stops at the newline.",
  "",
  "Examples:",
  "  APPROVE: minimal rename, semantics unchanged.",
  "  FLAG: this also touches the cache invalidation path; review that.",
  "  REJECT: the new branch removes the nil guard at line 42.",
  "",
  "Bias: prefer FLAG over REJECT unless the patch is unambiguously wrong. Prefer APPROVE only when you can name what the patch does correctly. The user makes the final call; your verdict is advisory.",
  "",
}, "\n")

local function build_critic_prompt(opts)
  local selection = opts.selection or {}
  local diff_text = opts.diff_text or "(empty diff)"
  local rationale = opts.rationale or "(no rationale provided)"
  local intent = opts.intent or "(no intent recorded)"
  local context = opts.context or "(no context lines)"
  local lines = { CRITIC_PROMPT_HEADER }
  lines[#lines + 1] = "File: " .. (selection.path or "?")
  lines[#lines + 1] = "Range: " .. tostring(selection.line1 or "?") .. "-" .. tostring(selection.line2 or "?")
  lines[#lines + 1] = ""
  lines[#lines + 1] = "User intent (verbatim):"
  lines[#lines + 1] = intent
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Patch worker's stated rationale:"
  lines[#lines + 1] = rationale
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Proposed patch (unified diff):"
  lines[#lines + 1] = "```diff"
  lines[#lines + 1] = diff_text
  lines[#lines + 1] = "```"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Selected range with surrounding context:"
  lines[#lines + 1] = "```"
  lines[#lines + 1] = context
  lines[#lines + 1] = "```"
  return table.concat(lines, "\n")
end

-- Parse APPROVE/FLAG/REJECT verdict from raw agent output. Real-world
-- responses arrive with markdown decoration (`**APPROVE**`), unicode em
-- dashes, leading list/header markers, mixed case, etc. We strip noise
-- aggressively and look for the verdict word as the first word of any
-- non-empty line.
local function parse_verdict(text)
  if type(text) ~= "string" or text == "" then
    return nil
  end
  -- Strip markdown emphasis pairs first so "**APPROVE**: text" becomes
  -- "APPROVE: text". Strip backticks too in case the agent quoted the
  -- verdict word.
  local cleaned = text:gsub("%*%*", ""):gsub("__", ""):gsub("``+", "")
  local decisions = { "APPROVE", "FLAG", "REJECT" }

  for _, raw in ipairs(vim.split(cleaned, "\n", { plain = true })) do
    -- Strip leading whitespace, common prose noise:
    --   "## APPROVE..."  → header markers
    --   "> APPROVE..."   → blockquote
    --   "- APPROVE..."   → bullet
    --   "1. APPROVE..."  → ordered list
    --   "`APPROVE`..."   → inline code
    --   "*APPROVE*..."   → italic emphasis (single)
    local trimmed = raw
      :gsub("^%s+", "")
      :gsub("^[#>]+%s*", "")
      :gsub("^[%-%*%+]%s+", "")
      :gsub("^%d+[%.%)]%s+", "")
      :gsub("^[`*_]+", "")
      :gsub("[`*_]+$", "")
      :gsub("^%s+", "")
    if trimmed ~= "" then
      local upper = trimmed:upper()
      for _, decision in ipairs(decisions) do
        if upper:sub(1, #decision) == decision then
          local next_byte = upper:byte(#decision + 1)
          -- Verdict word must be at a word boundary: end of string, or
          -- the next char is non-word. Prevents matching "APPROVED" /
          -- "APPROVES" / "REJECTING" as the verdict.
          local boundary = next_byte == nil or not string.char(next_byte):match("[%w_]")
          if boundary then
            local after = trimmed:sub(#decision + 1)
            -- Strip any leading non-word run (covers ":", "-", em dash,
            -- en dash, periods, multiple whitespace, mixed punctuation).
            after = after:gsub("^[^%w]+", "")
            return {
              decision = decision,
              justification = vim.trim(after),
            }
          end
        end
      end
    end
  end
  return nil
end

local function diff_text_from_session(session)
  if not session or not session.hunks then
    return ""
  end
  local out = {}
  if session.file then
    out[#out + 1] = "--- a/" .. session.file
    out[#out + 1] = "+++ b/" .. session.file
  end
  for _, hunk in ipairs(session.hunks) do
    for _, line in ipairs(hunk.lines or {}) do
      out[#out + 1] = line
    end
  end
  return table.concat(out, "\n")
end

local function context_from_session(session, pad)
  pad = pad or 4
  if not session or not session.target_bufnr or not vim.api.nvim_buf_is_valid(session.target_bufnr) then
    return ""
  end
  local total = vim.api.nvim_buf_line_count(session.target_bufnr)
  local sel = session.selection or {}
  local first = math.max(1, (tonumber(sel.line1) or 1) - pad)
  local last = math.min(total, (tonumber(sel.line2) or total) + pad)
  local lines = vim.api.nvim_buf_get_lines(session.target_bufnr, first - 1, last, false)
  local out = {}
  for index, line in ipairs(lines) do
    out[#out + 1] = string.format("%4d  %s", first + index - 1, line)
  end
  return table.concat(out, "\n")
end

-- Public: review the patch on a freshly created diff session. Runs the critic
-- agent asynchronously; sets session.verdict + triggers a re-render so the
-- diff banner gains a verdict badge.
function M.review(session, opts)
  opts = opts or {}
  if not session or not session.target_bufnr then
    return
  end
  if session.critic_started then
    return
  end
  session.critic_started = true
  session.verdict = nil
  session.verdict_pending = true

  local provider = opts.provider or session.provider or (state.config and state.config.provider) or "claude"
  local diff_text = diff_text_from_session(session)
  local context = context_from_session(session)
  local prompt = build_critic_prompt({
    selection = session.selection,
    diff_text = diff_text,
    rationale = session.rationale or opts.rationale,
    intent = opts.intent,
    context = context,
  })

  audit.write({
    event = "critic_start",
    provider = provider,
    file = session.file,
    line1 = session.selection and session.selection.line1,
    line2 = session.selection and session.selection.line2,
  })

  local response = {}
  agents.run({
    provider = provider,
    lane = "critic",
    prompt = prompt,
    on_text = function(text)
      response[#response + 1] = text
    end,
    on_progress = function() end,
    on_exit = function(result)
      local raw = table.concat(response)
      local verdict = parse_verdict(raw)
      if not verdict and result.code == 0 then
        -- Treat unparseable but successful runs as advisory FLAG, but
        -- include the actual response snippet so the user can see WHAT
        -- the critic said instead of getting a useless "review manually"
        -- placeholder. Find the first non-empty line for the snippet.
        local snippet = nil
        for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
          local s = vim.trim(line)
          if s ~= "" then
            snippet = s
            break
          end
        end
        if snippet and #snippet > 200 then
          snippet = snippet:sub(1, 197) .. "..."
        end
        verdict = {
          decision = "FLAG",
          justification = "no APPROVE/FLAG/REJECT line found; agent said: "
            .. (snippet and ('"' .. snippet .. '"') or "(empty response)"),
        }
      end
      audit.write({
        event = "critic_exit",
        provider = provider,
        code = result.code,
        decision = verdict and verdict.decision or "ERROR",
        raw_response_excerpt = raw:sub(1, 500),
      })
      vim.schedule(function()
        session.verdict_pending = false
        session.verdict = verdict
        if verdict then
          local hl = (verdict.decision == "APPROVE" and vim.log.levels.INFO)
            or (verdict.decision == "FLAG" and vim.log.levels.WARN)
            or vim.log.levels.ERROR
          vim.notify("nvime critic " .. verdict.decision .. ": " .. (verdict.justification or ""), hl)
        end
        -- Re-render the diff so the new banner appears.
        local ok_diff, diff = pcall(require, "nvime.diff")
        if ok_diff and diff and type(diff.refresh_session) == "function" then
          diff.refresh_session(session)
        end
      end)
    end,
  })
end

M._parse_verdict = parse_verdict -- exposed for tests

return M
