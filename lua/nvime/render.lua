local ui = require("nvime.ui")

local M = {}

local function provider_group(provider)
  if provider == "claude" then
    return "NvimeProviderClaude"
  end
  if provider == "codex" then
    return "NvimeProviderCodex"
  end
  return "NvimePrompt"
end

local HEADING_HL = {
  [1] = "NvimeMarkdownH1",
  [2] = "NvimeMarkdownH2",
  [3] = "NvimeMarkdownH3",
  [4] = "NvimeMarkdownH4",
  [5] = "NvimeMarkdownH5",
  [6] = "NvimeMarkdownH6",
}

-- Find the next non-overlapping span matching `pat` in `line` starting at
-- byte offset `from`. Returns (start_byte, end_byte, capture_text) or nil.
-- Spans are returned in 1-based inclusive byte coordinates relative to the
-- line, matching what nvim_buf_set_extmark expects after subtracting 1.
local function find_span(line, from, pat)
  local s, e, body = line:find(pat, from)
  if not s then
    return nil
  end
  return s, e, body
end

-- Inline span scanner. Walks a single line and emits styled spans for:
--   `code`        → NvimeMarkdownInlineCode
--   **strong**    → NvimeMarkdownStrong (already partially handled below)
--   *em* / _em_   → NvimeMarkdownEmphasis (with word-boundary checks so the
--                    `*` in a bullet or argv quote isn't mistaken for italic)
--   ~~strike~~    → NvimeMarkdownStrike
--   [text](url)   → NvimeMarkdownLinkText + NvimeMarkdownLinkUrl
-- Returns a list of { start, finish, hl } in display order. Caller is
-- responsible for applying them via nvim_buf_set_extmark.
--
-- Order of detection matters: we walk the line left-to-right and grab the
-- earliest match each pass, then advance past it. This is intentional —
-- Lua's pattern engine is not regex, and trying to compose alternation
-- gets brittle. A scanned approach also makes priority obvious: inline
-- code bodies are NOT scanned for further markdown (so `*foo*` inside a
-- backtick stays plain), matching CommonMark.
local function inline_spans(line)
  local spans = {}
  if line == nil or line == "" then
    return spans
  end
  -- Pre-skip leading list / quote markers when computing spans so an
  -- emphasis inside a bullet still scans the body. We only want to skip
  -- markers from inline scanning; the line-level marker highlighting is
  -- already applied by the caller.
  local cursor = 1
  while cursor <= #line do
    -- Inline code: backtick spans, e.g. `foo bar`. Disallow embedded
    -- backticks per CommonMark; multi-backtick fences (``a`b``) are
    -- intentionally not handled here because they're rare in agent prose.
    local code_s, code_e = line:find("`[^`\n]+`", cursor)
    -- Bold: **foo** (greedy enough that **a*b** still scans correctly).
    local bold_s, bold_e = line:find("%*%*[^%*]-%*%*", cursor)
    if not bold_s then
      bold_s, bold_e = line:find("__[^_]-__", cursor)
    end
    -- Strikethrough: ~~foo~~
    local strike_s, strike_e = line:find("~~[^~]-~~", cursor)
    -- Link: [text](url) — non-greedy on body, url is anything up to `)`
    local link_s, link_e, link_text_s, link_text_e, link_url_s, link_url_e
    do
      local s, e = line:find("%[[^%]\n]-%]%([^%)\n]-%)", cursor)
      if s then
        link_s, link_e = s, e
        local text_close = line:find("]", s + 1, true)
        if text_close then
          link_text_s = s + 1
          link_text_e = text_close - 1
          link_url_s = text_close + 2 -- skip ]( prefix
          link_url_e = e - 1
        else
          link_s, link_e = nil, nil
        end
      end
    end
    -- Emphasis: *foo* / _foo_ — word-boundary aware so we don't match
    -- a single asterisk used as a bullet or an underscore in an
    -- identifier. We require non-space immediately after the opener
    -- and immediately before the closer.
    local em_s, em_e
    do
      local s = cursor
      while true do
        local m_s, m_e, body = line:find("%*([^%*\n]-)%*", s)
        if not m_s then
          break
        end
        local prev = m_s == 1 and "" or line:sub(m_s - 1, m_s - 1)
        local nextc = m_e == #line and "" or line:sub(m_e + 1, m_e + 1)
        local body_first = body and body:sub(1, 1) or ""
        local body_last = body and body:sub(-1) or ""
        local valid = body
          and body ~= ""
          and not body_first:match("%s")
          and not body_last:match("%s")
          and not prev:match("[%w_*]")
          and not nextc:match("[%w_*]")
        if valid then
          em_s, em_e = m_s, m_e
          break
        end
        s = m_e + 1
      end
      if not em_s then
        local s2 = cursor
        while true do
          local m_s, m_e, body = line:find("_([^_\n]-)_", s2)
          if not m_s then
            break
          end
          local prev = m_s == 1 and "" or line:sub(m_s - 1, m_s - 1)
          local nextc = m_e == #line and "" or line:sub(m_e + 1, m_e + 1)
          local body_first = body and body:sub(1, 1) or ""
          local body_last = body and body:sub(-1) or ""
          local valid = body
            and body ~= ""
            and not body_first:match("%s")
            and not body_last:match("%s")
            and not prev:match("[%w_]")
            and not nextc:match("[%w_]")
          if valid then
            em_s, em_e = m_s, m_e
            break
          end
          s2 = m_e + 1
        end
      end
    end

    -- Pick the earliest matching span. If two start at the same byte,
    -- prefer the longer one (so **bold** wins over *em* at the same
    -- index).
    local candidates = {}
    if code_s then
      candidates[#candidates + 1] = { code_s, code_e, "code" }
    end
    if bold_s then
      candidates[#candidates + 1] = { bold_s, bold_e, "bold" }
    end
    if strike_s then
      candidates[#candidates + 1] = { strike_s, strike_e, "strike" }
    end
    if link_s then
      candidates[#candidates + 1] = { link_s, link_e, "link" }
    end
    if em_s then
      candidates[#candidates + 1] = { em_s, em_e, "em" }
    end
    if #candidates == 0 then
      break
    end
    table.sort(candidates, function(a, b)
      if a[1] == b[1] then
        return (a[2] - a[1]) > (b[2] - b[1])
      end
      return a[1] < b[1]
    end)
    local s, e, kind = candidates[1][1], candidates[1][2], candidates[1][3]

    if kind == "code" then
      spans[#spans + 1] = { s, e, "NvimeMarkdownInlineCode" }
    elseif kind == "bold" then
      spans[#spans + 1] = { s, e, "NvimeMarkdownStrong" }
    elseif kind == "strike" then
      spans[#spans + 1] = { s, e, "NvimeMarkdownStrike" }
    elseif kind == "em" then
      spans[#spans + 1] = { s, e, "NvimeMarkdownEmphasis" }
    elseif kind == "link" then
      spans[#spans + 1] = { link_s, link_text_s - 1, "NvimeMarkdownPunct" } -- the [
      spans[#spans + 1] = { link_text_s, link_text_e, "NvimeMarkdownLinkText" }
      spans[#spans + 1] = { link_text_e + 1, link_url_s - 1, "NvimeMarkdownPunct" } -- ](
      spans[#spans + 1] = { link_url_s, link_url_e, "NvimeMarkdownLinkUrl" }
      spans[#spans + 1] = { link_e, link_e, "NvimeMarkdownPunct" } -- )
    end
    cursor = e + 1
  end
  return spans
end

M.inline_spans = inline_spans

function M.scrollback(bufnr, ns)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local in_code = false
  local code_lang = nil

  -- Width of the text area of the window showing this buffer, used to suppress
  -- right-aligned badges that would otherwise overlay (hide) the last
  -- characters of a long line — e.g. the "user" badge over a long prompt you
  -- are still typing.
  local badge_avail = nil
  do
    local win = vim.fn.bufwinid(bufnr)
    if win ~= -1 then
      local info = vim.fn.getwininfo(win)[1]
      if info then
        badge_avail = info.width - (info.textoff or 0)
      end
    end
  end

  local function mark(row, start_col, end_col, group, opts)
    if row < 0 or row >= #lines then
      return
    end
    local line_len = #(lines[row + 1] or "")
    start_col = math.max(0, math.min(start_col, line_len))
    end_col = math.max(start_col, math.min(end_col, line_len))
    if start_col == end_col then
      return
    end
    opts = opts or {}
    opts.end_col = end_col
    opts.hl_group = group
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, start_col, opts)
  end

  local function mark_line(row, group)
    if row < 0 or row >= #lines then
      return
    end
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      end_col = #(lines[row + 1] or ""),
      hl_group = group,
      hl_eol = true,
    })
  end

  local function label(row, text, group)
    if row < 0 or row >= #lines then
      return
    end
    -- Drop the badge rather than let it cover real text: a right-aligned
    -- virt_text is painted at the window edge even when the line reaches it.
    if badge_avail then
      local line_w = vim.fn.strdisplaywidth(lines[row + 1] or "")
      local text_w = vim.fn.strdisplaywidth(text)
      if line_w + text_w + 1 > badge_avail then
        return
      end
    end
    vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
      virt_text = { { text, group or "NvimeMuted" } },
      virt_text_pos = "right_align",
      priority = 120,
    })
  end

  -- Apply intra-line spans (inline code, bold, italic, strike, link). We
  -- skip this inside fenced code blocks because their bodies are literal
  -- code, not prose.
  local function apply_inline(row, line)
    if line == nil or line == "" then
      return
    end
    for _, span in ipairs(inline_spans(line)) do
      mark(row, span[1] - 1, span[2], span[3])
    end
  end

  for index, line in ipairs(lines) do
    local row = index - 1
    if line:match("^```") then
      mark(row, 0, #line, "NvimeCodeFence")
      local lang = vim.trim(line:gsub("^```", ""))
      if lang ~= "" then
        label(row, lang, "NvimeCodeLang")
      end
      if in_code then
        in_code = false
        code_lang = nil
      else
        in_code = true
        code_lang = vim.trim(line:gsub("^```", ""))
      end
    elseif in_code then
      if code_lang == "diff" and line:match("^%+") and not line:match("^%+%+%+") then
        mark_line(row, "NvimeDiffAdd")
      elseif code_lang == "diff" and line:match("^%-") and not line:match("^%-%-%-") then
        mark_line(row, "NvimeDiffDelete")
      elseif code_lang == "diff" and line:match("^@@") then
        mark_line(row, "NvimeDiffHunk")
      else
        mark_line(row, "NvimeCode")
      end
    elseif line:match("^%[[^%]]+%]%$") then
      local provider = line:match("^%[([^%s%]]+)")
      local finish = line:find("%$") or #line
      mark(row, 0, finish + 1, "NvimePrompt")
      if provider then
        mark(row, 1, 1 + #provider, provider_group(provider))
      end
      if finish + 1 < #line then
        mark(row, finish + 1, #line, "NvimeUserText")
      end
      label(row, "user", "NvimeMuted")
    elseif line:match("^%[[^%]]+ response%]$") then
      local provider = line:match("^%[([^%s%]]+)")
      mark(row, 0, #line, "NvimeAgent")
      if provider then
        mark(row, 1, 1 + #provider, provider_group(provider))
      end
      label(row, ui.icon("review") .. " agent", "NvimeAgent")
    elseif line:match("^%[[^%]]+ selection question%]$") then
      mark(row, 0, #line, "NvimeAgent")
      label(row, ui.icon("selection") .. " selection", "NvimeAgent")
    elseif line:match("^%[nvime%]") then
      mark(row, 0, #line, "NvimeExit")
    elseif line:match("^%[error%]") or line:match("^%[failed%]") then
      mark(row, 0, #line, "NvimeError")
    elseif line:match("^#+%s+") then
      -- Heading: color the hash markers muted, the body by level. Levels
      -- 1-3 are bold + saturated; 4-6 fall back to italic muted so
      -- agent-emitted "##### sub-sub" stays distinguishable but doesn't
      -- shout. Markers stay visible (no concealing) so the original text
      -- is preserved exactly.
      local hashes = line:match("^(#+)") or "#"
      local level = math.min(#hashes, 6)
      mark(row, 0, #hashes, "NvimeMarkdownHeadingMarker")
      local body_start = #hashes
      while body_start < #line and line:byte(body_start + 1) == string.byte(" ") do
        body_start = body_start + 1
      end
      mark(row, body_start, #line, HEADING_HL[level] or "NvimeMarkdownHeading")
      apply_inline(row, line)

      -- Decorative virt_lines above H1/H2/H3 to break the section visually
      -- from preceding prose. Pure decoration: the buffer line count and
      -- text content are unchanged, so copy/paste / yank / save still
      -- return exactly what the agent generated. Skip when the heading
      -- is at the very top of the buffer or when the previous buffer
      -- line is already blank (would double the spacing).
      if level <= 3 and row > 0 then
        local prev_line = lines[row] or ""
        if vim.trim(prev_line) ~= "" then
          local virt_line
          if level <= 2 then
            -- H1/H2 get a thin dim rule above so the section break reads
            -- as a chapter marker.
            virt_line = { { string.rep("─", 60), "NvimeMarkdownHeadingMarker" } }
          else
            -- H3 gets only an extra blank line — a softer break.
            virt_line = { { "", "NvimeMarkdownHeadingMarker" } }
          end
          vim.api.nvim_buf_set_extmark(bufnr, ns, row, 0, {
            virt_lines = { virt_line },
            virt_lines_above = true,
            priority = 100,
          })
        end
      end
    elseif line:match("^%s*[-*+]%s+") then
      -- Unordered bullet: highlight the marker, then process inline
      -- spans on the body so `**bold**` and `*em*` still render even
      -- when nested inside a list item.
      local indent_end, marker_end = line:find("^(%s*)([-*+])")
      if indent_end and marker_end then
        local marker_col = line:find("[-*+]")
        if marker_col then
          mark(row, marker_col - 1, marker_col, "NvimeBullet")
        end
      end
      apply_inline(row, line)
    elseif line:match("^%s*%d+[%.%)]%s+") then
      -- Numbered list: 1. foo / 2) bar. Highlight the number+punct as
      -- the bullet glyph; rest gets inline span treatment.
      local s, e = line:find("^%s*%d+[%.%)]")
      if s and e then
        mark(row, s - 1, e, "NvimeBulletNumber")
      end
      apply_inline(row, line)
    elseif line:match("^%s*>%s?") then
      mark_line(row, "NvimeQuote")
      -- Soft visual gutter: render a `▎` glyph in the gutter via overlay
      -- so the blockquote has a visible vertical bar without modifying
      -- the buffer text.
      local indent = line:match("^(%s*)>") or ""
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, #indent, {
        virt_text = { { "▎", "NvimeQuoteGutter" } },
        virt_text_pos = "overlay",
        priority = 110,
      })
      apply_inline(row, line)
    elseif line:match("^@@") then
      mark_line(row, "NvimeDiffHunk")
    elseif line:match("^%+") and not line:match("^%+%+%+") then
      mark_line(row, "NvimeDiffAdd")
    elseif line:match("^%-") and not line:match("^%-%-%-") and not line:match("^%-%-+$") then
      mark_line(row, "NvimeDiffDelete")
    elseif line:match("^[=-]+$") then
      mark(row, 0, #line, "NvimeRule")
    else
      apply_inline(row, line)
    end
  end
end

function M.input(bufnr, ns, prompt_prefix, start_lnum, opts)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  opts = opts or {}
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  start_lnum = start_lnum or 1
  local prompt_lnum = start_lnum
  if lines[start_lnum] and not vim.startswith(lines[start_lnum], prompt_prefix) then
    vim.api.nvim_buf_set_extmark(bufnr, ns, start_lnum - 1, 0, {
      end_col = #lines[start_lnum],
      hl_group = "NvimeInputStatus",
    })
    prompt_lnum = start_lnum + 1
  end
  local prompt_line = lines[prompt_lnum] or ""
  if vim.startswith(prompt_line, prompt_prefix) then
    vim.api.nvim_buf_set_extmark(bufnr, ns, prompt_lnum - 1, 0, {
      end_col = #prompt_prefix,
      hl_group = "NvimeInputPrompt",
    })
    if #prompt_line > #prompt_prefix then
      vim.api.nvim_buf_set_extmark(bufnr, ns, prompt_lnum - 1, #prompt_prefix, {
        end_col = #prompt_line,
        hl_group = "NvimeUserText",
      })
    elseif opts.show_ghost ~= false then
      vim.api.nvim_buf_set_extmark(bufnr, ns, prompt_lnum - 1, #prompt_prefix, {
        virt_text = { { opts.ghost or "type a message", "NvimeInputGhost" } },
        virt_text_pos = "eol",
        priority = 90,
      })
    end
    if opts.divider ~= false then
      local rule_width = opts.rule_width or vim.o.columns
      local winid = vim.fn.bufwinid(bufnr)
      if winid > 0 then
        rule_width = vim.api.nvim_win_get_width(winid)
      end
      rule_width = math.max(20, rule_width - 2)
      local virt_lines = {}
      if opts.busy_status and opts.busy_status ~= "" then
        local pad = math.max(0, rule_width - vim.fn.strdisplaywidth(opts.busy_status))
        virt_lines[#virt_lines + 1] = {
          { string.rep(" ", pad), "" },
          { opts.busy_status, "NvimeStatusRunning" },
        }
      end
      virt_lines[#virt_lines + 1] = { { string.rep("─", rule_width), "NvimeRule" } }
      vim.api.nvim_buf_set_extmark(bufnr, ns, prompt_lnum - 1, 0, {
        virt_lines = virt_lines,
        virt_lines_above = true,
        priority = 80,
      })
    end
  end
end

function M.spinner_text(seed)
  local cfg = (require("nvime.state").config or {}).ui or {}
  local frames = cfg.spinner_frames
  if type(frames) ~= "table" or #frames == 0 then
    frames = cfg.ascii_icons == true and { "-", "\\", "|", "/" }
      or { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  end
  if tonumber(seed) then
    seed = tonumber(seed)
  else
    local uv = vim.uv or vim.loop
    seed = uv and uv.hrtime and math.floor(uv.hrtime() / 120000000) or os.time()
  end
  return frames[(seed % #frames) + 1]
end

return M
