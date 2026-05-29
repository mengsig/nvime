-- nvime.send
--
-- Send file references into the active chat conversation via @path mentions,
-- bound to <leader>ns. Two entry points:
--   * M.send()           — normal mode. In netrw, stages the marked files (or
--                          the entry under the cursor); in any other buffer,
--                          stages the current file.
--   * M.send_visual(opts)— visual mode. Stages the current file plus the
--                          highlighted line range, e.g. `@path (lines 10-25)`.
--
-- References are *appended* to the last chat's input (never clobbered), so you
-- can stack several files/selections into one message before submitting. We
-- send a bare @path mention rather than embedding code: the chat replays its
-- full transcript every turn, so a reference stays cheap where inlined code
-- would be re-sent on every subsequent message. The agent reads the exact
-- lines on demand via its Read tool.

local git = require("nvime.git")

local M = {}

local function relpath(path)
  if not path or path == "" then
    return nil
  end
  return git.repo_relative_path(path) or path
end

-- Build the @reference line for a path, optionally annotated with a line range.
local function reference(path, line1, line2)
  local rel = relpath(path)
  if not rel then
    return nil
  end
  local ref = "@" .. rel
  if line1 and line2 then
    if line1 == line2 then
      ref = ref .. string.format(" (line %d)", line1)
    else
      ref = ref .. string.format(" (lines %d-%d)", line1, line2)
    end
  end
  return ref
end

-- Resolve the file path(s) to send from the current buffer.
-- netrw: marked files if any, else the entry under the cursor.
-- anything else: the current buffer's file.
local function targets_for_current_buffer()
  if vim.bo.filetype == "netrw" then
    return M._netrw_targets()
  end
  local name = vim.api.nvim_buf_get_name(0)
  if not name or name == "" then
    return {}
  end
  return { vim.fn.fnamemodify(name, ":p") }
end

-- Collect file paths from a netrw buffer. Returns a list of absolute paths.
function M._netrw_targets()
  -- 1. Marked files take priority (mf marks). `s:netrwmarkfilelist` holds the
  --    complete paths; netrw#Expose returns "n/a" (a string) when unset.
  local ok_marks, marked = pcall(vim.fn["netrw#Expose"], "netrwmarkfilelist")
  if ok_marks and type(marked) == "table" and #marked > 0 then
    local out = {}
    for _, p in ipairs(marked) do
      out[#out + 1] = vim.fn.fnamemodify(p, ":p")
    end
    return out
  end

  -- 2. Otherwise, the entry under the cursor. NetrwGetWord returns a name
  --    relative to b:netrw_curdir (directories keep a trailing marker).
  local word
  local ok_word, w = pcall(vim.fn["netrw#Call"], "NetrwGetWord")
  if ok_word and type(w) == "string" then
    word = w
  end
  if not word or word == "" then
    word = vim.fn.expand("<cfile>")
  end
  word = (word or ""):gsub("[%*@/]+$", "") -- strip netrw type markers / trailing slash
  if word == "" or word == "." or word == ".." then
    return {}
  end

  local dir = vim.b.netrw_curdir
  local full
  if word:sub(1, 1) == "/" then
    full = word
  elseif dir and dir ~= "" then
    full = dir .. "/" .. word
  else
    full = word
  end
  return { vim.fn.fnamemodify(full, ":p") }
end

-- Append a list of @reference lines, as one block, to the most-recently-opened
-- conversation — the same target <leader>nn reopens. Routes to whichever lane
-- (chat or selection discussion) owns that conversation; falls back to a fresh
-- chat when none exists yet.
local function stage(refs)
  if #refs == 0 then
    vim.notify("nvime send: no file to send", vim.log.levels.WARN)
    return
  end
  local block = table.concat(refs, "\n")
  local target = require("nvime").resolve_last()
  local where = "new chat"
  if target and target.kind == "selection" then
    require("nvime.selection").append_prompt(block, target.id)
    where = "last discussion"
  else
    require("nvime.chat").append_prompt(block, target and target.id or nil)
    where = target and "last chat" or "new chat"
  end
  local label = #refs == 1 and refs[1] or string.format("%d files", #refs)
  vim.notify(string.format("nvime: staged %s in %s", label, where), vim.log.levels.INFO)
end

function M.send()
  local paths = targets_for_current_buffer()
  local refs = {}
  for _, path in ipairs(paths) do
    local ref = reference(path)
    if ref then
      refs[#refs + 1] = ref
    end
  end
  stage(refs)
end

function M.send_visual(opts)
  opts = opts or {}
  local name = vim.api.nvim_buf_get_name(0)
  if not name or name == "" then
    vim.notify("nvime send: current buffer has no file", vim.log.levels.WARN)
    return
  end
  local line1, line2 = opts.line1, opts.line2
  if line1 and line2 and line1 > line2 then
    line1, line2 = line2, line1
  end
  local ref = reference(vim.fn.fnamemodify(name, ":p"), line1, line2)
  stage(ref and { ref } or {})
end

return M
