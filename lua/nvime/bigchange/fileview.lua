-- nvime.bigchange.fileview
--
-- Render a session's captured diff onto the REAL worktree file buffers, so the
-- review reads like a normal file instead of opaque diff text: LSP go-to-
-- definition, treesitter highlighting, search, and editing all keep working.
--
-- For the file currently shown we:
--   * tint added/changed lines (background only, so syntax stays intact) and
--     drop a "+" sign in the gutter,
--   * render removed lines as red virtual lines above their anchor,
--   * record each hunk's first buffer line so ]c / [c can jump between the
--     change chunks.
--
-- The buffer holds the POST-change file (it lives on disk in the worktree), so
-- a hunk's new-side line numbers map directly onto buffer line numbers.

local M = {}

local DIFF_NS = vim.api.nvim_create_namespace("nvime.bigchange.fileview.diff")
M.DIFF_NS = DIFF_NS

-- Every captured hunk that belongs to `file` (a worktree-relative path).
function M.hunks_for_file(session, file)
  local out = {}
  for _, h in ipairs(session.diff_hunks or {}) do
    if h.file == file then
      out[#out + 1] = h
    end
  end
  return out
end

local function buf_line_count(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return 0
  end
  return vim.api.nvim_buf_line_count(bufnr)
end

-- Clamp a 1-based new-side line number into the buffer's real line range.
local function clamp(bufnr, line)
  local total = buf_line_count(bufnr)
  if total == 0 then
    return 0
  end
  if line < 1 then
    return 1
  end
  if line > total then
    return total
  end
  return line
end

-- Apply inline diff annotations for `hunks` onto `bufnr` (the real, post-change
-- file). Returns { anchors = sorted buffer lines that start each hunk,
-- by_hunk = { [hunk.id] = first buffer line } } so callers can drive ]c/[c and
-- jump straight to a specific block's first hunk.
function M.apply(bufnr, hunks)
  local result = { anchors = {}, by_hunk = {} }
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return result
  end
  vim.api.nvim_buf_clear_namespace(bufnr, DIFF_NS, 0, -1)
  local total = buf_line_count(bufnr)
  if total == 0 then
    return result
  end

  for _, hunk in ipairs(hunks or {}) do
    local pending = {} -- removed lines awaiting a virt_lines flush
    local anchor_for_hunk = nil
    local last_new = hunk.new_start or 1

    -- Flush queued removals as red virtual lines above buffer line `at`.
    local function flush_removals(at)
      if #pending == 0 then
        return
      end
      local anchor, above = at, true
      if anchor < 1 then
        anchor = 1
      end
      if anchor > total then
        anchor, above = total, false
      end
      local virt = {}
      for _, rem in ipairs(pending) do
        virt[#virt + 1] = { { "- " .. rem.text, "NvimeDiffDelete" } }
      end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, DIFF_NS, anchor - 1, 0, {
        virt_lines = virt,
        virt_lines_above = above,
      })
      pending = {}
    end

    for _, l in ipairs(hunk.lines or {}) do
      if l.kind == "del" then
        pending[#pending + 1] = l
      elseif l.kind == "add" and l.new_line then
        last_new = l.new_line
        local anchor = clamp(bufnr, l.new_line)
        flush_removals(anchor)
        if anchor >= 1 then
          pcall(vim.api.nvim_buf_set_extmark, bufnr, DIFF_NS, anchor - 1, 0, {
            line_hl_group = "NvimeDiffAddLine",
            sign_text = "+ ",
            sign_hl_group = "NvimeDiffAdd",
          })
          anchor_for_hunk = anchor_for_hunk or anchor
        end
      elseif l.kind == "ctx" and l.new_line then
        last_new = l.new_line
        local anchor = clamp(bufnr, l.new_line)
        flush_removals(anchor)
        anchor_for_hunk = anchor_for_hunk or anchor
      end
    end
    -- Removals trailing the hunk (pure deletion at its tail) anchor just below
    -- the last new-side line they followed.
    if #pending > 0 then
      flush_removals(clamp(bufnr, last_new + 1))
    end

    local anchor = anchor_for_hunk or clamp(bufnr, hunk.new_start or 1)
    if anchor >= 1 then
      result.anchors[#result.anchors + 1] = anchor
      result.by_hunk[hunk.id] = anchor
    end
  end

  table.sort(result.anchors)
  return result
end

-- Clear the diff annotations from a buffer (e.g. when it is reloaded).
function M.clear(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, DIFF_NS, 0, -1)
  end
end

-- Move the cursor in `winid` to the next (dir=1) or previous (dir=-1) hunk
-- anchor, wrapping around. Returns true if it moved.
function M.jump(winid, anchors, dir)
  if not (winid and vim.api.nvim_win_is_valid(winid)) then
    return false
  end
  if not anchors or #anchors == 0 then
    return false
  end
  local cur = vim.api.nvim_win_get_cursor(winid)[1]
  local target
  if dir > 0 then
    for _, a in ipairs(anchors) do
      if a > cur then
        target = a
        break
      end
    end
    target = target or anchors[1]
  else
    for i = #anchors, 1, -1 do
      if anchors[i] < cur then
        target = anchors[i]
        break
      end
    end
    target = target or anchors[#anchors]
  end
  pcall(vim.api.nvim_win_set_cursor, winid, { target, 0 })
  pcall(vim.api.nvim_win_call, winid, function()
    vim.cmd("normal! zz")
  end)
  return true
end

return M
