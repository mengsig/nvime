-- nvime.bigchange.draft
--
-- The brief-authoring step that precedes intake. Instead of a one-line goal
-- prompt, the user writes a structured markdown brief (Title / Context / Goal /
-- Notes / Acceptance criteria) in a real editable buffer. The brief is
-- persisted on the session (session.draft) and autosaved, so you can leave and
-- come back: <leader>nB reopens an in-progress draft automatically.
--
-- Keys in the draft buffer:
--   <C-s>  submit  → brief becomes session.goal, hands off to intake
--   DD     discard → delete this draft and return to the picker
--   q      close   → save and hide (still in progress; reopen with <leader>nB)
--
-- The "# Title:" line drives session.title (the name shown in the picker),
-- updated live as you type.

local store = require("nvime.bigchange.store")
local uikit = require("nvime.bigchange.uikit")
local ui = require("nvime.ui")

local M = {}

local TEMPLATE = {
  "# Title: ",
  "",
  "## Context",
  "<!-- What exists today and why this change is needed. -->",
  "",
  "## Goal",
  "<!-- What the agent should build. Be concrete. -->",
  "",
  "## Notes",
  "<!-- Constraints, gotchas, file pointers (reference files with @path/to/file). -->",
  "",
  "## Acceptance criteria",
  "- [ ] ",
}

local view = {
  session = nil,
  bufnr = nil,
  winid = nil,
  save_timer = nil,
  augroup = vim.api.nvim_create_augroup("nvime.bigchange.draft", { clear = true }),
}

local function is_open()
  return view.winid and vim.api.nvim_win_is_valid(view.winid) and view.bufnr and vim.api.nvim_buf_is_valid(view.bufnr)
end

local function buffer_text()
  return table.concat(vim.api.nvim_buf_get_lines(view.bufnr, 0, -1, false), "\n")
end

-- Extract the title from the "# Title:" line (or the first markdown heading).
function M.parse_title(text)
  if not text then
    return nil
  end
  local t = text:match("#+%s*Title:%s*([^\n]*)")
  if t then
    t = vim.trim(t)
    if t ~= "" then
      return t
    end
  end
  return nil
end

local function save_now()
  if not is_open() then
    return
  end
  local session = view.session
  session.draft = buffer_text()
  local title = M.parse_title(session.draft)
  if title then
    session.title = title
  end
  store.touch(session)
end

local function schedule_save()
  if view.save_timer then
    pcall(function()
      view.save_timer:stop()
    end)
  end
  view.save_timer = vim.defer_fn(function()
    view.save_timer = nil
    save_now()
  end, 400)
end

-- ---------------------------------------------------------------------------
-- actions
-- ---------------------------------------------------------------------------
function M.close()
  save_now()
  if view.winid and vim.api.nvim_win_is_valid(view.winid) then
    pcall(vim.api.nvim_win_close, view.winid, true)
  end
  view.winid = nil
end

local function submit()
  save_now()
  local session = view.session
  local text = session.draft or ""
  if not M.parse_title(text) then
    vim.notify("nvime bigchange: add a '# Title:' before submitting the draft", vim.log.levels.WARN)
    return
  end
  session.goal = text
  session.status = store.STATUS.INTAKE
  store.touch(session)
  M.close()
  require("nvime.bigchange").open_session(session.id)
end

local function discard()
  local session = view.session
  local choice = vim.fn.confirm("Discard this draft?", "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end
  M.close()
  require("nvime.bigchange").discard(session.id)
  require("nvime.bigchange.picker").open()
end

-- ---------------------------------------------------------------------------
-- open
-- ---------------------------------------------------------------------------
local function install_keymaps(bufnr)
  vim.keymap.set({ "i", "n" }, "<C-s>", submit, { buffer = bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "DD", discard, { buffer = bufnr, nowait = true, silent = true })
  vim.keymap.set("n", "q", M.close, { buffer = bufnr, nowait = true, silent = true })
end

function M.open(session)
  if is_open() and view.session and view.session.id == session.id then
    vim.api.nvim_set_current_win(view.winid)
    return
  end
  if is_open() then
    M.close()
  end
  view.session = session

  view.bufnr, view.winid = uikit.open_float({
    title = ui.icon("brand") .. "  Draft brief",
    footer = "<C-s> submit · DD discard · q close",
    width_ratio = 0.7,
    height_ratio = 0.78,
    min_width = 64,
    min_height = 18,
    filetype = "markdown",
    wrap = true,
  })

  local seed = (session.draft and session.draft ~= "") and vim.split(session.draft, "\n", { plain = true }) or TEMPLATE
  vim.bo[view.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(view.bufnr, 0, -1, false, seed)

  install_keymaps(view.bufnr)

  -- Autosave as the user types (debounced) and on leaving the buffer.
  vim.api.nvim_clear_autocmds({ group = view.augroup })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = view.augroup,
    buffer = view.bufnr,
    callback = schedule_save,
  })
  vim.api.nvim_create_autocmd("BufWinLeave", {
    group = view.augroup,
    buffer = view.bufnr,
    callback = save_now,
  })

  -- Fresh template → drop the cursor on the Title line ready to type.
  if seed == TEMPLATE then
    pcall(vim.api.nvim_win_set_cursor, view.winid, { 1, #TEMPLATE[1] })
    vim.cmd("startinsert")
  end
end

return M
