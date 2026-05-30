-- nvime.bigchange.diffparse
--
-- Minimal unified-diff parser. Turns `git diff` output into a flat list of
-- hunks, each carrying a stable id ("<file>#<n>") so semantic blocks can
-- reference hunks without depending on line numbers that shift between rounds.

local M = {}

-- Parse unified diff text into a list of hunks:
--   { id, file, header, old_start, new_start,
--     lines = { { kind = "add"|"del"|"ctx", text, old_line?, new_line? } } }
function M.parse(text)
  local hunks = {}
  if not text or text == "" then
    return hunks
  end
  local current_file = nil
  local per_file = {}
  local hunk = nil
  local old_line, new_line = 0, 0
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^diff %-%-git ") then
      hunk = nil
      -- Prefer the b/ path from the diff header; +++ refines it below.
      current_file = line:match("^diff %-%-git a/.+ b/(.+)$") or current_file
    elseif line:match("^%+%+%+ ") then
      local path = line:match("^%+%+%+ b/(.+)$") or line:match("^%+%+%+ (.+)$")
      if path and path ~= "/dev/null" then
        current_file = path
      end
    elseif line:match("^%-%-%- ") then
      -- old-side path; new-side (+++) is authoritative for our purposes
    elseif line:match("^@@") then
      local os_, ns_ = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
      old_line = tonumber(os_) or 0
      new_line = tonumber(ns_) or 0
      local key = current_file or "?"
      per_file[key] = (per_file[key] or 0) + 1
      hunk = {
        id = key .. "#" .. per_file[key],
        file = key,
        header = line,
        old_start = old_line,
        new_start = new_line,
        lines = {},
      }
      hunks[#hunks + 1] = hunk
    elseif hunk then
      local first = line:sub(1, 1)
      if first == "+" then
        hunk.lines[#hunk.lines + 1] = { kind = "add", text = line:sub(2), new_line = new_line }
        new_line = new_line + 1
      elseif first == "-" then
        hunk.lines[#hunk.lines + 1] = { kind = "del", text = line:sub(2), old_line = old_line }
        old_line = old_line + 1
      elseif first == " " then
        hunk.lines[#hunk.lines + 1] = { kind = "ctx", text = line:sub(2), old_line = old_line, new_line = new_line }
        old_line = old_line + 1
        new_line = new_line + 1
      elseif first == "\\" then
        -- "\ No newline at end of file" — ignore
      end
    end
  end
  return hunks
end

-- A content signature over a hunk's add/del lines, used to carry a block's
-- cleared/graded state across grading rounds when its content is unchanged.
function M.hunk_signature(hunk)
  local parts = { hunk.file }
  for _, l in ipairs(hunk.lines) do
    if l.kind ~= "ctx" then
      parts[#parts + 1] = l.kind .. ":" .. l.text
    end
  end
  return table.concat(parts, "\n")
end

-- Count added / removed lines across a set of hunks.
function M.stats(hunks)
  local added, removed = 0, 0
  for _, h in ipairs(hunks) do
    for _, l in ipairs(h.lines) do
      if l.kind == "add" then
        added = added + 1
      elseif l.kind == "del" then
        removed = removed + 1
      end
    end
  end
  return added, removed
end

return M
