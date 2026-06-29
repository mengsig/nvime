-- nvime.bigchange.diffparse
--
-- Minimal unified-diff parser. Turns `git diff` output into a flat list of
-- hunks, each carrying a stable id ("<file>#<n>") so semantic blocks can
-- reference hunks without depending on line numbers that shift between rounds.

local M = {}

-- Parse unified diff text into a list of hunks:
--   { id, file, header, old_start, new_start,
--     lines = { { kind = "add"|"del"|"ctx", text, old_line?, new_line? } } }
--
-- Binary blobs, pure renames/copies, and mode-only changes carry NO @@ hunk, so
-- a hunk-only parser is blind to them — yet they DO land at merge (the merge
-- applies `git diff --binary`). To keep them from slipping into a Big Change
-- merge unreviewed, we emit one synthetic META hunk per such file so it surfaces
-- as a visible (un-gradeable) review row. A meta hunk is marked `meta =
-- "binary"|"rename"|"copy"|"mode"` and carries a single `kind = "meta"` line
-- describing the change.
function M.parse(text)
  local hunks = {}
  if not text or text == "" then
    return hunks
  end
  local current_file = nil
  local per_file = {}
  local hunk = nil
  local old_line, new_line = 0, 0
  -- File-level changes with no content hunk, keyed by file path. `has_hunk`
  -- marks files that produced a real @@ hunk (so their change is already
  -- reviewable and needs no synthetic row).
  local file_meta = {}
  local meta_order = 0
  local function file_block(key)
    if not file_meta[key] then
      meta_order = meta_order + 1
      file_meta[key] = { order = meta_order }
    end
    return file_meta[key]
  end
  local rename_from = nil
  for line in (text .. "\n"):gmatch("(.-)\n") do
    if line:match("^diff %-%-git ") then
      hunk = nil
      rename_from = nil
      -- Prefer the b/ path from the diff header; +++ refines it below.
      current_file = line:match("^diff %-%-git a/.+ b/(.+)$") or current_file
    elseif line:match("^%+%+%+ ") then
      local path = line:match("^%+%+%+ b/(.+)$") or line:match("^%+%+%+ (.+)$")
      if path and path ~= "/dev/null" then
        current_file = path
      end
    elseif line:match("^%-%-%- ") then
      -- old-side path; new-side (+++) is authoritative for our purposes
    elseif line:match("^rename from ") or line:match("^copy from ") then
      rename_from = line:match("^%a+ from (.+)$")
    elseif line:match("^rename to ") or line:match("^copy to ") then
      local to = line:match("^%a+ to (.+)$")
      local kind = line:match("^rename ") and "rename" or "copy"
      local key = to or current_file or "?"
      current_file = key
      local fb = file_block(key)
      fb.kind = kind
      fb.detail = string.format("%s %s → %s", kind == "copy" and "copied" or "renamed", rename_from or "?", to or "?")
    elseif line:match("^Binary files ") or line:match("^GIT binary patch") then
      local fb = file_block(current_file or "?")
      fb.kind = "binary"
      fb.detail = "binary file changed (" .. (current_file or "?") .. ")"
    elseif line:match("^old mode ") or line:match("^new mode ") then
      local fb = file_block(current_file or "?")
      if not fb.kind then
        fb.kind = "mode"
        fb.detail = "file mode changed (" .. (current_file or "?") .. ")"
      end
    elseif line:match("^@@") then
      local os_, ns_ = line:match("^@@ %-(%d+),?%d* %+(%d+),?%d* @@")
      old_line = tonumber(os_) or 0
      new_line = tonumber(ns_) or 0
      local key = current_file or "?"
      if file_meta[key] then
        file_meta[key].has_hunk = true
      end
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
  -- Emit synthetic meta hunks for file-level changes that produced no content
  -- hunk (binary blobs, pure renames/copies, mode-only changes), in the order
  -- their headers appeared, so they surface as visible review rows.
  local metas = {}
  for key, fb in pairs(file_meta) do
    if fb.kind and not fb.has_hunk then
      metas[#metas + 1] = { key = key, fb = fb }
    end
  end
  table.sort(metas, function(a, b)
    return a.fb.order < b.fb.order
  end)
  for _, m in ipairs(metas) do
    per_file[m.key] = (per_file[m.key] or 0) + 1
    hunks[#hunks + 1] = {
      id = m.key .. "#" .. per_file[m.key],
      file = m.key,
      header = m.fb.detail,
      old_start = 0,
      new_start = 0,
      meta = m.fb.kind,
      lines = { { kind = "meta", text = m.fb.detail } },
    }
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
