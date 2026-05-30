-- nvime.bigchange.intake
--
-- Stage 2: the clarifying-questions phase. A read-only scrollback float where
-- the agent interrogates the user about WHAT to build, one topic at a time,
-- until it writes a spec wrapped in <SPEC>…</SPEC>. The user then approves,
-- edits, or asks for more questions. On approval we hand off to the build
-- stage. The agent runs read-only ("critic" lane) in the real repo so it can
-- read the codebase to ask informed questions.

local agent = require("nvime.bigchange.agent")
local store = require("nvime.bigchange.store")
local uikit = require("nvime.bigchange.uikit")
local ui = require("nvime.ui")

local M = {}

local view = {
  session = nil,
  bufnr = nil,
  winid = nil,
  ns = vim.api.nvim_create_namespace("nvime.bigchange.intake"),
  busy = false,
  status = nil,
}

local function is_open()
  return view.winid and vim.api.nvim_win_is_valid(view.winid) and view.bufnr and vim.api.nvim_buf_is_valid(view.bufnr)
end

local function spec_ready(session)
  return session.spec and session.spec ~= ""
end

-- ---------------------------------------------------------------------------
-- render
-- ---------------------------------------------------------------------------
local function push(lines, marks, text, hl)
  lines[#lines + 1] = text
  if hl then
    marks[#marks + 1] = { #lines, 0, -1, hl }
  end
  return #lines
end

local function push_wrapped(lines, marks, text, hl, indent)
  indent = indent or "    "
  for _, paragraph in ipairs(vim.split(text or "", "\n", { plain = true })) do
    if paragraph == "" then
      lines[#lines + 1] = ""
    else
      lines[#lines + 1] = indent .. paragraph
      if hl then
        marks[#marks + 1] = { #lines, 0, -1, hl }
      end
    end
  end
end

local function render()
  if not is_open() then
    return
  end
  local session = view.session
  ui.ensure_highlights()
  local lines, marks = {}, {}

  push(lines, marks, "  " .. ui.icon("brand") .. "  " .. (session.title or "Big Change") .. " — intake", "NvimeTitle")
  local diff = store.DIFFICULTY[session.difficulty] or { label = session.difficulty, detail = "" }
  push(lines, marks, "  Difficulty: " .. (diff.label or "?") .. " — " .. (diff.detail or ""), "NvimeMuted")
  push(
    lines,
    marks,
    "  ───────────────────────────────────────────────",
    "NvimeRule"
  )
  push(lines, marks, "")

  for _, turn in ipairs(session.intake_history or {}) do
    if turn.role == "user" then
      push(lines, marks, "  ❯ you", "NvimeSection")
      push_wrapped(lines, marks, turn.content, "NvimeUserText")
    else
      push(lines, marks, "  " .. ui.icon("brand") .. " agent", "NvimeAgent")
      push_wrapped(lines, marks, turn.content, "NvimeNormal")
    end
    push(lines, marks, "")
  end

  if view.busy then
    push(lines, marks, "  ● " .. (view.status or "agent is thinking…"), "NvimeStatusRunning")
    push(lines, marks, "")
  end

  if spec_ready(session) then
    push(
      lines,
      marks,
      "  ┌─ SPEC ──────────────────────────────────────",
      "NvimeStatusSuccess"
    )
    push_wrapped(lines, marks, session.spec, "NvimeNormal", "  │ ")
    push(
      lines,
      marks,
      "  └─────────────────────────────────────────────",
      "NvimeStatusSuccess"
    )
    push(lines, marks, "")
    push(lines, marks, "  [a] approve & build · [e] edit spec · [m] more questions · q close", "NvimeHelp")
  elseif not view.busy then
    push(lines, marks, "  [i] answer · [m] answer · q close", "NvimeHelp")
  end

  vim.bo[view.bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(view.bufnr, 0, -1, false, lines)
  vim.bo[view.bufnr].modifiable = false
  uikit.apply_marks(view.bufnr, view.ns, lines, marks)

  -- Keep the newest content in view.
  if is_open() then
    pcall(vim.api.nvim_win_set_cursor, view.winid, { #lines, 0 })
  end
end

-- ---------------------------------------------------------------------------
-- agent turns
-- ---------------------------------------------------------------------------
local function handle_response(text, result)
  view.busy = false
  view.status = nil
  local session = view.session
  if result and result.code and result.code ~= 0 and (not text or text == "") then
    session.intake_history[#session.intake_history + 1] =
      { role = "assistant", content = "[the agent run failed — press q, then reopen to retry]" }
    store.touch(session)
    render()
    return
  end
  local spec = agent.extract_spec(text)
  local display = text
  if spec then
    -- Strip the spec envelope from the transcript line; show it in the box.
    display = vim.trim(text:gsub("<SPEC>.-</SPEC>", "📋 Spec ready — review below."))
    session.spec = spec
  end
  if display and display ~= "" then
    session.intake_history[#session.intake_history + 1] = { role = "assistant", content = display }
  end
  store.touch(session)
  render()
end

local function run_turn(prompt, resume)
  local session = view.session
  view.busy = true
  view.status = "agent is thinking…"
  render()
  agent.turn({
    session = session,
    lane = "critic",
    prompt = prompt,
    resume = resume,
    on_progress = function(line)
      view.status = vim.trim((line or ""):gsub("\n", " "))
      vim.schedule(render)
    end,
    on_done = handle_response,
  })
end

local function kickoff()
  run_turn(agent.intake_kickoff_prompt(view.session), false)
end

local function answer()
  if view.busy then
    vim.notify("nvime bigchange: agent is still thinking", vim.log.levels.INFO)
    return
  end
  uikit.input({ title = "Your answer (intake)" }, function(text)
    if not text or text == "" then
      return
    end
    view.session.intake_history[#view.session.intake_history + 1] = { role = "user", content = text }
    -- A fresh answer invalidates any previously proposed spec.
    view.session.spec = nil
    run_turn(text, true)
  end)
end

local function edit_spec()
  if not spec_ready(view.session) then
    return
  end
  uikit.input({ title = "Edit spec", initial = view.session.spec, height = 16 }, function(text)
    view.session.spec = vim.trim(text)
    store.touch(view.session)
    render()
  end)
end

local function approve()
  if not spec_ready(view.session) then
    vim.notify("nvime bigchange: no spec to approve yet", vim.log.levels.INFO)
    return
  end
  view.session.spec_approved = true
  store.touch(view.session)
  M.close()
  require("nvime.bigchange.build").start(view.session)
end

-- ---------------------------------------------------------------------------
-- open / close
-- ---------------------------------------------------------------------------
function M.close()
  if view.winid and vim.api.nvim_win_is_valid(view.winid) then
    pcall(vim.api.nvim_win_close, view.winid, true)
  end
  view.winid = nil
end

local function install_keymaps(bufnr)
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = bufnr, silent = true, nowait = true })
  end
  map("i", answer)
  map("<CR>", answer)
  map("m", answer)
  map("a", approve)
  map("e", edit_spec)
  map("q", M.close)
  map("<Esc>", M.close)
end

function M.open(session)
  view.session = session
  view.busy = false
  if not is_open() then
    view.bufnr, view.winid = uikit.open_float({
      title = ui.icon("brand") .. "  Intake",
      width_ratio = 0.78,
      height_ratio = 0.78,
      min_width = 60,
      min_height = 16,
      wrap = true,
    })
    install_keymaps(view.bufnr)
  else
    vim.api.nvim_set_current_win(view.winid)
  end

  render()
  -- Auto-start the interrogation when this is a fresh intake.
  if #(session.intake_history or {}) == 0 and not spec_ready(session) and not view.busy then
    kickoff()
  end
end

return M
