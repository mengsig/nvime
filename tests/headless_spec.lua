local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")

local fake_claude = root .. "/tests/fixtures/claude"
local audit_path = tmp .. "/audit.jsonl"
local sessions_path = tmp .. "/selection-sessions.json"
local chat_sessions_path = tmp .. "/chat-sessions.json"

require("nvime").setup({
  provider = "claude",
  providers = {
    claude = {
      cmd = fake_claude,
    },
    codex = {
      cmd = fake_claude,
    },
  },
  audit = {
    path = audit_path,
    log_prompts = true,
  },
  sessions = {
    path = sessions_path,
    chat_path = chat_sessions_path,
  },
  test_loop = {
    enabled = false,
  },
  guard = {
    notify = false,
    block_cmdline = false,
  },
  risk = {
    -- Tests run in a long-lived audit/attribution dir; AI-share can climb
    -- above 0.5 and trip the high-risk force-accept prompt, which
    -- vim.fn.confirm cancels by default in headless mode. Disable the
    -- confirm so existing force-accept tests keep their semantics.
    confirm_on_force_high = false,
  },
})

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error((label or "assert_eq") .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
  end
end

assert(vim.fn.maparg("<leader>nr", "n") ~= "", "default review keymap exists")
assert(vim.fn.maparg("<leader>ne", "x") ~= "", "default visual edit keymap exists")
assert(vim.fn.maparg("<leader>nq", "x") ~= "", "default visual ask keymap exists")
assert(vim.fn.maparg("<leader>n<Space>", "n") == "<Cmd>Nvime<CR>", "default dashboard keymap opens command center")
assert(vim.fn.maparg("<leader>nc", "n") == "<Cmd>NvimeChat<CR>", "default normal chat keymap opens chat picker")
assert(vim.fn.maparg("<leader>ne", "n") == "<Cmd>NvimeChats edit<CR>", "default normal edit keymap opens edit picker")
assert(vim.fn.maparg("<leader>nq", "n") == "<Cmd>NvimeChats ask<CR>", "default normal ask keymap opens ask picker")
assert(vim.fn.maparg("<leader>nn", "n") ~= "", "default normal last-session keymap exists")
assert(vim.fn.maparg("<leader>np", "n") ~= "", "default provider keymap exists")
assert(vim.fn.maparg("<leader>nv", "n") ~= "", "default diff review keymap exists");
(function()
  local state = require("nvime.state")
  vim.keymap.set("n", "<leader>nc", "<Cmd>let g:nvime_user_chat_map = 1<CR>", { silent = true })
  require("nvime").setup(state.config)
  assert_eq(
    vim.fn.maparg("<leader>nc", "n"),
    "<Cmd>let g:nvime_user_chat_map = 1<CR>",
    "identical setup does not clobber user maps"
  )
  local forced_config = vim.deepcopy(state.config)
  forced_config.force = true
  require("nvime").setup(forced_config)
  assert_eq(vim.fn.maparg("<leader>nc", "n"), "<Cmd>NvimeChat<CR>", "force setup re-installs nvime maps")
end)()
assert_eq(
  require("nvime.progress").compact("[claude] tool: Bash: rg README"),
  "claude Bash",
  "claude progress footer keeps tool name"
)
assert_eq(
  require("nvime.progress").compact([[[codex] tool: /usr/bin/zsh -lc "sed -n '1,260p' README.md"]]),
  "codex tool",
  "codex command progress footer hides command text"
)
assert(vim.fn.exists(":Nvime") == 2, "Nvime command center command exists")
assert(vim.fn.exists(":NvimeDiff") == 2, "Nvime diff review command exists")
assert(vim.fn.exists(":NvimeCancel") == 2, "Nvime cancel command exists")
assert(vim.fn.exists(":NvimeDisable") == 2, "Nvime disable command exists")
assert(vim.fn.exists(":NvimeEnable") == 2, "Nvime enable command exists")
assert_eq(require("nvime.version").label(), "v0.3.0", "version label is centralized")
assert(vim.fn.exists(":NvimePlan") == 2, "NvimePlan command exists")
do
  local warnings = require("nvime.config").validate({
    provdier = "codex",
    ui = {
      width = "wide",
    },
    providers = {
      localai = {
        cmd = 42,
      },
    },
  })
  assert(#warnings >= 3, "config validation warns on unknown keys and wrong types")
end
do
  -- triviality: self-evident Big Change review blocks auto-clear without a
  -- graded explanation on easy/medium difficulty.
  local triviality = require("nvime.bigchange.triviality")
  local function hunks_of(file, lines)
    local hl = {}
    for _, l in ipairs(lines) do
      hl[#hl + 1] = { kind = l[1], text = l[2] }
    end
    return { { file = file, header = "@@", lines = hl } }
  end
  local function classify(file, lines, opts)
    opts = opts or {}
    local session = { difficulty = opts.difficulty or "easy" }
    local block = { file = file, agent_trivial = opts.agent_trivial }
    return triviality.classify(session, block, hunks_of(file, lines))
  end

  -- pure imports across lua / py / js
  local lua_imports = classify("lua/foo.lua", { { "add", 'local bar = require("bar")' } })
  assert_eq(lua_imports.trivial, true, "lua imports are trivial")
  assert_eq(lua_imports.source, "heuristic", "lua imports clear via heuristic")
  assert_eq(lua_imports.category, "imports", "lua imports category")
  local py_imports = classify("app/x.py", { { "add", "import os" }, { "add", "from a.b import c" } })
  assert_eq(py_imports.category, "imports", "py imports category")
  assert_eq(py_imports.source, "heuristic", "py imports heuristic")
  local js_imports = classify("src/x.js", { { "add", 'import x from "y"' } })
  assert_eq(js_imports.category, "imports", "js imports category")

  -- documentation files (by extension and by docs/** directory)
  assert_eq(classify("README.md", { { "add", "# New heading" } }).category, "docs", "markdown is docs")
  assert_eq(classify("docs/guide.rst", { { "add", "Some prose." } }).category, "docs", "docs/** is docs")

  -- comment-only edits
  assert_eq(
    classify("lua/foo.lua", { { "add", "-- explain the why" }, { "add", "" } }).category,
    "comments",
    "comment-only block is comments"
  )

  -- docstrings: bare triple-quoted strings are self-evident, single- or
  -- multi-line, and never count as substantive code on their own.
  assert_eq(
    classify("app/x.py", { { "add", '"""Return the widget."""' } }).category,
    "docstrings",
    "single-line python docstring is docstrings"
  )
  local multiline_doc = classify("app/x.py", {
    { "del", '    """Old summary.' },
    { "add", '    """New summary.' },
    { "add", "" },
    { "add", "    Explains the new behaviour." },
    { "add", '    """' },
  })
  assert_eq(multiline_doc.category, "docstrings", "multi-line python docstring body is docstrings")
  -- r"""...""" raw-prefixed docstrings still read as a docstring open
  assert_eq(
    classify("app/x.py", { { "add", 'r"""Raw docstring."""' } }).category,
    "docstrings",
    "raw-prefixed python docstring is docstrings"
  )
  -- a triple quote mid-expression is NOT a docstring: it stays substantive
  local sql = classify("app/x.py", { { "add", 'q = """SELECT 1"""' } })
  assert_eq(sql.trivial, false, "mid-expression triple quote is not a docstring")
  -- docstring + executable code in one block never auto-clears
  local doc_plus_code = classify("app/x.py", {
    { "add", '"""Do the thing."""' },
    { "add", "do_the_thing()" },
  })
  assert_eq(doc_plus_code.trivial, false, "docstring mixed with executable code is not trivial")

  -- version / config value bumps
  assert_eq(classify("Cargo.toml", { { "add", 'version = "0.4.0"' } }).category, "config", "toml is config")
  assert_eq(
    classify("lua/version.lua", { { "add", 'M.version = "0.4.0"' } }).category,
    "config",
    "version.lua is config"
  )

  -- mixing an import with executable code is NOT trivial
  local mixed_exec = classify("lua/foo.lua", { { "add", 'local x = require("y")' }, { "add", "x.run()" } })
  assert_eq(mixed_exec.trivial, false, "import + executable assignment is not trivial")

  -- agent-tagged block mixing trivial kinds (no executable code) clears via agent path
  local agent_mixed = classify(
    "lua/foo.lua",
    { { "add", 'local x = require("y")' }, { "add", "-- note" }, { "add", "" } },
    { agent_trivial = true }
  )
  assert_eq(agent_mixed.trivial, true, "agent-tagged mixed-trivial block clears")
  assert_eq(agent_mixed.source, "agent", "agent-tagged mixed block clears via agent path")
  assert_eq(agent_mixed.category, "mixed", "agent-tagged mixed block category")

  -- the agent guard: a block with executable code never auto-clears
  local agent_exec = classify(
    "lua/foo.lua",
    { { "add", 'local x = require("y")' }, { "add", "dangerous()" } },
    { agent_trivial = true }
  )
  assert_eq(agent_exec.trivial, false, "agent guard blocks executable code")

  -- relaxation is off on extreme / when disabled / and a no-op on vibe
  assert_eq(triviality.applies({ difficulty = "extreme" }), false, "applies false on extreme")
  assert_eq(
    classify("lua/foo.lua", { { "add", 'local b = require("b")' } }, { difficulty = "extreme" }).trivial,
    false,
    "extreme never auto-clears"
  )
  assert_eq(triviality.applies({ difficulty = "vibe" }), false, "applies false on vibe")
  assert_eq(
    classify("lua/foo.lua", { { "add", 'local b = require("b")' } }, { difficulty = "vibe" }).trivial,
    false,
    "vibe is a no-op for triviality"
  )
  local state = require("nvime.state")
  local prior_trivial = state.config.bigchange and state.config.bigchange.trivial
  state.config.bigchange = state.config.bigchange or {}
  state.config.bigchange.trivial = { enabled = false }
  assert_eq(triviality.applies({ difficulty = "easy" }), false, "applies false when disabled")
  assert_eq(
    classify("lua/foo.lua", { { "add", 'local b = require("b")' } }).trivial,
    false,
    "disabled never auto-clears"
  )
  state.config.bigchange.trivial = prior_trivial

  -- overall_grade excludes trivial blocks from the percentage
  local review = require("nvime.bigchange.review")
  local all_trivial = { blocks = { { trivial = true, state = "cleared" }, { trivial = true, state = "cleared" } } }
  assert_eq(review._overall_grade(all_trivial), nil, "all-trivial change has no grade")
  local mix = {
    blocks = {
      { trivial = true, state = "cleared" },
      { grade = 80, state = "cleared" },
      { grade = 40, state = "cleared" },
    },
  }
  local pct, scored, gradeable = review._overall_grade(mix)
  assert_eq(pct, 60, "grade excludes trivial block from the average")
  assert_eq(scored, 2, "grade counts only non-trivial graded blocks")
  assert_eq(gradeable, 2, "grade denominator is the non-trivial count")

  -- The Big Change review advertises its left-tree keys through the shared g?
  -- overlay; verify the sections the binding feeds keyhelp render as expected.
  do
    local keyhelp = require("nvime.keyhelp")
    keyhelp.close()
    keyhelp.open({ title = "big change keys", sections = review._help_sections() })
    assert(keyhelp.is_open(), "big change help renders through keyhelp")
    local bc_help = table.concat(vim.api.nvim_buf_get_lines(state.panels.keyhelp.bufnr, 0, -1, false), "\n")
    assert(bc_help:find("approve", 1, true), "big change help documents approve")
    assert(bc_help:find("submit the round", 1, true), "big change help documents submit round")
    assert(bc_help:find("toggle this help", 1, true), "big change help documents g? itself")
    keyhelp.close()
  end

  -- #10: every grading attempt is recorded to per-block history + audit.
  local gsession = {
    id = "proj-grade",
    title = "Grade project",
    difficulty = "medium", -- threshold 70
    blocks = { { id = 1, title = "Block A", file = "a.lua", action = "approve", comment = "explains the change" } },
  }
  local audit_before = vim.fn.filereadable(audit_path) == 1 and #vim.fn.readfile(audit_path) or 0
  review._apply_results(gsession, { { id = 1, grade = 85 } }, gsession.blocks)
  assert_eq(gsession.blocks[1].state, "cleared", "grading: 85 >= 70 clears the block")
  assert_eq(#gsession.blocks[1].grading_history, 1, "grading: first attempt recorded")
  assert_eq(gsession.blocks[1].grading_history[1].passed, true, "grading: passing attempt marked passed")
  gsession.blocks[1].action = "approve"
  review._apply_results(gsession, { { id = 1, grade = 40 } }, gsession.blocks)
  assert_eq(gsession.blocks[1].state, "needs_explanation", "grading: 40 < 70 needs a better explanation")
  assert_eq(#gsession.blocks[1].grading_history, 2, "grading: attempts accumulate in history")
  assert_eq(gsession.blocks[1].grading_history[2].passed, false, "grading: failing attempt marked not passed")
  local saw_grade_audit = false
  for _, line in ipairs(vim.fn.readfile(audit_path)) do
    local ok_d, d = pcall(vim.json.decode, line)
    if ok_d and type(d) == "table" and d.event == "bigchange_block_graded" and d.block_id == 1 then
      saw_grade_audit = true
    end
  end
  assert(saw_grade_audit, "grading: bigchange_block_graded audit event written")

  -- #11: a trivial auto-cleared block can be re-locked to require explanation.
  local osession = {
    id = "proj-ovr",
    title = "Override",
    difficulty = "easy",
    blocks = {
      { id = 1, title = "imports", file = "a.lua", trivial = true, state = "cleared", action = "auto_trivial" },
    },
  }
  local ob = osession.blocks[1]
  assert(review._override_trivial(osession, ob), "override: a trivial auto-clear is re-lockable")
  assert_eq(ob.state, "pending", "override: re-locked block returns to pending")
  assert_eq(ob.trivial, false, "override: re-locked block is no longer trivial (now counts toward the grade)")
  assert_eq(
    review._override_trivial(osession, { id = 2, state = "cleared", grade = 90 }),
    false,
    "override: an earned (non-trivial) clear is not re-locked"
  )
  local saw_override_audit = false
  for _, line in ipairs(vim.fn.readfile(audit_path)) do
    local ok_d, d = pcall(vim.json.decode, line)
    if ok_d and type(d) == "table" and d.event == "bigchange_trivial_overridden" then
      saw_override_audit = true
    end
  end
  assert(saw_override_audit, "override: bigchange_trivial_overridden audit event written")
end
do
  local state = require("nvime.state")
  local wrapped_system = vim.system
  require("nvime").disable()
  assert(state.disabled == true, "disable marks nvime disabled")
  assert(state.guard_installed == false, "disable restores guard wrappers")
  assert(vim.system ~= wrapped_system, "disable restores the raw vim.system function")
  require("nvime").enable()
  assert(state.disabled == false, "enable marks nvime enabled")
  assert(state.guard_installed == true, "enable reinstalls guard wrappers")
  require("nvime.health").check()
end
assert(vim.fn.strdisplaywidth(require("nvime.ui").truncate("abcdef", 4)) <= 4, "ui truncation respects display width")
assert(
  vim.fn.strdisplaywidth(require("nvime.ui").truncate("ab◈cdef", 4)) <= 4,
  "ui truncation respects display width for glyph labels"
)

vim.cmd("NvimeProvider codex")
assert(require("nvime.state").config.provider == "codex", "provider command sets codex")
vim.cmd("NvimeProvider claude")
assert(require("nvime.state").config.provider == "claude", "provider command sets claude")

vim.cmd("Nvime")
local dashboard_panel = require("nvime.state").panels.chats
assert(dashboard_panel and vim.api.nvim_win_is_valid(dashboard_panel.winid), "Nvime opens the command center")
assert(dashboard_panel.mode == "dashboard", "Nvime command center uses dashboard mode")
local dashboard_lines = table.concat(vim.api.nvim_buf_get_lines(dashboard_panel.bufnr, 0, -1, false), "\n")
assert(dashboard_lines:find("nvime", 1, true), "dashboard has branded heading")
assert(dashboard_lines:find("(1) All", 1, true), "dashboard exposes Mason-style tabs")
assert(dashboard_lines:find("Actions", 1, true), "dashboard exposes action rows")
assert(
  #vim.api.nvim_buf_get_extmarks(dashboard_panel.bufnr, vim.api.nvim_create_namespace("nvime.chats"), 0, -1, {}) > 0,
  "dashboard has visual decorations"
)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("?", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local help = require("nvime.state").panels.chats_help
    return help and help.winid and vim.api.nvim_win_is_valid(help.winid)
  end, 20),
  "dashboard help overlay opens"
)
pcall(vim.api.nvim_win_close, require("nvime.state").panels.chats_help.winid, true)
require("nvime.state").panels.chats_help = nil
pcall(vim.api.nvim_win_close, dashboard_panel.winid, true)

local stale_chat = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(stale_chat, "nvime://stale-chat")
local chat = require("nvime.ui").panel("stale-chat", "nvime", "nvime")
assert(chat == stale_chat, "reuses pre-existing nvime named buffer")

vim.cmd("NvimeChat")
local chat_picker_panel = require("nvime.state").panels.chats
assert(
  chat_picker_panel and vim.api.nvim_win_is_valid(chat_picker_panel.winid),
  "NvimeChat opens the general chat picker"
)
local chat_picker_lines = table.concat(vim.api.nvim_buf_get_lines(chat_picker_panel.bufnr, 0, -1, false), "\n")
assert(chat_picker_lines:find("General Conversations", 1, true), "chat picker is scoped to general conversations")
assert(chat_picker_lines:find("start new chat conversation", 1, true), "chat picker offers a new chat session")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("n", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local panel = require("nvime.state").panels.chat
    return panel and panel.winid and vim.api.nvim_win_is_valid(panel.winid)
  end, 20),
  "chat picker n opens a new general chat"
)
assert(vim.api.nvim_get_mode().mode ~= "i", "chat picker n opens general chat in normal mode")
assert(
  vim.bo[require("nvime.state").panels.chat.bufnr].modifiable == false,
  "newly opened chat is locked until prompt focus"
)

local stale_chat_input = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(stale_chat_input, "nvime://chat-input")
local chat_buf = require("nvime.chat").open()
local chat_panel = require("nvime.state").panels.chat
local chat_win = chat_panel.winid
local chat_input = chat_panel.input_bufnr
local chat_input_win = chat_panel.input_winid
assert(vim.api.nvim_win_get_config(chat_win).relative == "editor", "chat opens as a float by default")
assert(chat_input_win == chat_win, "chat uses one floating window")
assert(chat_input == chat_buf, "chat input shares the scrollback buffer")
assert(not vim.api.nvim_buf_is_valid(stale_chat_input), "chat removes legacy input buffers")
assert(vim.api.nvim_win_get_height(chat_win) >= 16, "chat has a usable float height")
local chat_lines = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
assert(not chat_lines:find("====", 1, true), "chat does not write rule text into the transcript")
assert(vim.bo[chat_buf].modifiable == false, "chat buffer is locked until the input is focused")
local input_lines = table.concat(vim.api.nvim_buf_get_lines(chat_buf, chat_panel.input_start - 1, -1, false), "\n")
assert(input_lines:find("[claude]$ ", 1, true), "chat input has a terminal prompt")
assert(
  #vim.api.nvim_buf_get_extmarks(chat_buf, vim.api.nvim_create_namespace("nvime.chat"), 0, -1, {}) > 0,
  "chat has decorations"
)
assert(
  #vim.api.nvim_buf_get_extmarks(chat_input, vim.api.nvim_create_namespace("nvime.chat.input"), 0, -1, {}) > 0,
  "chat input has decorations"
)

local fast_append_done = false
local fast_append_ok = false
local fast_append_err = nil
local fast_timer = (vim.uv or vim.loop).new_timer()
fast_timer:start(0, 0, function()
  fast_append_ok, fast_append_err = pcall(function()
    require("nvime.ui").ensure_highlights()
    require("nvime.chat").append("chat fast-event append\n")
  end)
  fast_append_done = true
  fast_timer:stop()
  fast_timer:close()
end)
assert(
  vim.wait(1000, function()
    return fast_append_done
  end, 20),
  "fast-event chat append callback ran"
)
assert(fast_append_ok, tostring(fast_append_err))
assert(
  vim.wait(1000, function()
    return table
      .concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
      :find("chat fast-event append", 1, true)
  end, 20),
  "chat append schedules UI work from fast events"
)
chat_panel = require("nvime.state").panels.chat
chat_win = chat_panel.winid
chat_input = chat_panel.input_bufnr
chat_input_win = chat_panel.input_winid;
(function()
  local dedupe_claude = tmp .. "/dedupe-claude"
  vim.fn.writefile({
    "#!/usr/bin/env sh",
    'printf \'%s\\n\' \'{"event":{"delta":{"type":"text_delta","text":"Hey!"}}}\'',
    'printf \'%s\\n\' \'{"type":"assistant","message":{"content":[{"type":"text","text":"Hey!"}]}}\'',
  }, dedupe_claude)
  vim.fn.setfperm(dedupe_claude, "rwxr-xr-x")
  local dedupe_old_claude_cmd = require("nvime.state").config.providers.claude.cmd
  require("nvime.state").config.providers.claude.cmd = dedupe_claude
  local dedupe_chunks = {}
  local dedupe_done = false
  require("nvime.agents").run({
    provider = "claude",
    lane = "ask",
    prompt = "hello",
    on_text = function(text)
      dedupe_chunks[#dedupe_chunks + 1] = text
    end,
    on_exit = function()
      dedupe_done = true
    end,
  })
  assert(
    vim.wait(5000, function()
      return dedupe_done
    end, 20),
    "agent dedupe fixture exits"
  )
  assert_eq(table.concat(dedupe_chunks), "Hey!", "claude streamed delta and final aggregate are not duplicated")
  require("nvime.state").config.providers.claude.cmd = dedupe_old_claude_cmd
end)()

require("nvime.chat").prompt()
assert(vim.api.nvim_get_current_buf() == chat_buf, "chat prompt focuses shared input buffer")
assert(vim.api.nvim_get_current_win() == chat_input_win, "chat prompt focuses the single chat window")
assert(vim.bo[chat_buf].modifiable == true, "chat buffer becomes editable while typing on the prompt")
local old_select = vim.ui.select
vim.ui.select = function(items, _opts, on_choice)
  on_choice(items[1])
end
require("nvime.chat").choose_prompt()
chat_panel = require("nvime.state").panels.chat
local templated_chat_prompt = vim.api.nvim_buf_get_lines(
  chat_buf,
  chat_panel.input_start - 1,
  chat_panel.input_start,
  false
)[1] or ""
assert(templated_chat_prompt:find("Please review this repository", 1, true), "chat prompt picker fills the prompt line")
vim.api.nvim_buf_set_lines(chat_buf, chat_panel.input_start - 1, chat_panel.input_start, false, { "[claude]$ " })
vim.ui.select = old_select
pcall(vim.cmd.stopinsert)
require("nvime.chat").prompt()
vim.api.nvim_buf_set_lines(chat_buf, 0, -1, false, { "oops" })
assert(
  vim.wait(1000, function()
    local guarded = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    return guarded:find("oops", 1, true) == nil and guarded:find("[claude]$ ", 1, true) ~= nil
  end, 20),
  "chat guard restores edits outside the prompt line"
)
local append_prompt_line = "[claude]$ Hey, please iterate throughout"
vim.api.nvim_buf_set_lines(chat_buf, chat_panel.input_start - 1, chat_panel.input_start, false, { append_prompt_line })
pcall(vim.cmd.stopinsert)
vim.api.nvim_win_set_cursor(chat_win, { chat_panel.input_start, #"[claude]$ " })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("A", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    return vim.api.nvim_win_get_cursor(chat_win)[2] >= (#append_prompt_line - 2)
  end, 20),
  "chat A appends at the end of the live prompt line"
)
pcall(vim.cmd.stopinsert)
vim.api.nvim_buf_set_lines(chat_buf, chat_panel.input_start - 1, chat_panel.input_start, false, { "[claude]$ " })
vim.api.nvim_win_set_cursor(chat_win, { chat_panel.input_start, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("Ityped<Esc>", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local line = vim.api.nvim_buf_get_lines(chat_buf, chat_panel.input_start - 1, chat_panel.input_start, false)[1]
      or ""
    return line == "[claude]$ typed"
  end, 20),
  "chat I inserts after the prompt prefix on an empty prompt"
)
pcall(vim.cmd.stopinsert)

local chat_scroll_lines = {}
for index = 1, 40 do
  chat_scroll_lines[#chat_scroll_lines + 1] = "chat scroll fixture " .. index
end
require("nvime.chat").append(table.concat(chat_scroll_lines, "\n") .. "\n")
assert(
  vim.wait(1000, function()
    return table
      .concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
      :find("chat scroll fixture 40", 1, true)
  end, 20),
  "chat scroll fixture is appended"
)
require("nvime.state").panels.chat.input_active = false
vim.api.nvim_win_set_cursor(chat_win, { 2, 0 })
vim.api.nvim_win_call(chat_win, function()
  vim.fn.winrestview({ topline = 1 })
end)
require("nvime.chat").append("chat locked output\n")
assert(
  vim.wait(1000, function()
    return table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n"):find("chat locked output", 1, true)
  end, 20),
  "chat locked output is appended"
)
local chat_locked_view = vim.api.nvim_win_call(chat_win, vim.fn.winsaveview)
assert_eq(vim.api.nvim_win_get_cursor(chat_win)[1], 2, "chat output preserves cursor when user scrolled away")
assert_eq(chat_locked_view.topline, 1, "chat output preserves topline when user scrolled away")
local chat_bottom_lnum = require("nvime.state").panels.chat.input_start
vim.api.nvim_win_set_cursor(chat_win, { chat_bottom_lnum, 0 })
vim.api.nvim_win_call(chat_win, function()
  vim.fn.winrestview({ topline = math.max(1, chat_bottom_lnum - vim.api.nvim_win_get_height(chat_win) + 2) })
end)
require("nvime.chat").append("chat following output\n")
assert(
  vim.wait(1000, function()
    return table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n"):find("chat following output", 1, true)
      and vim.api.nvim_win_get_cursor(chat_win)[1] >= require("nvime.state").panels.chat.input_start
  end, 20),
  "chat output follows when cursor is at the prompt"
)

require("nvime.provider").cycle()
local cycled_lines = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
local cycled_input = table.concat(vim.api.nvim_buf_get_lines(chat_input, chat_panel.input_start - 1, -1, false), "\n")
assert(require("nvime.state").config.provider == "codex", "provider cycles in chat")
assert(not cycled_lines:find("====", 1, true), "provider cycle keeps transcript free of rule text")
assert(cycled_input:find("[codex]$ ", 1, true), "provider cycle updates input prompt")
vim.cmd("NvimeProvider claude")

require("nvime.chat").submit("say hello")
local chat_done = vim.wait(5000, function()
  return #require("nvime.state").chat.history >= 2
end, 20)
assert(chat_done, "chat prompt submits to provider")
local chat_transcript = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
assert(not chat_transcript:find("chat exited", 1, true), "chat transcript omits successful exit status")
local saw_code_fence = false
local saw_code_line = false
for _, mark in
  ipairs(vim.api.nvim_buf_get_extmarks(chat_buf, vim.api.nvim_create_namespace("nvime.chat"), 0, -1, {
    details = true,
  }))
do
  local details = mark[4] or {}
  saw_code_fence = saw_code_fence or details.hl_group == "NvimeCodeFence"
  saw_code_line = saw_code_line or details.hl_group == "NvimeCode"
end
assert(saw_code_fence and saw_code_line, "chat parses and highlights fenced code output")
assert(#require("nvime.state").chat.history >= 2, "chat keeps transcript history")

require("nvime.chat").submit("what did I just say?")
local followup_done = vim.wait(5000, function()
  return #require("nvime.state").chat.history >= 4
end, 20)
assert(followup_done, "chat follow-up updates transcript history")
assert(#require("nvime.state").chat.history >= 4, "chat history is retained for reopened chat prompts")
require("nvime.chat").save_sessions()
assert(vim.fn.filereadable(chat_sessions_path) == 1, "general chat sessions persist to disk")
local chat_sessions_json = table.concat(vim.fn.readfile(chat_sessions_path), "\n")
assert(chat_sessions_json:find("say hello", 1, true), "persisted chat sessions include transcript history")
require("nvime.chat").new_session({ title = "delete me", focus_input = false })
vim.cmd("NvimeChat")
local persisted_chat_picker = require("nvime.state").panels.chats
local persisted_chat_lines = table.concat(vim.api.nvim_buf_get_lines(persisted_chat_picker.bufnr, 0, -1, false), "\n")
assert(persisted_chat_lines:find("say hello", 1, true), "chat picker shows old conversations by title")
assert(persisted_chat_lines:find("delete me", 1, true), "chat picker shows newly created conversations")
local delete_chat_row = nil
for row, _ in pairs(persisted_chat_picker.row_to_session or {}) do
  local line = vim.api.nvim_buf_get_lines(persisted_chat_picker.bufnr, row - 1, row, false)[1] or ""
  if line:find("delete me", 1, true) then
    delete_chat_row = row
    break
  end
end
assert(delete_chat_row ~= nil, "chat picker has a deletable chat row")
vim.api.nvim_win_set_cursor(persisted_chat_picker.winid, { delete_chat_row, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("dd", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    return not table
      .concat(vim.api.nvim_buf_get_lines(require("nvime.state").panels.chats.bufnr, 0, -1, false), "\n")
      :find("delete me", 1, true)
  end, 20),
  "chat picker dd deletes the selected chat session"
)
assert(require("nvime.chat").session_count() >= 1, "deleting one chat keeps older conversations")
require("nvime.chat").save_sessions()
do
  local before_reload = require("nvime.chat").active_session_id()
  assert(before_reload ~= nil, "chat has an active session prior to reload")
  require("nvime.chat").save_sessions()
  require("nvime.chat").reload_sessions()
  assert_eq(require("nvime.chat").active_session_id(), before_reload, "active chat session id is restored after reload")
end
require("nvime.chat").reload_sessions()
assert(require("nvime.chat").session_count() >= 1, "general chat sessions reload from disk")
vim.cmd("NvimeChat")
local reloaded_chat_picker = require("nvime.state").panels.chats
assert(
  table.concat(vim.api.nvim_buf_get_lines(reloaded_chat_picker.bufnr, 0, -1, false), "\n"):find("say hello", 1, true),
  "chat picker shows persisted conversations after reload"
)
local reloaded_chat = require("nvime.chat").sessions()[1]
vim.api.nvim_set_current_win(reloaded_chat_picker.winid)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("1", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local panel = require("nvime.state").panels.chat
    return require("nvime.chat").active_session_id() == reloaded_chat.id
      and panel
      and panel.winid
      and vim.api.nvim_win_is_valid(panel.winid)
  end, 20),
  "chat picker numeric shortcut opens the first conversation"
)
assert(vim.api.nvim_get_mode().mode ~= "i", "chat picker numeric shortcut opens chat in normal mode")
assert(
  vim.bo[require("nvime.state").panels.chat.bufnr].modifiable == false,
  "opened chat session is locked until prompt focus"
)
chat_buf = require("nvime.state").panels.chat.bufnr
chat_panel = require("nvime.state").panels.chat
chat_win = chat_panel.winid
chat_input = chat_panel.input_bufnr
chat_input_win = chat_panel.input_winid

local old_claude_cmd = require("nvime.state").config.providers.claude.cmd
local chat_progress_claude = tmp .. "/chat-progress-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  'printf \'%s\\n\' \'{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"sed -n 1,260p README.md"}}]}}\'',
  "sleep 0.2",
  'printf \'%s\\n\' \'{"type":"assistant","message":{"content":[{"type":"text","text":"progress final"}]}}\'',
}, chat_progress_claude)
vim.fn.setfperm(chat_progress_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = chat_progress_claude
local progress_history_start = #require("nvime.state").chat.history
require("nvime.chat").submit("progress flush chat")
assert(
  vim.wait(5000, function()
    return require("nvime.state").chat.progress == "claude Bash"
  end, 20),
  "chat progress is visible while the provider runs"
)
assert(
  vim.wait(2000, function()
    local panel = require("nvime.state").panels.spinner
    if not panel or not panel.bufnr or not vim.api.nvim_buf_is_valid(panel.bufnr) then
      return false
    end
    local lines = vim.api.nvim_buf_get_lines(panel.bufnr, 0, -1, false)
    for _, line in ipairs(lines) do
      if line:find("Bash", 1, true) then
        return true
      end
    end
    return false
  end, 20),
  "chat progress is shown in the corner spinner float"
)
assert(
  vim.wait(5000, function()
    return #require("nvime.state").chat.history >= progress_history_start + 2
  end, 20),
  "chat progress fixture runs"
)
local progress_flush_transcript = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
assert(progress_flush_transcript:find("progress final", 1, true), "chat progress fixture delivers final answer")
assert(progress_flush_transcript:find("tool: Bash", 1, true), "chat tool log is visible in transcript")
assert(require("nvime.state").chat.progress == nil, "chat progress is cleared after completion")
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

local chat_native_claude_id = "33333333-3333-3333-3333-333333333333"
local fake_chat_resume_claude = tmp .. "/fake-chat-resume-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  'printf \'%s\\n\' \'{"type":"system","subtype":"init","session_id":"' .. chat_native_claude_id .. "\"}'",
  'printf \'%s\\n\' \'{"type":"assistant","message":{"content":[{"type":"text","text":"native chat ok"}]}}\'',
}, fake_chat_resume_claude)
vim.fn.setfperm(fake_chat_resume_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = fake_chat_resume_claude
require("nvime.state").chat.provider_sessions = {}
require("nvime.state").chat.provider_workspaces = {}
require("nvime.state").chat.last_provider = nil
local native_chat_start = #require("nvime.state").chat.history
require("nvime.chat").submit("first native chat")
assert(
  vim.wait(5000, function()
    return #require("nvime.state").chat.history >= native_chat_start + 2
  end, 20),
  "native chat first turn runs"
)
assert_eq(
  require("nvime.state").chat.provider_sessions.claude,
  chat_native_claude_id,
  "general chat captures native claude session id"
)
local native_chat_followup = #require("nvime.state").chat.history
require("nvime.chat").submit("second native chat")
assert(
  vim.wait(5000, function()
    return #require("nvime.state").chat.history >= native_chat_followup + 2
  end, 20),
  "native chat follow-up runs"
)
local native_chat_audit = vim.fn.readfile(audit_path)
local first_native_chat = ""
local second_native_chat = ""
for _, line in ipairs(native_chat_audit) do
  if line:find("first native chat", 1, true) then
    first_native_chat = line
  elseif line:find("second native chat", 1, true) then
    second_native_chat = line
  end
end
assert(not first_native_chat:find("--no-session-persistence", 1, true), "general chat keeps native session persistence")
assert(
  second_native_chat:find("--resume " .. chat_native_claude_id, 1, true),
  "general chat follow-up uses native resume"
)
assert(
  second_native_chat:find("Conversation so far: available from the resumed native provider session", 1, true),
  "resumed chat avoids resending full transcript"
)
local first_native_chat_event = vim.json.decode(first_native_chat)
local second_native_chat_event = vim.json.decode(second_native_chat)
assert_eq(
  first_native_chat_event.markdown_workspace,
  second_native_chat_event.markdown_workspace,
  "general chat reuses one markdown workspace for native resume"
)
assert_eq(
  first_native_chat_event.cwd,
  first_native_chat_event.markdown_workspace,
  "general chat runs inside the stable markdown workspace"
)
assert_eq(
  second_native_chat_event.cwd,
  second_native_chat_event.markdown_workspace,
  "resumed general chat stays in the stable markdown workspace"
)

local stale_chat_claude = tmp .. "/stale-chat-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' 'No conversation found with session ID: stale-chat-id' >&2",
  "exit 1",
}, stale_chat_claude)
vim.fn.setfperm(stale_chat_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = stale_chat_claude
require("nvime.state").chat.provider_sessions = { claude = "stale-chat-id" }
require("nvime.state").chat.provider_workspaces = {}
require("nvime.state").chat.last_provider = "claude"
require("nvime.chat").submit("stale native chat")
assert(
  vim.wait(5000, function()
    local text = table.concat(vim.api.nvim_buf_get_lines(chat_buf, 0, -1, false), "\n")
    return text:find("No conversation found with session ID: stale-chat-id", 1, true)
      and text:find("[nvime] chat failed with code 1", 1, true)
  end, 20),
  "general chat dumps stale native resume errors"
)
require("nvime.state").config.providers.claude.cmd = old_claude_cmd
require("nvime.state").chat.provider_sessions = {}
require("nvime.state").chat.provider_workspaces = {}
require("nvime.state").chat.last_provider = nil

local hidden_chat_claude = tmp .. "/hidden-chat-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "sleep 0.2",
  'printf \'%s\\n\' \'{"type":"assistant","message":{"content":[{"type":"text","text":"hidden chat done"}]}}\'',
}, hidden_chat_claude)
vim.fn.setfperm(hidden_chat_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = hidden_chat_claude
local old_notify = vim.notify
local notices = {}
vim.notify = function(msg, level, opts)
  notices[#notices + 1] = tostring(msg)
  return old_notify(msg, level, opts)
end
require("nvime.chat").submit("hidden chat notify")
local hidden_chat_id = require("nvime.chat").active_session_id()
require("nvime.chat").close()
assert(not require("nvime.chat").is_open(hidden_chat_id), "hidden chat fixture closes the float while running")
assert(
  vim.wait(5000, function()
    local session = require("nvime.chat").get_session(hidden_chat_id)
    return session
      and not session.busy
      and table.concat(vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false), "\n"):find("hidden chat done", 1, true)
  end, 20),
  "hidden chat still records the completed response"
)
assert(not require("nvime.chat").is_open(hidden_chat_id), "hidden chat completion does not reopen the float")
assert(
  vim.tbl_contains(notices, "nvime chat finished. Reopen with :NvimeLast or <leader>nn."),
  "hidden chat completion notifies"
)
vim.notify = old_notify
require("nvime").open_last()
assert(require("nvime.chat").is_open(hidden_chat_id), "NvimeLast reopens the hidden completed chat")
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

local writer_claude = tmp .. "/writer-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' '# Generated by nvime test' > NVIME_TEST_DOC.md",
  "printf '%s\\n' 'source writes must not sync' > SHOULD_NOT_SYNC.lua",
  "printf '%s\\n' 'wrote markdown'",
}, writer_claude)
vim.fn.setfperm(writer_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = writer_claude
local markdown_done = false
require("nvime.agents").run({
  provider = "claude",
  lane = "review",
  prompt = "create markdown docs",
  on_exit = function(result)
    markdown_done = result.code == 0
      and vim.fn.filereadable(root .. "/NVIME_TEST_DOC.md") == 1
      and vim.fn.filereadable(root .. "/SHOULD_NOT_SYNC.lua") == 0
      and #(result.nvime_synced_markdown or {}) == 1
  end,
})
assert(
  vim.wait(5000, function()
    return markdown_done
  end, 20),
  "review lane syncs markdown writes only"
)
require("nvime.state").config.providers.claude.cmd = old_claude_cmd
vim.fn.delete(root .. "/NVIME_TEST_DOC.md")

local native_claude_id = "11111111-1111-1111-1111-111111111111"
local fake_resume_claude = tmp .. "/fake-resume-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  'printf \'%s\\n\' \'{"type":"system","subtype":"init","session_id":"' .. native_claude_id .. "\"}'",
  'printf \'%s\\n\' \'{"type":"assistant","message":{"content":[{"type":"text","text":"native claude ok"}]}}\'',
}, fake_resume_claude)
vim.fn.setfperm(fake_resume_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = fake_resume_claude
local native_claude_seen = nil
local native_claude_done = false
require("nvime.agents").run({
  provider = "claude",
  lane = "ask",
  prompt = "first native claude",
  persist_session = true,
  on_session_id = function(session_id)
    native_claude_seen = session_id
  end,
  on_exit = function(result)
    native_claude_done = result.code == 0
  end,
})
assert(
  vim.wait(5000, function()
    return native_claude_done
  end, 20),
  "persistent claude selection lane runs"
)
assert_eq(native_claude_seen, native_claude_id, "claude session id is captured")
native_claude_done = false
require("nvime.agents").run({
  provider = "claude",
  lane = "ask",
  prompt = "second native claude",
  persist_session = true,
  resume_session_id = native_claude_seen,
  on_exit = function(result)
    native_claude_done = result.code == 0
  end,
})
assert(
  vim.wait(5000, function()
    return native_claude_done
  end, 20),
  "claude resume lane runs"
)
local native_claude_audit = vim.fn.readfile(audit_path)
local first_native_claude = ""
local second_native_claude = ""
for _, line in ipairs(native_claude_audit) do
  if line:find("first native claude", 1, true) then
    first_native_claude = line
  elseif line:find("second native claude", 1, true) then
    second_native_claude = line
  end
end
assert(
  not first_native_claude:find("--no-session-persistence", 1, true),
  "persistent claude start keeps native session persistence"
)
assert(
  first_native_claude:find("--tools Read,Glob,Grep,LS,WebFetch,WebSearch,Bash", 1, true),
  "claude selection lane allows read/search/web/shell tools"
)
assert(
  first_native_claude:find("--allowedTools Read,Glob,Grep,LS,WebFetch,WebSearch,Bash", 1, true),
  "claude selection allow-list is explicit"
)
assert(
  first_native_claude:find("--disallowedTools Edit,Write,NotebookEdit", 1, true),
  "claude selection lane blocks direct write tools"
)
assert(
  first_native_claude:find("Bash(git commit:*)", 1, true) and first_native_claude:find("Bash(git push:*)", 1, true),
  "claude selection lane disallows destructive git verbs"
)
assert(
  first_native_claude:find("Bash(rm -rf:*)", 1, true),
  "claude selection lane disallows recursive force-delete of the working tree"
)
assert(
  not first_native_claude:find("Bash(sudo:*)", 1, true) and not first_native_claude:find("Bash(dd:*)", 1, true),
  "claude selection lane does not pretend to be a system sandbox (no mkfs/dd/sudo blocklist)"
)
assert(not first_native_claude:find("Bash(git diff", 1, true), "claude selection lane keeps git diff readable")
assert(not first_native_claude:find("Bash(git add", 1, true), "claude selection lane keeps git add allowed")
assert(second_native_claude:find("--resume " .. native_claude_id, 1, true), "claude follow-up uses native resume")
local old_selection_allow_shell = require("nvime.state").config.selection.allow_shell
local old_selection_allow_web = require("nvime.state").config.selection.allow_web
require("nvime.state").config.selection.allow_shell = false
native_claude_done = false
require("nvime.agents").run({
  provider = "claude",
  lane = "ask",
  prompt = "no shell native claude",
  persist_session = true,
  on_exit = function(result)
    native_claude_done = result.code == 0
  end,
})
assert(
  vim.wait(5000, function()
    return native_claude_done
  end, 20),
  "claude selection lane can disable shell tools"
)
require("nvime.state").config.selection.allow_shell = old_selection_allow_shell
native_claude_audit = vim.fn.readfile(audit_path)
local no_shell_native_claude = ""
for _, line in ipairs(native_claude_audit) do
  if line:find("no shell native claude", 1, true) then
    no_shell_native_claude = line
  end
end
assert(
  no_shell_native_claude:find("--tools Read,Glob,Grep,LS,WebFetch,WebSearch", 1, true),
  "claude selection keeps web tools when shell is disabled"
)
assert(not no_shell_native_claude:find("Bash", 1, true), "claude selection omits Bash when selection shell is disabled")
require("nvime.state").config.selection.allow_web = false
native_claude_done = false
require("nvime.agents").run({
  provider = "claude",
  lane = "ask",
  prompt = "no web native claude",
  persist_session = true,
  on_exit = function(result)
    native_claude_done = result.code == 0
  end,
})
assert(
  vim.wait(5000, function()
    return native_claude_done
  end, 20),
  "claude selection lane can disable web tools"
)
require("nvime.state").config.selection.allow_shell = old_selection_allow_shell
require("nvime.state").config.selection.allow_web = old_selection_allow_web
native_claude_audit = vim.fn.readfile(audit_path)
local no_web_native_claude = ""
for _, line in ipairs(native_claude_audit) do
  if line:find("no web native claude", 1, true) then
    no_web_native_claude = line
  end
end
assert(no_web_native_claude:find("--tools Read,Glob,Grep,LS", 1, true), "claude selection can omit web tools")
assert(
  not no_web_native_claude:find("--tools Read,Glob,Grep,LS,WebFetch", 1, true),
  "claude selection omits WebFetch from the allowed tool list when selection web is disabled"
)
assert(
  no_web_native_claude:find("--disallowedTools Edit,Write,NotebookEdit,WebFetch,WebSearch", 1, true),
  "claude selection explicitly disallows web tools when disabled"
)
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

local noisy_lsp_claude = tmp .. "/noisy-lsp-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  'printf \'%s\\n\' \'{"type":"assistant","message":{"content":[{"type":"tool_use","name":"LSP","input":{}}]}}\'',
  'printf \'%s\\n\' \'{"type":"assistant","message":{"content":[{"type":"tool_use","name":"LSP","input":{}}]}}\'',
  'printf \'%s\\n\' \'{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}\'',
}, noisy_lsp_claude)
vim.fn.setfperm(noisy_lsp_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = noisy_lsp_claude
local lsp_progress = {}
local lsp_done = false
require("nvime.agents").run({
  provider = "claude",
  lane = "ask",
  prompt = "check lsp progress",
  persist_session = true,
  on_progress = function(text)
    lsp_progress[#lsp_progress + 1] = text
  end,
  on_exit = function(result)
    lsp_done = result.code == 0
  end,
})
assert(
  vim.wait(5000, function()
    return lsp_done
  end, 20),
  "claude LSP progress fixture runs"
)
local lsp_progress_text = table.concat(lsp_progress)
local _, lsp_progress_count = lsp_progress_text:gsub("%[claude%] tool: LSP", "")
assert_eq(lsp_progress_count, 1, "duplicate Claude LSP progress is collapsed")
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

local fake_codex = tmp .. "/fake-codex"
local native_codex_id = "22222222-2222-2222-2222-222222222222"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "test -d .git || { printf '%s\\n' 'missing temp git root'; exit 3; }",
  "cat >/dev/null",
  'printf \'%s\\n\' \'{"type":"turn.started","session_id":"' .. native_codex_id .. "\"}'",
  'printf \'%s\\n\' \'{"item":{"type":"reasoning","summary":"checking files"}}\'',
  'printf \'%s\\n\' \'{"item":{"type":"command_execution","command":"rg README"}}\'',
  "printf '%s\\n' '2026-05-04T19:02:05.488995Z ERROR codex_models_manager::manager: failed to refresh available models: timeout waiting for child process to exit' >&2",
  'printf \'%s\\n\' \'{"item":{"type":"agent_message","text":"codex ok"}}\'',
}, fake_codex)
vim.fn.setfperm(fake_codex, "rwxr-xr-x")
require("nvime.state").config.providers.codex.cmd = fake_codex
local codex_done = false
local codex_text = {}
local codex_progress = {}
require("nvime.agents").run({
  provider = "codex",
  lane = "review",
  prompt = "check codex args",
  on_text = function(text)
    codex_text[#codex_text + 1] = text
  end,
  on_progress = function(text)
    codex_progress[#codex_progress + 1] = text
  end,
  on_exit = function(result)
    codex_done = result.code == 0
  end,
})
assert(
  vim.wait(5000, function()
    return codex_done
  end, 20),
  "codex review lane runs with fake provider"
)
local codex_audit = table.concat(vim.fn.readfile(audit_path), "\n")
assert(codex_audit:find("%-%-skip%-git%-repo%-check"), "codex argv skips git repo check for nvime temp workspace")
assert(table.concat(codex_text):find("codex ok", 1, true), "codex final answer is delivered as text")
assert(not table.concat(codex_text):find("checking files", 1, true), "codex progress is not mixed into final text")
assert(
  not table.concat(codex_text):find("failed to refresh available models", 1, true),
  "codex model refresh stderr noise is not transcript text"
)
local codex_progress_text = table.concat(codex_progress)
assert(codex_progress_text:find("checking files", 1, true), "codex reasoning summaries stream as progress")
assert(codex_progress_text:find("rg README", 1, true), "codex tool activity streams as progress")

local codex_edit_done = false
require("nvime.agents").run({
  provider = "codex",
  lane = "edit",
  prompt = "check codex edit args",
  on_exit = function(result)
    codex_edit_done = result.code == 0
  end,
})
assert(
  vim.wait(5000, function()
    return codex_edit_done
  end, 20),
  "codex edit lane runs with fake provider"
)
local codex_audit_after_edit = table.concat(vim.fn.readfile(audit_path), "\n")
assert(codex_audit_after_edit:find("check codex edit args", 1, true), "codex edit lane is audited")
assert(codex_audit_after_edit:find("%-%-skip%-git%-repo%-check"), "codex edit argv also skips git repo check")

local native_codex_seen = nil
local native_codex_done = false
require("nvime.agents").run({
  provider = "codex",
  lane = "ask",
  prompt = "first native codex",
  persist_session = true,
  on_session_id = function(session_id)
    native_codex_seen = session_id
  end,
  on_exit = function(result)
    native_codex_done = result.code == 0
  end,
})
assert(
  vim.wait(5000, function()
    return native_codex_done
  end, 20),
  "persistent codex selection lane runs"
)
assert_eq(native_codex_seen, native_codex_id, "codex session id is captured")
native_codex_done = false
require("nvime.agents").run({
  provider = "codex",
  lane = "ask",
  prompt = "second native codex",
  persist_session = true,
  resume_session_id = native_codex_seen,
  on_exit = function(result)
    native_codex_done = result.code == 0
  end,
})
assert(
  vim.wait(5000, function()
    return native_codex_done
  end, 20),
  "codex resume lane runs"
)
local native_codex_audit = vim.fn.readfile(audit_path)
local first_native_codex = ""
local second_native_codex = ""
for _, line in ipairs(native_codex_audit) do
  if line:find("first native codex", 1, true) then
    first_native_codex = line
  elseif line:find("second native codex", 1, true) then
    second_native_codex = line
  end
end
assert(not first_native_codex:find("--ephemeral", 1, true), "persistent codex start keeps native session persistence")
assert(second_native_codex:find("exec resume", 1, true), "codex follow-up uses exec resume")
assert(second_native_codex:find(native_codex_id, 1, true), "codex follow-up passes the native session id")

local stale_selection_input = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(stale_selection_input, "nvime://selection-input")
require("nvime.ask").start({
  provider = "claude",
  question = "does this look right?",
  selection = {
    bufnr = chat_buf,
    line1 = 1,
    line2 = 1,
    path = "nvime-chat.txt",
    source = "test",
  },
})
local ask_done = vim.wait(5000, function()
  local selection_buf = require("nvime.state").panels.selection and require("nvime.state").panels.selection.bufnr
  if not selection_buf then
    return false
  end
  local ask = require("nvime.state").selection.last_ask
  return ask and ask.selection.path == "nvime-chat.txt"
end, 20)
assert(ask_done, "read-only selection ask uses selection lane")
local ask_transcript =
  table.concat(vim.api.nvim_buf_get_lines(require("nvime.state").panels.selection.bufnr, 0, -1, false), "\n")
assert(not ask_transcript:find("ask exited", 1, true), "ask transcript omits successful exit status")
assert(not vim.api.nvim_buf_is_valid(stale_selection_input), "selection removes legacy input buffers")
assert(
  require("nvime.state").panels.selection.bufnr ~= chat_buf,
  "selection workflow has a separate buffer from general chat"
)
assert(require("nvime.state").panels.selection.input_bufnr ~= nil, "selection workflow has a prompt buffer")
assert(
  require("nvime.state").panels.selection.input_bufnr == require("nvime.state").panels.selection.bufnr,
  "selection input shares the workflow buffer"
)
assert(
  require("nvime.state").panels.selection.input_winid == require("nvime.state").panels.selection.winid,
  "selection uses one floating window"
)
assert(
  vim.bo[require("nvime.state").panels.selection.bufnr].modifiable == false,
  "selection workflow locks until input focus"
)
assert(require("nvime.selection").session_count() == 1, "selection ask creates one resumable discussion")
require("nvime.selection").save_sessions()
assert(vim.fn.filereadable(sessions_path) == 1, "selection discussions persist to disk")
local persisted_json = table.concat(vim.fn.readfile(sessions_path), "\n")
assert(persisted_json:find("nvime%-chat%.txt", 1, false), "persisted discussions include selection metadata")
assert(persisted_json:find("local function add", 1, true), "persisted discussions include transcript text")
local persisted_panel = require("nvime.state").panels.selection
if persisted_panel and persisted_panel.winid and vim.api.nvim_win_is_valid(persisted_panel.winid) then
  pcall(vim.api.nvim_win_close, persisted_panel.winid, true)
end
require("nvime.state").panels.selection = nil
require("nvime.selection").reload_sessions()
assert(require("nvime.selection").session_count() == 1, "selection discussions reload from disk")
local persisted_session = require("nvime.selection").sessions()[1]
assert(
  persisted_session and persisted_session.selection.path == "nvime-chat.txt",
  "reloaded discussion keeps file/range"
)
require("nvime.selection").open_session(persisted_session.id, { focus_input = false })
assert(
  table
    .concat(vim.api.nvim_buf_get_lines(require("nvime.state").panels.selection.bufnr, 0, -1, false), "\n")
    :find("local function add", 1, true),
  "reopened persisted discussion restores transcript"
)
local selection_panel_for_scroll = require("nvime.state").panels.selection
local selection_scroll_lines = {}
for index = 1, 40 do
  selection_scroll_lines[#selection_scroll_lines + 1] = "selection scroll fixture " .. index
end
require("nvime.selection").append(
  table.concat(selection_scroll_lines, "\n") .. "\n",
  require("nvime.selection").active_session_id()
)
assert(
  vim.wait(1000, function()
    return table
      .concat(vim.api.nvim_buf_get_lines(selection_panel_for_scroll.bufnr, 0, -1, false), "\n")
      :find("selection scroll fixture 40", 1, true)
  end, 20),
  "selection scroll fixture is appended"
)
require("nvime.state").panels.selection.input_active = false
vim.api.nvim_win_set_cursor(selection_panel_for_scroll.winid, { 2, 0 })
vim.api.nvim_win_call(selection_panel_for_scroll.winid, function()
  vim.fn.winrestview({ topline = 1 })
end)
require("nvime.selection").append("selection locked output\n", require("nvime.selection").active_session_id())
assert(
  vim.wait(1000, function()
    return table
      .concat(vim.api.nvim_buf_get_lines(selection_panel_for_scroll.bufnr, 0, -1, false), "\n")
      :find("selection locked output", 1, true)
  end, 20),
  "selection locked output is appended"
)
local selection_locked_view = vim.api.nvim_win_call(selection_panel_for_scroll.winid, vim.fn.winsaveview)
assert_eq(
  vim.api.nvim_win_get_cursor(selection_panel_for_scroll.winid)[1],
  2,
  "selection output preserves cursor when user scrolled away"
)
assert_eq(selection_locked_view.topline, 1, "selection output preserves topline when user scrolled away")
local selection_session_buf = require("nvime.state").panels.selection.bufnr
local selection_session_win = require("nvime.state").panels.selection.winid
if selection_session_win and vim.api.nvim_win_is_valid(selection_session_win) then
  pcall(vim.api.nvim_win_close, selection_session_win, true)
end
vim.cmd("NvimeChats ask")
local chats_panel = require("nvime.state").panels.chats
assert(chats_panel and vim.api.nvim_win_is_valid(chats_panel.winid), "NvimeChats opens a floating picker")
local chats_lines = table.concat(vim.api.nvim_buf_get_lines(chats_panel.bufnr, 0, -1, false), "\n")
assert(chats_lines:find("start new ask session", 1, true), "chats picker offers a new ask session")
assert(chats_lines:find("nvime%-chat%.txt:1%-1"), "chats picker shows selection file and range")
local numeric_discussion = require("nvime.selection").sessions()[1]
assert(numeric_discussion ~= nil, "chats picker has a persisted discussion row to reopen")
vim.api.nvim_set_current_win(chats_panel.winid)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("1", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local panel = require("nvime.state").panels.selection
    return panel
      and panel.bufnr == selection_session_buf
      and panel.winid
      and vim.api.nvim_win_is_valid(panel.winid)
      and require("nvime.selection").active_session_id() == numeric_discussion.id
  end, 20),
  "ask picker numeric shortcut reopens the first discussion"
)
pcall(vim.cmd.stopinsert)
require("nvime.provider").cycle({ scope = "selection" })
local active_selection_session = require("nvime.selection").get_session(require("nvime.selection").active_session_id())
local selection_prompt_after_cycle = table.concat(
  vim.api.nvim_buf_get_lines(
    require("nvime.state").panels.selection.bufnr,
    require("nvime.state").panels.selection.input_start - 1,
    -1,
    false
  ),
  "\n"
)
assert(active_selection_session.provider == "codex", "selection provider cycle updates the active discussion")
assert(selection_prompt_after_cycle:find("[codex ask]$ ", 1, true), "selection provider cycle updates the prompt")
require("nvime.provider").cycle({ scope = "selection" })
assert(active_selection_session.provider == "claude", "selection provider cycle can switch back")
vim.cmd("NvimeChats edit")
local edit_chats_panel = require("nvime.state").panels.chats
local numeric_edit_discussion = require("nvime.selection").sessions()[1]
assert(
  edit_chats_panel and vim.api.nvim_win_is_valid(edit_chats_panel.winid),
  "NvimeChats edit opens a floating picker"
)
assert(numeric_edit_discussion ~= nil, "edit picker has a persisted discussion row to reopen")
vim.api.nvim_set_current_win(edit_chats_panel.winid)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("1", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local panel = require("nvime.state").panels.selection
    return panel
      and panel.winid
      and vim.api.nvim_win_is_valid(panel.winid)
      and require("nvime.selection").active_session_id() == numeric_edit_discussion.id
  end, 20),
  "edit picker numeric shortcut reopens the first discussion"
)
local edit_numeric_prompt = table.concat(
  vim.api.nvim_buf_get_lines(
    require("nvime.state").panels.selection.bufnr,
    require("nvime.state").panels.selection.input_start - 1,
    -1,
    false
  ),
  "\n"
)
assert(edit_numeric_prompt:find("[claude edit]$ ", 1, true), "edit picker numeric shortcut arms the edit prompt")
assert(vim.api.nvim_get_mode().mode ~= "i", "edit picker numeric shortcut opens in normal mode")
assert(
  vim.bo[require("nvime.state").panels.selection.bufnr].modifiable == false,
  "edit picker numeric shortcut keeps prompt locked until input focus"
);
(function()
  local normal_enter_claude = tmp .. "/normal-enter-claude"
  vim.fn.writefile({
    "#!/usr/bin/env sh",
    "printf '%s\\n' 'NVIME_NO_CHANGE'",
    "printf '%s\\n' 'normal enter submitted'",
  }, normal_enter_claude)
  vim.fn.setfperm(normal_enter_claude, "rwxr-xr-x")
  local normal_enter_old_cmd = require("nvime.state").config.providers.claude.cmd
  require("nvime.state").config.providers.claude.cmd = normal_enter_claude
  require("nvime.selection").focus_input()
  local panel = require("nvime.state").panels.selection
  vim.api.nvim_buf_set_lines(panel.bufnr, panel.input_start - 1, panel.input_start, false, {
    "[claude edit]$ hey",
  })
  pcall(vim.cmd.stopinsert)
  panel.input_active = false
  vim.bo[panel.bufnr].modifiable = false
  vim.api.nvim_set_current_win(panel.winid)
  vim.api.nvim_win_set_cursor(panel.winid, { panel.input_start, 0 })
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "xt", false)
  assert(
    vim.wait(5000, function()
      local session = require("nvime.selection").get_session(require("nvime.selection").active_session_id())
      return session
        and table
          .concat(vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false), "\n")
          :find("normal enter submitted", 1, true)
    end, 20),
    "normal-mode Enter submits a filled selection prompt after reopening a discussion"
  )
  require("nvime.state").config.providers.claude.cmd = normal_enter_old_cmd
end)()
vim.cmd("NvimeChats ask")
local delete_panel = require("nvime.state").panels.chats
local delete_row = nil
for row, _ in pairs(delete_panel.row_to_session or {}) do
  delete_row = row
  break
end
assert(delete_row ~= nil, "chats picker has a persisted discussion row to delete")
vim.api.nvim_win_set_cursor(delete_panel.winid, { delete_row, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("dd", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    return require("nvime.selection").session_count() == 0
  end, 20),
  "chats picker dd deletes the selected discussion"
)
require("nvime.selection").save_sessions()
local after_delete_json = table.concat(vim.fn.readfile(sessions_path), "\n")
assert(not after_delete_json:find("nvime%-chat%.txt"), "deleted discussions are removed from persisted sessions");
(function()
  local stale_selection_file = tmp .. "/stale-selection.lua"
  vim.fn.writefile({
    "local function stale()",
    "  return true",
    "end",
  }, stale_selection_file)
  vim.cmd.edit(stale_selection_file)
  local stale_selection_buf = vim.api.nvim_get_current_buf()
  require("nvime.selection").open({
    provider = "claude",
    mode = "edit",
    selection = {
      bufnr = stale_selection_buf,
      line1 = 1,
      line2 = 3,
      path = stale_selection_file,
      source = "test",
    },
    new_session = true,
  })
  local stale_selection_session_id = require("nvime.selection").active_session_id()
  require("nvime.selection").save_sessions()
  pcall(vim.api.nvim_buf_delete, stale_selection_buf, { force = true })
  require("nvime.selection").reload_sessions()
  local stale_no_change_claude = tmp .. "/stale-no-change-claude"
  vim.fn.writefile({
    "#!/usr/bin/env sh",
    "printf '%s\\n' 'NVIME_NO_CHANGE'",
    "printf '%s\\n' 'stale persisted selection reattached'",
  }, stale_no_change_claude)
  vim.fn.setfperm(stale_no_change_claude, "rwxr-xr-x")
  local stale_old_claude_cmd = require("nvime.state").config.providers.claude.cmd
  require("nvime.state").config.providers.claude.cmd = stale_no_change_claude
  local stale_session = require("nvime.selection").get_session(stale_selection_session_id)
  assert(stale_session and stale_session.selection.bufnr == nil, "persisted selection reload drops stale buffer ids")
  require("nvime.edit").start({
    provider = "claude",
    selection = stale_session.selection,
    session_id = stale_selection_session_id,
  })
  require("nvime.selection").focus_input()
  local stale_panel = require("nvime.state").panels.selection
  vim.api.nvim_buf_set_lines(stale_panel.bufnr, stale_panel.input_start - 1, stale_panel.input_start, false, {
    "[claude edit]$ please fix",
  })
  local stale_submit_ok, stale_submit_err = pcall(require("nvime.selection").submit_current)
  assert(stale_submit_ok, tostring(stale_submit_err))
  assert(
    vim.wait(5000, function()
      local session = require("nvime.selection").get_session(stale_selection_session_id)
      return session
        and table
          .concat(vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false), "\n")
          :find("stale persisted selection reattached", 1, true)
    end, 20),
    "persisted selection sessions reattach by path before submit"
  )
  require("nvime.state").config.providers.claude.cmd = stale_old_claude_cmd
  require("nvime.selection").delete_sessions({ stale_selection_session_id })
end)()

require("nvime.ask").start({
  provider = "claude",
  selection = {
    bufnr = chat_buf,
    line1 = 1,
    line2 = 1,
    path = "nvime-chat.txt",
    source = "test",
  },
  new_session = true,
})
local prompt_only_session_id = require("nvime.selection").active_session_id()
assert(vim.api.nvim_get_mode().mode ~= "i", "selection prompt opens in normal mode")
assert(
  vim.bo[require("nvime.state").panels.selection.bufnr].modifiable == false,
  "selection prompt is locked until input focus"
)
local old_select_selection = vim.ui.select
vim.ui.select = function(items, _opts, on_choice)
  on_choice(items[1])
end
require("nvime.selection").choose_prompt()
local templated_selection_prompt = vim.api.nvim_buf_get_lines(
  require("nvime.state").panels.selection.bufnr,
  require("nvime.state").panels.selection.input_start - 1,
  require("nvime.state").panels.selection.input_start,
  false
)[1] or ""
assert(
  templated_selection_prompt:find("Please review this selection", 1, true),
  "selection prompt picker fills the prompt line"
)
vim.ui.select = old_select_selection
pcall(vim.cmd.stopinsert)
require("nvime.selection").delete_sessions({ prompt_only_session_id })

local hidden_ask_claude = tmp .. "/hidden-ask-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "sleep 0.2",
  "printf '%s\\n' 'hidden ask done'",
}, hidden_ask_claude)
vim.fn.setfperm(hidden_ask_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = hidden_ask_claude
local old_notify_selection = vim.notify
local selection_notices = {}
vim.notify = function(msg, level, opts)
  selection_notices[#selection_notices + 1] = tostring(msg)
  return old_notify_selection(msg, level, opts)
end
require("nvime.ask").start({
  provider = "claude",
  question = "finish while hidden",
  selection = {
    bufnr = chat_buf,
    line1 = 1,
    line2 = 1,
    path = "nvime-chat.txt",
    source = "test",
  },
  new_session = true,
})
local hidden_ask_session_id = require("nvime.selection").active_session_id()
require("nvime.selection").close()
assert(
  not require("nvime.selection").is_open(hidden_ask_session_id),
  "hidden ask fixture closes the float while running"
)
assert(
  vim.wait(5000, function()
    local session = require("nvime.selection").get_session(hidden_ask_session_id)
    return session
      and not session.busy
      and table.concat(vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false), "\n"):find("hidden ask done", 1, true)
  end, 20),
  "hidden ask still records the completed response"
)
assert(not require("nvime.selection").is_open(hidden_ask_session_id), "hidden ask completion does not reopen the float")
assert(
  vim.wait(1000, function()
    return vim.tbl_contains(selection_notices, "nvime ask finished. Reopen with :NvimeLast or <leader>nn.")
  end, 20),
  "hidden ask completion notifies"
)
vim.notify = old_notify_selection
require("nvime").open_last()
assert(
  require("nvime.selection").is_open(hidden_ask_session_id),
  "NvimeLast reopens the hidden completed selection discussion"
)
require("nvime.selection").delete_sessions({ hidden_ask_session_id })
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

vim.cmd.edit(tmp .. "/visual-resume.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local previous = true",
  "local current = true",
})
local visual_resume_buf = vim.api.nvim_get_current_buf()
require("nvime.selection").open({
  provider = "codex",
  mode = "ask",
  selection = {
    bufnr = visual_resume_buf,
    line1 = 1,
    line2 = 1,
    path = "visual-resume.lua",
    source = "test",
  },
  new_session = true,
})
local old_visual_session_id = require("nvime.selection").active_session_id()
local old_visual_session = require("nvime.selection").get_session(old_visual_session_id)
old_visual_session.provider_sessions.codex = "codex-visual-resume"
require("nvime.selection").append("previous repo context\n", old_visual_session_id)
assert(
  vim.wait(1000, function()
    local session = require("nvime.selection").get_session(old_visual_session_id)
    return session
      and table
        .concat(vim.api.nvim_buf_get_lines(session.bufnr, 0, -1, false), "\n")
        :find("previous repo context", 1, true)
  end, 20),
  "visual resume fixture has persisted context"
)
require("nvime.selection").save_sessions()
require("nvime.selection").reload_sessions()
local old_select = vim.ui.select
local visual_resume_choices = nil
vim.ui.select = function(items, _opts, on_choice)
  visual_resume_choices = items
  for _, item in ipairs(items) do
    if item.session_id == old_visual_session_id then
      on_choice(item)
      return
    end
  end
  on_choice(items[1])
end
require("nvime.ask").start({
  provider = "claude",
  question = "can we continue this older context on the current line?",
  choose_session = true,
  selection = {
    bufnr = visual_resume_buf,
    line1 = 2,
    line2 = 2,
    path = "visual-resume.lua",
    source = "test",
  },
})
vim.ui.select = old_select
assert(visual_resume_choices and #visual_resume_choices >= 2, "visual selection chooser offers previous discussions")
assert(
  visual_resume_choices[2].label:find("same file", 1, true),
  "visual selection chooser labels same-file discussions"
)
assert(
  vim.wait(5000, function()
    local ask = require("nvime.state").selection.last_ask
    return require("nvime.selection").active_session_id() == old_visual_session_id
      and ask
      and ask.selection.path == "visual-resume.lua"
      and tonumber(ask.selection.line1) == 2
  end, 20),
  "visual selection can resume an older persisted discussion for a new range"
)
local resumed_visual_session = require("nvime.selection").get_session(old_visual_session_id)
assert_eq(resumed_visual_session.provider, "codex", "resuming a previous discussion keeps its provider")
assert_eq(resumed_visual_session.selection.line1, 2, "resumed discussion attaches the newly highlighted range")
assert_eq(resumed_visual_session.key, "visual-resume.lua:2:2", "resumed discussion updates future range matching")
require("nvime.selection").delete_sessions({ old_visual_session_id })

local ask_diff_claude = tmp .. "/ask-diff-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' '```diff'",
  "printf '%s\\n' '--- a/askdiff.lua'",
  "printf '%s\\n' '+++ b/askdiff.lua'",
  "printf '%s\\n' '@@ -1,1 +1,1 @@'",
  "printf '%s\\n' '-local value = 1'",
  "printf '%s\\n' '+local value = 2'",
  "printf '%s\\n' '```'",
}, ask_diff_claude)
vim.fn.setfperm(ask_diff_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = ask_diff_claude
vim.cmd.edit(tmp .. "/askdiff.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 1" })
local ask_diff_target = vim.api.nvim_get_current_buf()
require("nvime.state").current_diff = nil
require("nvime.ask").start({
  provider = "claude",
  question = "could you suggest the diff so I can approve it?",
  selection = {
    bufnr = ask_diff_target,
    line1 = 1,
    line2 = 1,
    path = "askdiff.lua",
    source = "test",
  },
})
assert(
  vim.wait(5000, function()
    local session = require("nvime.state").current_diff
    return session ~= nil and session.file == "askdiff.lua" and session.selection_session_id ~= nil
  end, 20),
  "ask response containing a current-file diff opens inline review"
)
local ask_diff_panel = require("nvime.state").panels.selection
assert(
  not ask_diff_panel or not ask_diff_panel.winid or not vim.api.nvim_win_is_valid(ask_diff_panel.winid),
  "ask output float closes when an inline diff opens"
)
require("nvime.diff").reject_all()
require("nvime.state").config["providers"].claude.cmd = old_claude_cmd

do
  local diff = require("nvime.diff")
  local diff_state = require("nvime.state")
  diff_state.current_diff = nil
  diff_state.diffs = {
    active_by_bufnr = {},
    active_by_path = {},
    queue_by_path = {},
  }

  local function create_named_buffer(name, lines)
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, tmp .. "/" .. name)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    return bufnr
  end

  local function one_line_patch(path, old_line, new_line, line)
    line = line or 1
    return table.concat({
      "```diff",
      "--- a/" .. path,
      "+++ b/" .. path,
      string.format("@@ -%d,1 +%d,1 @@", line, line),
      "-" .. old_line,
      "+" .. new_line,
      "```",
    }, "\n")
  end

  local one_buf = create_named_buffer("multi-one.lua", { "local one = 1" })
  local two_buf = create_named_buffer("multi-two.lua", { "local two = 1" })
  vim.api.nvim_set_current_buf(one_buf)
  diff.start_session({
    bufnr = one_buf,
    line1 = 1,
    line2 = 1,
    path = "multi-one.lua",
    source = "test",
  }, one_line_patch("multi-one.lua", "local one = 1", "local one = 2"), "claude", "first")
  diff.start_session({
    bufnr = two_buf,
    line1 = 1,
    line2 = 1,
    path = "multi-two.lua",
    source = "test",
  }, one_line_patch("multi-two.lua", "local two = 1", "local two = 2"), "claude", "second")
  assert_eq(vim.api.nvim_get_current_buf(), one_buf, "background diff for another file does not steal focus")
  assert_eq(diff_state.diffs.active_by_bufnr[one_buf].file, "multi-one.lua", "first file keeps its active diff")
  assert_eq(diff_state.diffs.active_by_bufnr[two_buf].file, "multi-two.lua", "second file also has an active diff")

  diff.open_view()
  assert_eq(diff_state.current_diff.file, "multi-one.lua", "NvimeDiff opens the current file's diff")
  diff.close_view()
  diff.accept_all()
  assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(one_buf, 0, -1, false), "\n"),
    "local one = 2",
    "accept_all applies the current buffer's diff"
  )
  assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(two_buf, 0, -1, false), "\n"),
    "local two = 1",
    "accept_all leaves other-file diffs untouched"
  )
  vim.api.nvim_set_current_buf(two_buf)
  diff.accept_all()
  assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(two_buf, 0, -1, false), "\n"),
    "local two = 2",
    "switching buffers lets accept_all apply the other active diff"
  )

  diff_state.current_diff = nil
  diff_state.diffs = {
    active_by_bufnr = {},
    active_by_path = {},
    queue_by_path = {},
  }
  local queue_buf = create_named_buffer("queue.lua", { "local one = 1", "local two = 1" })
  vim.api.nvim_set_current_buf(queue_buf)
  local first = diff.start_session({
    bufnr = queue_buf,
    line1 = 1,
    line2 = 2,
    path = "queue.lua",
    source = "test",
  }, one_line_patch("queue.lua", "local one = 1", "local one = 2", 1), "claude", "first")
  local second = diff.start_session({
    bufnr = queue_buf,
    line1 = 1,
    line2 = 2,
    path = "queue.lua",
    source = "test",
  }, one_line_patch("queue.lua", "local two = 1", "local two = 2", 2), "claude", "second")
  assert(first.session and first.session.active, "first same-file diff is active")
  assert(second.queued == true and second.session.queued == true, "second same-file diff is queued")
  assert_eq(#diff_state.diffs.queue_by_path["queue.lua"], 1, "same-file queue keeps the later diff")
  diff.accept_all()
  assert_eq(diff_state.current_diff, second.session, "resolving the first diff promotes the queued diff")
  assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(queue_buf, 0, -1, false), "\n"),
    "local one = 2\nlocal two = 1",
    "first queued-diff accept only applies the first patch"
  )
  diff.accept_all()
  assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(queue_buf, 0, -1, false), "\n"),
    "local one = 2\nlocal two = 2",
    "promoted same-file diff can be accepted after the first resolves"
  )
end

(function()
  local policy = require("nvime.policy")
  local copied_claude = tmp .. "/clyde"
  vim.fn.writefile(vim.fn.readfile(fake_claude), copied_claude)
  vim.fn.setfperm(copied_claude, "rwxr-xr-x")
  local detect_cases = {
    { { fake_claude, "-p", "hi" }, "path command" },
    { "./claude -p hi", "relative path command" },
    { "/tmp/bin/claude -p hi", "absolute path command" },
    { "~/bin/claude -p hi", "home path command" },
    { "bash -c 'claude --dangerously-skip-permissions'", "quoted shell command" },
    { "env CLAUDE_API_KEY=x claude -p hi", "env wrapper command" },
    { "printf x | xargs claude", "xargs indirection command" },
    { 'vim.fn.execute("!claude -p hi")', "execute bang command" },
    { ":silent !claude -p hi", "silent bang command" },
  }
  for _, case in ipairs(detect_cases) do
    assert(policy.detect(case[1]), "policy detects " .. case[2])
  end
  assert(policy.detect({ copied_claude, "-p", "hi" }) == nil, "renamed binaries remain a documented guard limitation")

  local dangerous_cases = {
    { "--dangerously-skip-permissions", "--dangerously-skip-permissions-extra" },
    { "--allow-dangerously-skip-permissions", "--allow-dangerously-skip-permissions-extra" },
    { "--permission-mode bypassPermissions", "--permission-mode bypassPermissionss" },
    { "--permission-mode=bypassPermissions", "--permission-mode=bypassPermissionss" },
    { "--dangerously-bypass-approvals-and-sandbox", "--dangerously-bypass-approvals-and-sandboxed" },
    { "--sandbox danger-full-access", "--sandbox danger-full-accessory" },
    { "--sandbox=danger-full-access", "--sandbox=danger-full-accessory" },
    { "-s danger-full-access", "-s danger-full-accessory" },
  }
  for _, case in ipairs(dangerous_cases) do
    local detected = policy.detect("claude " .. case[1])
    assert(detected and detected.dangerous, "policy flags dangerous arg: " .. case[1])
    local near = policy.detect("claude " .. case[2])
    assert(near and not near.dangerous, "policy does not flag near miss: " .. case[2])
  end

  local blocked_job = vim.fn.jobstart({ fake_claude, "-p", "should be blocked" })
  assert_eq(blocked_job, -1, "direct jobstart block")

  local blocked_system = vim.system({ fake_claude, "-p", "should be blocked" }):wait()
  assert_eq(blocked_system.code, 126, "direct vim.system block")

  local blocked_termopen = vim.fn.termopen({ fake_claude, "-p", "should be blocked" })
  assert_eq(blocked_termopen, -1, "direct termopen block")

  local blocked_fn_system = vim.fn.system({ fake_claude, "-p", "should be blocked" })
  assert(blocked_fn_system:find("nvime blocked command", 1, true), "direct system block")

  local blocked_fn_systemlist = vim.fn.systemlist({ fake_claude, "-p", "should be blocked" })
  assert(blocked_fn_systemlist[1]:find("nvime blocked command", 1, true), "direct systemlist block")

  local uv_handle, uv_err, uv_name = (vim.uv or vim.loop).spawn(
    fake_claude,
    { args = { "-p", "should be blocked" } },
    function() end
  )
  assert(
    uv_handle == nil and tostring(uv_err):find("nvime blocked command", 1, true) and uv_name == "EPERM",
    "direct uv.spawn block"
  )

  local term_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(term_buf, "term://claude -p should-be-blocked")
  vim.api.nvim_exec_autocmds("TermOpen", { buffer = term_buf })
  local term_audit = table.concat(vim.fn.readfile(audit_path), "\n")
  assert(term_audit:find('"surface":"terminal"', 1, true), "TermOpen detector records blocked terminal")
end)()

vim.cmd.edit(tmp .. "/sample.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local function add(a,b)",
  "  return a-b",
  "end",
})
vim.fn.mkdir(tmp .. "/scripts", "p")
vim.fn.writefile({ "#!/usr/bin/env sh", "exit 0" }, tmp .. "/scripts/test")
vim.fn.setfperm(tmp .. "/scripts/test", "rwxr-xr-x")
vim.fn.writefile({ "local sample = require('sample')", "return sample" }, tmp .. "/test_sample.lua")

local target = vim.api.nvim_get_current_buf()
require("nvime.state").current_diff = nil
require("nvime.edit").start({
  provider = "claude",
  intent = "does this look right?",
  selection = {
    bufnr = target,
    line1 = 1,
    line2 = 3,
    path = "sample.lua",
    source = "test",
  },
})
local edit_question_done = vim.wait(5000, function()
  local ask = require("nvime.state").selection.last_ask
  return ask
    and ask.selection.path == "sample.lua"
    and tonumber(ask.selection.line1) == 1
    and tonumber(ask.selection.line2) == 3
end, 20)
assert(edit_question_done, "question-shaped edit routes to ask lane")
local edit_question_transcript =
  table.concat(vim.api.nvim_buf_get_lines(require("nvime.state").panels.selection.bufnr, 0, -1, false), "\n")
assert(
  not edit_question_transcript:find("ask exited", 1, true),
  "question-shaped edit omits successful ask exit status"
)
assert(require("nvime.state").current_diff == nil, "question-shaped edit does not open a diff")

assert(require("nvime.state").selection.last_ask ~= nil, "ask result is retained for edit handoff")
local selection_panel = require("nvime.state").panels.selection
assert(
  require("nvime.state").selection.pending_input.mode == "ask",
  "ask arms a follow-up prompt for the same selection"
)
require("nvime.selection").focus_input()
assert(vim.api.nvim_get_current_win() == selection_panel.input_winid, "ask follow-up focuses the selection prompt")
assert(vim.bo[selection_panel.bufnr].modifiable == true, "selection buffer becomes editable while typing on the prompt")
vim.api.nvim_buf_set_lines(selection_panel.bufnr, 0, 1, false, { "oops" })
assert(
  vim.wait(1000, function()
    local guarded = table.concat(vim.api.nvim_buf_get_lines(selection_panel.bufnr, 0, -1, false), "\n")
    return guarded:find("oops", 1, true) == nil and guarded:find("[claude ask]$ ", 1, true) ~= nil
  end, 20),
  "selection guard restores edits outside the prompt line"
)
local edit_prompt_lnum = selection_panel.input_start
local edit_prompt_line = vim.api.nvim_buf_get_lines(
  selection_panel.bufnr,
  edit_prompt_lnum - 1,
  edit_prompt_lnum,
  false
)[1] or ""
assert(edit_prompt_line:find("[claude ask]$ ", 1, true), "ask follow-up input shows the ask prompt")
vim.api.nvim_buf_set_lines(selection_panel.bufnr, edit_prompt_lnum - 1, edit_prompt_lnum, false, {
  "[claude ask]$ ",
})
vim.api.nvim_win_set_cursor(selection_panel.input_winid, { edit_prompt_lnum, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("Ityped<Esc>", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local line = vim.api.nvim_buf_get_lines(selection_panel.bufnr, edit_prompt_lnum - 1, edit_prompt_lnum, false)[1]
      or ""
    return line == "[claude ask]$ typed"
  end, 20),
  "selection I inserts after the prompt prefix on an empty prompt"
)
pcall(vim.cmd.stopinsert)
vim.api.nvim_buf_set_lines(selection_panel.bufnr, edit_prompt_lnum - 1, edit_prompt_lnum, false, {
  "[claude ask]$ can you please suggest the diff so i can approve it",
})
pcall(vim.cmd.stopinsert)
require("nvime.selection").submit_current()

local ready = vim.wait(5000, function()
  return require("nvime.state").current_diff ~= nil
end, 20)
assert(ready, "timed out waiting for nvime diff session")
assert(
  require("nvime.state").selection.last_edit_prompt:find("Previous read-only reviewer context", 1, true),
  "edit prompt includes previous ask context for same selection"
)
assert(
  require("nvime.state").selection.last_edit_prompt:find("Return exactly one machine-readable response block", 1, true),
  "edit prompt uses a strict machine-readable patch contract"
)
assert(
  require("nvime.state").selection.last_edit_prompt:find("only prose allowed before it is one `RATIONALE:`", 1, true),
  "edit prompt allows exactly one RATIONALE line and forbids any other prose"
)
assert(
  require("nvime.state").selection.last_edit_prompt:find("RATIONALIZATION", 1, true),
  "edit prompt walks the agent through the bug → patch → why self-check"
)
assert(
  require("nvime.state").selection.last_edit_prompt:find("If nvime MCP tools are available", 1, true),
  "edit prompt nudges agents toward bounded nvime MCP context tools"
)
assert(
  require("nvime.state").selection.last_edit_prompt:find("Do not narrate tool use", 1, true),
  "edit prompt forbids tool-use narration before the machine-readable block"
)
assert(
  require("nvime.state").selection.last_edit_prompt:find("verification pass", 1, true),
  "edit prompt asks agents to verify intent edge cases before patching"
)
assert(
  require("nvime.state").selection.last_edit_prompt:find("consume/validate the full input", 1, true),
  "edit prompt calls out parser and normalizer completeness"
)
assert(
  require("nvime.state").selection.last_edit_prompt:find("Precomputed nvime project context", 1, true),
  "edit prompt includes bounded precomputed project context"
)
assert(
  require("nvime.state").selection.last_edit_prompt:find("Detected test runner: ./scripts/test", 1, true),
  "edit prompt detects the selected buffer's project test runner"
)
assert(
  require("nvime.state").selection.last_edit_prompt:find("Related test file: test_sample.lua", 1, true),
  "edit prompt includes a related test excerpt when available"
)
local closed_selection_panel = require("nvime.state").panels.selection
assert(
  not closed_selection_panel
    or not closed_selection_panel.winid
    or not vim.api.nvim_win_is_valid(closed_selection_panel.winid),
  "selection output float closes when an inline diff opens"
)

local session = require("nvime.state").current_diff
assert_eq(#session.hunks, 1, "one generated hunk")
assert_eq(#session.blocks, 2, "replacement diff trims unchanged trailing lines")
assert_eq(#session.visual_groups, 1, "contiguous line units render as one readable change block")
assert(session.bufnr == nil, "diff review does not open a separate diff buffer")
assert(vim.api.nvim_get_current_buf() == target, "diff review focuses the target file")
assert(
  #vim.api.nvim_buf_get_extmarks(target, vim.api.nvim_create_namespace("nvime.diff.inline"), 0, -1, {}) > 0,
  "diff review renders inline extmarks"
)
require("nvime.diff").accept_hunks({ session.hunks[1] })

local lines = vim.api.nvim_buf_get_lines(target, 0, -1, false)
assert_eq(lines[1], "local function add(a, b)", "applied function signature")
assert_eq(lines[2], "  return a + b", "applied function body")
assert_eq(lines[3], "end", "applied function end")

local no_patch_claude = tmp .. "/no-patch-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' 'I do not have a concrete patch for this request.'",
}, no_patch_claude)
vim.fn.setfperm(no_patch_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = no_patch_claude
vim.cmd.edit(tmp .. "/no-patch.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local function add(a,b)",
  "  return a-b",
  "end",
})
local no_patch_target = vim.api.nvim_get_current_buf()
require("nvime.state").current_diff = nil
require("nvime.edit").start({
  provider = "claude",
  intent = "please fix this",
  selection = {
    bufnr = no_patch_target,
    line1 = 1,
    line2 = 3,
    path = "no-patch.lua",
    source = "test",
  },
})
assert(
  vim.wait(5000, function()
    local transcript =
      table.concat(vim.api.nvim_buf_get_lines(require("nvime.state").panels.selection.bufnr, 0, -1, false), "\n")
    return transcript:find("no patch opened", 1, true) ~= nil
  end, 20),
  "edit no-patch result is reported"
)
assert(
  require("nvime.state").selection.pending_input
    and require("nvime.state").selection.pending_input.mode == "edit"
    and type(require("nvime.state").selection.pending_input.on_submit) == "function",
  "edit no-patch result re-arms the edit prompt"
)
require("nvime.state").config.providers.claude.cmd = old_claude_cmd
require("nvime.selection").focus_input()
local no_patch_panel = require("nvime.state").panels.selection
vim.api.nvim_buf_set_lines(no_patch_panel.bufnr, no_patch_panel.input_start - 1, no_patch_panel.input_start, false, {
  "[claude edit]$ please fix",
})
require("nvime.selection").submit_current()
assert(
  vim.wait(5000, function()
    local followup_diff = require("nvime.state").current_diff
    return followup_diff and followup_diff.file == "no-patch.lua"
  end, 20),
  "edit follow-up prompt submits after a no-patch result"
)
require("nvime.diff").reject_all()

local review_route_claude = tmp .. "/review-route-claude"
vim.fn.writefile({
  "#!/usr/bin/env sh",
  "printf '%s\\n' 'Review only: one thing may need a follow-up patch.'",
}, review_route_claude)
vim.fn.setfperm(review_route_claude, "rwxr-xr-x")
require("nvime.state").config.providers.claude.cmd = review_route_claude
require("nvime.state").selection.last_ask = nil
require("nvime.state").current_diff = nil
require("nvime.edit").start({
  provider = "claude",
  intent = "please iterate throughout this readme and ensure correctness. Be nitpicky.",
  selection = {
    bufnr = no_patch_target,
    line1 = 1,
    line2 = 3,
    path = "no-patch.lua",
    source = "test",
  },
})
assert(
  vim.wait(5000, function()
    local ask = require("nvime.state").selection.last_ask
    return ask and ask.question:find("nitpicky", 1, true)
  end, 20),
  "review-shaped edit prompt routes to ask"
)
assert(require("nvime.state").current_diff == nil, "review-shaped edit prompt does not open a diff")
require("nvime.state").config.providers.claude.cmd = old_claude_cmd

local audit = table.concat(vim.fn.readfile(audit_path), "\n")
assert(audit:find('"event":"blocked"', 1, true), "audit records blocked direct invocation")
assert(audit:find('"event":"agent_start"', 1, true), "audit records trusted agent start")
assert(audit:find('"event":"agent_exit"', 1, true), "audit records trusted agent exit");
(function()
  local state = require("nvime.state")
  local audit_mod = require("nvime.audit")
  state.config.audit.log_prompts = false
  audit_mod.write({
    event = "redaction_fixture",
    tool = fake_claude,
    argv = fake_claude .. " -p secret prompt text --output-format stream-json",
    prompt = "secret prompt text",
    input = "secret stdin text",
    response = "secret response text",
  })
  state.config.audit.log_prompts = true
  local redacted = table.concat(vim.fn.readfile(audit_path), "\n")
  assert(redacted:find('"event":"redaction_fixture"', 1, true), "audit redaction fixture is written")
  assert(not redacted:find("secret prompt text", 1, true), "audit redacts prompt text")
  assert(not redacted:find("secret stdin text", 1, true), "audit redacts input text")
  assert(not redacted:find("secret response text", 1, true), "audit redacts response text")
  assert(redacted:find("%[redacted%]"), "audit redacts provider argv when prompt logging is off")

  local old_path = state.config.audit.path
  state.config.audit.path = tmp
  local ok, write_err = pcall(audit_mod.write, { event = "unwritable_fixture" })
  assert(ok, "audit write failure does not throw: " .. tostring(write_err))
  assert(state.audit_write_disabled == true, "audit disables further writes after an unwritable path")
  state.audit_write_disabled = false
  state.audit_write_warned = false
  state.config.audit.path = old_path
end)()

local ok, err = pcall(require("nvime.diff").start_session, {
  bufnr = target,
  line1 = 1,
  line2 = 1,
  path = "sample.lua",
  source = "test",
}, "--- a/other.lua\n+++ b/other.lua\n@@ -1,1 +1,1 @@\n-x\n+y", "claude", "")
assert(not ok and tostring(err):find("outside the current file"), "rejects cross-file diffs")

local unchanged = require("nvime.diff").start_session({
  bufnr = target,
  line1 = 1,
  line2 = 3,
  path = "sample.lua",
  source = "test",
}, "```lua\nlocal function add(a, b)\n  return a + b\nend\n```", "claude", "")
assert(unchanged.status == "no_change", "identical replacement does not open a diff")

local prose_answer = require("nvime.diff").start_session({
  bufnr = target,
  line1 = 1,
  line2 = 3,
  path = "sample.lua",
  source = "test",
}, "Yes, this looks right. I would not change it.", "claude", "")
assert(prose_answer.status == "no_change", "plain review answer does not become a replacement")

local unchanged_diff = require("nvime.diff").start_session(
  {
    bufnr = target,
    line1 = 1,
    line2 = 3,
    path = "sample.lua",
    source = "test",
  },
  "--- a/sample.lua\n+++ b/sample.lua\n@@ -1,3 +1,3 @@\n-local function add(a, b)\n+local function add(a, b)\n-  return a + b\n+  return a + b\n-end\n+end",
  "claude",
  ""
)
assert(unchanged_diff.status == "no_change", "semantically identical diff does not open a diff")

vim.cmd.edit(tmp .. "/nested-fence.md")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "# nvime",
  "",
  "```lua",
  "local value = 1",
  "```",
  "",
  "tail",
})
local nested_fence_target = vim.api.nvim_get_current_buf()
local nested_fence_result = require("nvime.diff").start_session({
  bufnr = nested_fence_target,
  line1 = 1,
  line2 = 7,
  path = "nested-fence.md",
  source = "test",
}, "NVIME_REPLACEMENT\n````markdown\n# nvime\n\n```lua\nlocal value = 2\n```\n\ntail\n````", "claude", "")
assert_eq(nested_fence_result.session.hunks[1].old_start, 4, "four-backtick replacement strips the outer fence")
assert_eq(#nested_fence_result.session.blocks, 1, "nested fenced markdown replacement only changes the edited line")
assert_eq(
  nested_fence_result.session.blocks[1].old_lines[1],
  "local value = 1",
  "nested replacement keeps original changed line"
)
assert_eq(
  nested_fence_result.session.blocks[1].new_lines[1],
  "local value = 2",
  "nested replacement keeps proposed changed line"
)
require("nvime.diff").reject_all()
local prefaced_fence_result = require("nvime.diff").start_session(
  {
    bufnr = nested_fence_target,
    line1 = 1,
    line2 = 7,
    path = "nested-fence.md",
    source = "test",
  },
  "I found one issue.\n\nNVIME_REPLACEMENT\n````markdown\n# nvime\n\n```lua\nlocal value = 3\n```\n\ntail\n````",
  "claude",
  ""
)
assert_eq(prefaced_fence_result.session.hunks[1].old_start, 4, "replacement parser finds NVIME mode after prose")
assert_eq(
  prefaced_fence_result.session.blocks[1].new_lines[1],
  "local value = 3",
  "prefaced replacement keeps nested fence content"
)
require("nvime.diff").reject_all()

vim.cmd.edit(tmp .. "/bare-diff.md")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "# install",
  "The plugin auto-registers with defaults when it is on `runtimepath`, so no",
  'explicit `setup` call is required to use it; call `require("nvime").setup({ ... })`',
  "## next",
})
local bare_diff_target = vim.api.nvim_get_current_buf()
local bare_diff_result = require("nvime.diff").start_session(
  {
    bufnr = bare_diff_target,
    line1 = 1,
    line2 = 4,
    path = "bare-diff.md",
    source = "test",
  },
  'NVIME_DIFF\n```diff\n@@\n The plugin auto-registers with defaults when it is on `runtimepath`, so no\n-explicit `setup` call is required to use it; call `require("nvime").setup({ ... })`\n+explicit `setup` call is required. Call `require("nvime").setup({ ... })` only\n+when you want to override the defaults shown below.\n```',
  "claude",
  ""
)
assert_eq(bare_diff_result.status, "diff", "bare @@ NVIME_DIFF is anchored into a reviewed hunk")
assert_eq(bare_diff_result.session.hunks[1].old_start, 2, "bare @@ diff anchors on selected context")
assert_eq(#bare_diff_result.session.blocks, 2, "bare @@ diff creates line-level review blocks")
require("nvime.diff").accept_all()
local bare_diff_lines = vim.api.nvim_buf_get_lines(bare_diff_target, 0, -1, false)
assert_eq(
  table.concat(bare_diff_lines, "\n"),
  '# install\nThe plugin auto-registers with defaults when it is on `runtimepath`, so no\nexplicit `setup` call is required. Call `require("nvime").setup({ ... })` only\nwhen you want to override the defaults shown below.\n## next',
  "bare @@ diff applies through inline review"
)

vim.cmd.edit(tmp .. "/lazy-install.md")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "```lua",
  "{",
  '  "mengsig/nvime",',
  "  opts = {},",
  "}",
  "```",
  "",
  "With lazy.nvim, `opts = {}` is enough because lazy calls `setup({})` for you.",
  "If the plugin is loaded directly from `runtimepath`, `plugin/nvime.lua`",
  'registers the defaults. Call `require("nvime").setup({ ... })` only when you',
  "want to override them.",
})
local lazy_install_target = vim.api.nvim_get_current_buf()
local lazy_install_result = require("nvime.diff").start_session(
  {
    bufnr = lazy_install_target,
    line1 = 8,
    line2 = 11,
    path = "lazy-install.md",
    source = "test",
  },
  'NVIME_DIFF\n```diff\n--- a/lazy-install.md\n+++ b/lazy-install.md\n@@ -6,6 +6,7 @@\n```\n\n-With lazy.nvim, `opts = {}` is enough because lazy calls `setup({})` for you.\n+With lazy.nvim, `opts = {}` is enough because lazy calls `setup({})` for you,\n+and it is where you can pass overrides.\n If the plugin is loaded directly from `runtimepath`, `plugin/nvime.lua`\n registers the defaults. Call `require("nvime").setup({ ... })` only when you\n want to override them.\n```',
  "codex",
  ""
)
assert_eq(lazy_install_result.status, "diff", "agent diff with unprefixed context lines still opens a patch")
assert(
  lazy_install_result.session.warnings and #lazy_install_result.session.warnings > 0,
  "malformed (unclosed-fence) diff surfaces a truncation warning"
)
lazy_install_result.session.warnings_overridden = true
require("nvime.diff").accept_all()
local lazy_install_lines = vim.api.nvim_buf_get_lines(lazy_install_target, 0, -1, false)
assert_eq(
  table.concat(lazy_install_lines, "\n"),
  '```lua\n{\n  "mengsig/nvime",\n  opts = {},\n}\n```\n\nWith lazy.nvim, `opts = {}` is enough because lazy calls `setup({})` for you,\nand it is where you can pass overrides.\nIf the plugin is loaded directly from `runtimepath`, `plugin/nvime.lua`\nregisters the defaults. Call `require("nvime").setup({ ... })` only when you\nwant to override them.',
  "agent diff with unprefixed context applies the intended README text"
)

vim.cmd.edit(tmp .. "/duplicate-diff.md")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "The plugin auto-registers with defaults when it is on `runtimepath`, so no",
  'explicit `setup` call is required. Call `require("nvime").setup({ ... })` only',
  "when you want to override the defaults.",
})
local duplicate_diff_target = vim.api.nvim_get_current_buf()
local duplicate_diff = table.concat({
  "NVIME_DIFF",
  "```diff",
  "--- a/duplicate-diff.md",
  "+++ b/duplicate-diff.md",
  "@@ -1,3 +1,4 @@",
  "-The plugin auto-registers with defaults when it is on `runtimepath`, so no",
  '-explicit `setup` call is required. Call `require("nvime").setup({ ... })` only',
  "-when you want to override the defaults.",
  "+With lazy.nvim, `opts = {}` is enough - lazy will call `setup({})` for you.",
  "+If your manager doesn't do that, nvime still auto-registers with defaults as",
  '+soon as it is on `runtimepath`. Call `require("nvime").setup({ ... })`',
  "+explicitly only to override the defaults.",
  "```NVIME_DIFF",
  "```diff",
  "--- a/duplicate-diff.md",
  "+++ b/duplicate-diff.md",
  "@@ -1,3 +1,4 @@",
  "-The plugin auto-registers with defaults when it is on `runtimepath`, so no",
  '-explicit `setup` call is required. Call `require("nvime").setup({ ... })` only',
  "-when you want to override the defaults.",
  "+With lazy.nvim, `opts = {}` is enough - lazy will call `setup({})` for you.",
  "+If your manager doesn't do that, nvime still auto-registers with defaults as",
  '+soon as it is on `runtimepath`. Call `require("nvime").setup({ ... })`',
  "+explicitly only to override the defaults.",
  "```",
}, "\n")
local duplicate_diff_result = require("nvime.diff").start_session({
  bufnr = duplicate_diff_target,
  line1 = 1,
  line2 = 3,
  path = "duplicate-diff.md",
  source = "test",
}, duplicate_diff, "claude", "")
assert_eq(#duplicate_diff_result.session.hunks, 1, "duplicate NVIME_DIFF blocks collapse to one hunk")
require("nvime.diff").accept_all()
local duplicate_diff_lines = vim.api.nvim_buf_get_lines(duplicate_diff_target, 0, -1, false)
assert_eq(
  table.concat(duplicate_diff_lines, "\n"),
  'With lazy.nvim, `opts = {}` is enough - lazy will call `setup({})` for you.\nIf your manager doesn\'t do that, nvime still auto-registers with defaults as\nsoon as it is on `runtimepath`. Call `require("nvime").setup({ ... })`\nexplicitly only to override the defaults.',
  "duplicate NVIME_DIFF accept-all applies only proposed content once"
)
assert(
  not table.concat(duplicate_diff_lines, "\n"):find("%+%+ b/duplicate%-diff%.md"),
  "diff file header is never applied as content"
)

vim.cmd.edit(tmp .. "/generate.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "",
  "local after = true",
})
local generate_target = vim.api.nvim_get_current_buf()
local generate_result = require("nvime.diff").start_session({
  bufnr = generate_target,
  line1 = 1,
  line2 = 1,
  path = "generate.lua",
  source = "range",
}, 'NVIME_REPLACEMENT\n```lua\nlocal function greet(name)\n  return "hello " .. name\nend\n```', "claude", "")
assert(generate_result.status == "diff", "blank selected range can generate code")
require("nvime.diff").accept_all()
local generated_lines = vim.api.nvim_buf_get_lines(generate_target, 0, -1, false)
assert_eq(
  table.concat(generated_lines, "\n"),
  'local function greet(name)\n  return "hello " .. name\nend\nlocal after = true',
  "generated function replaces the highlighted blank area only"
)

vim.cmd.edit(tmp .. "/.gitignore")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "node_modules/",
})
local gitignore_target = vim.api.nvim_get_current_buf()
local gitignore_result = require("nvime.diff").start_session({
  bufnr = gitignore_target,
  line1 = 1,
  line2 = 1,
  path = ".gitignore",
  source = "range",
}, "NVIME_REPLACEMENT\n```gitignore\nnode_modules/\ndist/\n.env\n*.log\n```", "claude", "")
assert(gitignore_result.status == "diff", "non-code selected range can be completed")
assert_eq(gitignore_result.session.hunks[1].old_count, 0, "completion replacement trims unchanged selected prefix")
require("nvime.diff").accept_all()
local gitignore_lines = vim.api.nvim_buf_get_lines(gitignore_target, 0, -1, false)
assert_eq(
  table.concat(gitignore_lines, "\n"),
  "node_modules/\ndist/\n.env\n*.log",
  "gitignore completion applies through reviewed diff"
)

vim.cmd.edit(tmp .. "/blocks.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "local a = 1",
  "local b = 2",
  "local c = 3",
  "local d = 4",
  "local e = 5",
})
local block_target = vim.api.nvim_get_current_buf()
local block_session_result = require("nvime.diff").start_session(
  {
    bufnr = block_target,
    line1 = 1,
    line2 = 5,
    path = "blocks.lua",
    source = "test",
  },
  "--- a/blocks.lua\n+++ b/blocks.lua\n@@ -1,5 +1,5 @@\n local a = 1\n-local b = 2\n+local b = 20\n local c = 3\n-local d = 4\n+local d = 40\n local e = 5",
  "claude",
  ""
)
assert(block_session_result.status == "diff", "multi-line inline diff opens")
assert_eq(#block_session_result.session.blocks, 2, "diff splits separated changes into line units")
assert_eq(#block_session_result.session.visual_groups, 2, "separated changes render as separate readable blocks")
require("nvime.diff").open_view()
local review_workspace = require("nvime.state").current_diff.review
assert(
  review_workspace
    and vim.api.nvim_tabpage_is_valid(review_workspace.tabpage)
    and vim.api.nvim_win_is_valid(review_workspace.proposed_winid)
    and vim.api.nvim_win_is_valid(review_workspace.target_winid),
  "diff review workspace opens a two-pane tab"
)
assert(
  vim.wo[review_workspace.target_winid].winhighlight:find("WinSeparator:NvimeBorder", 1, true),
  "diff review workspace uses nvime chrome for separators"
)
assert_eq(
  table.concat(require("nvime.state").current_diff.original_lines, "\n"),
  "local a = 1\nlocal b = 2\nlocal c = 3\nlocal d = 4\nlocal e = 5",
  "diff review session retains the pre-review snapshot"
)
assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(review_workspace.proposed_bufnr, 0, -1, false), "\n"),
  "local a = 1\nlocal b = 20\nlocal c = 3\nlocal d = 40\nlocal e = 5",
  "diff review proposed pane shows the full agent result"
)
assert(
  vim.fn.maparg("q", "n", false, true).buffer == 1 or vim.api.nvim_buf_get_keymap(block_target, "n")[1] ~= nil,
  "diff review installs a buffer-local q on the editable pane"
)
assert(vim.bo[block_target].modifiable, "diff review target pane remains directly editable")
require("nvime.diff").close_view()
vim.api.nvim_set_current_buf(block_target)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
require("nvime.diff").accept_current()
local block_lines = vim.api.nvim_buf_get_lines(block_target, 0, -1, false)
assert_eq(block_lines[2], "local b = 20", "accept_current applies only the current line")
assert_eq(block_lines[4], "local d = 4", "accept_current leaves other pending lines untouched")
vim.api.nvim_win_set_cursor(0, { 4, 0 })
require("nvime.diff").reject_current()
local review_state = require("nvime.diff").remaining_text()
assert(review_state:find("Accepted lines:", 1, true), "diff discussion state includes accepted lines")
assert(review_state:find("Rejected lines:", 1, true), "diff discussion state includes rejected lines")

vim.cmd.edit(tmp .. "/unequal.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "alpha",
  "beta",
  "gamma",
})
local unequal_target = vim.api.nvim_get_current_buf()
local unequal_result = require("nvime.diff").start_session({
  bufnr = unequal_target,
  line1 = 1,
  line2 = 3,
  path = "unequal.lua",
  source = "test",
}, "--- a/unequal.lua\n+++ b/unequal.lua\n@@ -1,3 +1,4 @@\n-alpha\n-beta\n+ALPHA\n+BETA\n+EXTRA\n gamma", "claude", "")
assert_eq(#unequal_result.session.blocks, 3, "unequal replacement is still split into line units")
assert_eq(#unequal_result.session.visual_groups, 1, "unequal contiguous replacement renders as one block")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
require("nvime.diff").accept_current()
local unequal_lines = vim.api.nvim_buf_get_lines(unequal_target, 0, -1, false)
assert_eq(unequal_lines[1], "alpha", "accepting one line leaves earlier pending line unchanged")
assert_eq(unequal_lines[2], "BETA", "accepting one line applies only that changed line")
assert_eq(unequal_lines[3], "gamma", "accepting one line does not apply pending insertion")

vim.cmd.edit(tmp .. "/group.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "one",
  "two",
  "three",
})
local group_target = vim.api.nvim_get_current_buf()
local group_result = require("nvime.diff").start_session({
  bufnr = group_target,
  line1 = 1,
  line2 = 3,
  path = "group.lua",
  source = "test",
}, "--- a/group.lua\n+++ b/group.lua\n@@ -1,3 +1,3 @@\n-one\n-two\n-three\n+ONE\n+TWO\n+THREE", "claude", "")
assert_eq(#group_result.session.blocks, 3, "group fixture keeps line-level review units")
assert_eq(#group_result.session.visual_groups, 1, "group fixture renders one readable block")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ga", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local group_lines = vim.api.nvim_buf_get_lines(group_target, 0, -1, false)
    return table.concat(group_lines, "\n") == "ONE\nTWO\nTHREE"
  end, 20),
  "normal ga accepts the whole visual block"
)
assert(vim.fn.maparg("gu", "n") ~= "", "undo accepted block mapping is installed")
do
  -- The inline diff buffer advertises its keys through the shared g? overlay.
  local keyhelp = require("nvime.keyhelp")
  keyhelp.close()
  local g_help
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(group_target, "n")) do
    if m.lhs == "g?" then
      g_help = m
    end
  end
  assert(g_help and g_help.callback, "inline diff binds g? to a help callback")
  g_help.callback()
  assert(keyhelp.is_open(), "diff g? opens the keyhelp overlay")
  local diff_help =
    table.concat(vim.api.nvim_buf_get_lines(require("nvime.state").panels.keyhelp.bufnr, 0, -1, false), "\n")
  assert(diff_help:find("Navigate", 1, true), "diff help shows the Navigate section")
  assert(diff_help:find("accept the block", 1, true), "diff help documents accept")
  assert(diff_help:find("undo the last accept", 1, true), "inline diff help includes gu undo")
  keyhelp.close()
  vim.api.nvim_set_current_win(vim.fn.bufwinid(group_target))
end
require("nvime.diff").undo_last_accept()
assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(group_target, 0, -1, false), "\n"),
  "ONE\nTWO\nthree",
  "undo restores the most recently accepted block"
)
require("nvime.diff").undo_last_accept()
require("nvime.diff").undo_last_accept()
assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(group_target, 0, -1, false), "\n"),
  "one\ntwo\nthree",
  "accepted block undo can unwind multiple accepted blocks"
)

vim.cmd.edit(tmp .. "/accept-all.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "left",
  "middle",
  "right",
})
local accept_all_target = vim.api.nvim_get_current_buf()
require("nvime.diff").start_session({
  bufnr = accept_all_target,
  line1 = 1,
  line2 = 3,
  path = "accept-all.lua",
  source = "test",
}, "--- a/accept-all.lua\n+++ b/accept-all.lua\n@@ -1,3 +1,3 @@\n-left\n+LEFT\n middle\n-right\n+RIGHT", "claude", "")
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gA", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local accept_all_lines = vim.api.nvim_buf_get_lines(accept_all_target, 0, -1, false)
    return table.concat(accept_all_lines, "\n") == "LEFT\nmiddle\nRIGHT"
  end, 20),
  "normal gA accepts all unresolved blocks"
)
assert(vim.fn.maparg("gA!", "n") ~= "", "force accept-all mapping is installed")

vim.cmd.edit(tmp .. "/iterative-undo.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "alpha",
  "bravo",
  "charlie",
  "delta",
})
local iterative_undo_target = vim.api.nvim_get_current_buf()
require("nvime.diff").start_session(
  {
    bufnr = iterative_undo_target,
    line1 = 1,
    line2 = 4,
    path = "iterative-undo.lua",
    source = "test",
  },
  "--- a/iterative-undo.lua\n+++ b/iterative-undo.lua\n@@ -1,4 +1,4 @@\n-alpha\n+ALPHA\n bravo\n-charlie\n+CHARLIE\n delta",
  "claude",
  ""
)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ga", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local lines = vim.api.nvim_buf_get_lines(iterative_undo_target, 0, -1, false)
    return table.concat(lines, "\n") == "ALPHA\nbravo\ncharlie\ndelta"
  end, 20),
  "iterative ga accepts the first separated block"
)
vim.cmd("undo")
require("nvime.diff").accept_all()
assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(iterative_undo_target, 0, -1, false), "\n"),
  "ALPHA\nbravo\nCHARLIE\ndelta",
  "gA after native undo reconciles stale accepted state"
)

vim.cmd.edit(tmp .. "/iterative-group-undo.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "one",
  "two",
  "three",
})
local iterative_group_undo_target = vim.api.nvim_get_current_buf()
require("nvime.diff").start_session(
  {
    bufnr = iterative_group_undo_target,
    line1 = 1,
    line2 = 3,
    path = "iterative-group-undo.lua",
    source = "test",
  },
  "--- a/iterative-group-undo.lua\n+++ b/iterative-group-undo.lua\n@@ -1,3 +1,3 @@\n-one\n-two\n-three\n+ONE\n+TWO\n+THREE",
  "claude",
  ""
)
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ga", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local lines = vim.api.nvim_buf_get_lines(iterative_group_undo_target, 0, -1, false)
    return table.concat(lines, "\n") == "ONE\nTWO\nTHREE"
  end, 20),
  "iterative ga accepts a multi-line visual block"
)
vim.cmd("undo")
require("nvime.diff").accept_all()
assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(iterative_group_undo_target, 0, -1, false), "\n"),
  "ONE\nTWO\nTHREE",
  "gA after native undo reconciles a multi-line ga block"
)

do
  vim.cmd.edit(tmp .. "/cookie-repeat.py")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "def parse_cookie(ts, username):",
    "    try:",
    "        timestamp = int(ts)",
    "    except ValueError:",
    "        return None",
    "    if time.time() - timestamp > COOKIE_MAX_AGE:",
    "        return None",
    "    return username",
  })
  local cookie_repeat_target = vim.api.nvim_get_current_buf()
  local cookie_repeat_diff =
    "--- a/cookie-repeat.py\n+++ b/cookie-repeat.py\n@@ -1,8 +1,8 @@\n def parse_cookie(ts, username):\n     try:\n+        return None\n         timestamp = int(ts)\n     except ValueError:\n-        return None\n     if time.time() - timestamp > COOKIE_MAX_AGE:\n         return None\n     return username"
  require("nvime.diff").start_session({
    bufnr = cookie_repeat_target,
    line1 = 1,
    line2 = 8,
    path = "cookie-repeat.py",
    source = "test",
  }, cookie_repeat_diff, "claude", "")
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  require("nvime.diff").accept_current_group()
  local cookie_after_first_ga = table.concat(vim.api.nvim_buf_get_lines(cookie_repeat_target, 0, -1, false), "\n")
  require("nvime.diff").accept_current_group()
  local cookie_after_second_ga = table.concat(vim.api.nvim_buf_get_lines(cookie_repeat_target, 0, -1, false), "\n")
  require("nvime.diff").accept_all()
  require("nvime.diff").accept_all()
  assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(cookie_repeat_target, 0, -1, false), "\n"),
    cookie_after_second_ga,
    "repeated accepts after an insertion/deletion hunk are idempotent"
  )
  assert(
    cookie_after_second_ga:find(cookie_after_first_ga, 1, true) == nil,
    "second ga resolves the deletion instead of appending the first insertion again"
  )
  assert_eq(
    select(2, cookie_after_second_ga:gsub("timestamp = int%(ts%)", "")),
    1,
    "cookie-shaped repeated accepts do not duplicate timestamp parsing"
  )
end

vim.cmd.edit(tmp .. "/iterative-redo.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "alpha",
  "bravo",
  "charlie",
  "delta",
})
local iterative_redo_target = vim.api.nvim_get_current_buf()
require("nvime.diff").start_session(
  {
    bufnr = iterative_redo_target,
    line1 = 1,
    line2 = 4,
    path = "iterative-redo.lua",
    source = "test",
  },
  "--- a/iterative-redo.lua\n+++ b/iterative-redo.lua\n@@ -1,4 +1,4 @@\n-alpha\n+ALPHA\n bravo\n-charlie\n+CHARLIE\n delta",
  "claude",
  ""
)
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("ga", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local lines = vim.api.nvim_buf_get_lines(iterative_redo_target, 0, -1, false)
    return table.concat(lines, "\n") == "ALPHA\nbravo\ncharlie\ndelta"
  end, 20),
  "iterative ga accepts before native redo"
)
vim.cmd("undo")
require("nvime.diff").refresh_view()
vim.cmd("redo")
require("nvime.diff").accept_all()
assert_eq(
  table.concat(vim.api.nvim_buf_get_lines(iterative_redo_target, 0, -1, false), "\n"),
  "ALPHA\nbravo\nCHARLIE\ndelta",
  "gA after native undo and redo does not duplicate or skip accepted blocks"
)

do
  vim.cmd.edit(tmp .. "/conflict.lua")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "one",
    "two",
  })
  local conflict_target = vim.api.nvim_get_current_buf()
  local conflict_result = require("nvime.diff").start_session({
    bufnr = conflict_target,
    line1 = 1,
    line2 = 2,
    path = "conflict.lua",
    source = "test",
  }, "--- a/conflict.lua\n+++ b/conflict.lua\n@@ -1,2 +1,2 @@\n-one\n+ONE\n two", "claude", "")
  vim.api.nvim_buf_set_lines(conflict_target, 0, 1, false, { "manual one" })
  require("nvime.diff").accept_all()
  assert_eq(conflict_result.session.blocks[1].status, "conflict", "drifted live text marks the block conflicted")
  assert_eq(
    vim.api.nvim_buf_get_lines(conflict_target, 0, 1, false)[1],
    "manual one",
    "normal accept refuses to overwrite drifted live text"
  )
  local saw_conflict_hl = false
  for _, mark in
    ipairs(vim.api.nvim_buf_get_extmarks(conflict_target, vim.api.nvim_create_namespace("nvime.diff.inline"), 0, -1, {
      details = true,
    }))
  do
    local details = mark[4] or {}
    saw_conflict_hl = saw_conflict_hl or details.line_hl_group == "NvimeConflict"
  end
  assert(saw_conflict_hl, "conflicted blocks render with a distinct highlight")
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  vim.cmd("NvimeAccept!")
  assert_eq(
    vim.api.nvim_buf_get_lines(conflict_target, 0, 1, false)[1],
    "ONE",
    "NvimeAccept! force applies a conflicted block"
  )
  local conflict_audit = table.concat(vim.fn.readfile(audit_path), "\n")
  assert(conflict_audit:find('"event":"block_force_applied"', 1, true), "force accept is audited")
end

vim.cmd.edit(tmp .. "/deny.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "one",
  "two",
  "three",
  "four",
})
local deny_target = vim.api.nvim_get_current_buf()
local deny_result = require("nvime.diff").start_session({
  bufnr = deny_target,
  line1 = 1,
  line2 = 4,
  path = "deny.lua",
  source = "test",
}, "--- a/deny.lua\n+++ b/deny.lua\n@@ -1,4 +1,4 @@\n-one\n+ONE\n two\n-three\n+THREE\n four", "claude", "")
assert_eq(#deny_result.session.visual_groups, 2, "deny fixture renders two readable blocks")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gb", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    return deny_result.session.blocks[1].status == "rejected" and deny_result.session.blocks[2].status == "pending"
  end, 20),
  "normal gb rejects the current visual block"
)
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("gB", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    return deny_result.session.blocks[1].status == "rejected" and deny_result.session.blocks[2].status == "rejected"
  end, 20),
  "normal gB rejects all remaining visual blocks"
)
local deny_lines = vim.api.nvim_buf_get_lines(deny_target, 0, -1, false)
assert_eq(table.concat(deny_lines, "\n"), "one\ntwo\nthree\nfour", "reject bindings leave current code untouched")

vim.cmd.edit(tmp .. "/visual.lua")
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "red",
  "green",
  "blue",
})
local visual_target = vim.api.nvim_get_current_buf()
require("nvime.diff").start_session({
  bufnr = visual_target,
  line1 = 1,
  line2 = 3,
  path = "visual.lua",
  source = "test",
}, "--- a/visual.lua\n+++ b/visual.lua\n@@ -1,3 +1,3 @@\n-red\n-green\n-blue\n+RED\n+GREEN\n+BLUE", "claude", "")
vim.api.nvim_win_set_cursor(0, { 1, 0 })
vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("Vjga", true, false, true), "xt", false)
assert(
  vim.wait(1000, function()
    local visual_lines = vim.api.nvim_buf_get_lines(visual_target, 0, -1, false)
    return visual_lines[1] == "RED" and visual_lines[2] == "GREEN" and visual_lines[3] == "blue"
  end, 20),
  "visual ga accepts every pending line touched by the visual range"
)

vim.cmd.edit(tmp .. "/large.lua")
local large_original = {}
local large_diff = {
  "--- a/large.lua",
  "+++ b/large.lua",
  "@@ -1,25 +1,25 @@",
}
for index = 1, 25 do
  large_original[#large_original + 1] = string.format("line_%02d", index)
  large_diff[#large_diff + 1] = "-" .. string.format("line_%02d", index)
end
for index = 1, 25 do
  large_diff[#large_diff + 1] = "+" .. string.format("LINE_%02d", index)
end
vim.api.nvim_buf_set_lines(0, 0, -1, false, large_original)
local large_target = vim.api.nvim_get_current_buf()
local large_result = require("nvime.diff").start_session({
  bufnr = large_target,
  line1 = 1,
  line2 = 25,
  path = "large.lua",
  source = "test",
}, table.concat(large_diff, "\n"), "claude", "")
assert_eq(#large_result.session.blocks, 25, "large contiguous diff keeps line-level review units")
assert(#large_result.session.visual_groups > 1, "large contiguous diff splits into review-sized visual blocks")
assert(#large_result.session.visual_groups[1].blocks <= 12, "default visual blocks stay small")
local first_large_group_size = #large_result.session.visual_groups[1].blocks
vim.api.nvim_win_set_cursor(0, { 1, 0 })
require("nvime.diff").accept_current_group()
local large_lines = vim.api.nvim_buf_get_lines(large_target, 0, -1, false)
assert_eq(large_lines[1], "LINE_01", "accept_current_group applies the first segmented block")
assert_eq(
  large_lines[first_large_group_size],
  string.format("LINE_%02d", first_large_group_size),
  "accept_current_group applies the end of the first segmented block"
)
assert_eq(
  large_lines[first_large_group_size + 1],
  string.format("line_%02d", first_large_group_size + 1),
  "accept_current_group leaves later visual blocks pending"
)

do
  vim.cmd.edit(tmp .. "/truncate-zig.zig")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "pub fn keep() void {",
    "    return;",
    "}",
    "",
    "pub fn rewrite() i32 {",
    "    var x: i32 = 1;",
    "    return x;",
    "}",
  })
  local target = vim.api.nvim_get_current_buf()
  local response = table.concat({
    "NVIME_DIFF",
    "```diff",
    "--- a/truncate-zig.zig",
    "+++ b/truncate-zig.zig",
    "@@ -5,4 +5,8 @@",
    "-pub fn rewrite() i32 {",
    "-    var x: i32 = 1;",
    "-    return x;",
    "-}",
    "+pub fn rewrite() i32 {",
    "+    var x: i32 = 1;",
    "+    if (x > 0) {",
    "+        x += 1;",
    "```",
  }, "\n")
  local result = require("nvime.diff").start_session({
    bufnr = target,
    line1 = 5,
    line2 = 8,
    path = "truncate-zig.zig",
    source = "test",
  }, response, "claude", "")
  assert_eq(result.status, "diff", "truncated diff still opens for review")
  assert(
    result.session.warnings and #result.session.warnings > 0,
    "truncated diff (missing closing braces) raises a truncation warning"
  )
  local warning_text = table.concat(result.session.warnings, " | ")
  assert(
    warning_text:find("delimiter imbalance", 1, true),
    "delimiter imbalance is named in the truncation warning: " .. warning_text
  )
  require("nvime.diff").reject_all()
end

do
  -- Rationale capture: the diff parser strips a leading RATIONALE: line and
  -- stores the text on the session for review-time display.
  vim.cmd.edit(tmp .. "/rationale.lua")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "local function add(a, b)",
    "  return a + b",
    "end",
  })
  local target = vim.api.nvim_get_current_buf()
  local response = table.concat({
    "RATIONALE: bug: nothing wrong; patch: rename param; why correct: pure rename, semantics unchanged.",
    "NVIME_REPLACEMENT",
    "```lua",
    "local function add(left, right)",
    "  return left + right",
    "end",
    "```",
  }, "\n")
  local result = require("nvime.diff").start_session({
    bufnr = target,
    line1 = 1,
    line2 = 3,
    path = "rationale.lua",
    source = "test",
  }, response, "claude", "")
  assert_eq(result.status, "diff", "rationale-prefixed response opens cleanly")
  assert(
    result.session.rationale and result.session.rationale:find("rename param", 1, true),
    "rationale captured on the session for the review banner"
  )
  require("nvime.diff").reject_all()

  -- NVIME_NO_CHANGE response also carries a rationale field
  local no_change_result = require("nvime.diff").start_session(
    {
      bufnr = target,
      line1 = 1,
      line2 = 3,
      path = "rationale.lua",
      source = "test",
    },
    "RATIONALE: bug: none; patch: none; why: code already correct.\nNVIME_NO_CHANGE\nalready handles this",
    "claude",
    ""
  )
  assert_eq(no_change_result.status, "no_change", "no_change still recognized after rationale")
  assert(
    no_change_result.rationale and no_change_result.rationale:find("already correct", 1, true),
    "rationale exposed on no_change result"
  )
end

do
  vim.cmd.edit(tmp .. "/balanced.lua")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "local function add(a, b)",
    "  return a + b",
    "end",
  })
  local target = vim.api.nvim_get_current_buf()
  local result = require("nvime.diff").start_session({
    bufnr = target,
    line1 = 1,
    line2 = 3,
    path = "balanced.lua",
    source = "test",
  }, "NVIME_REPLACEMENT\n```lua\nlocal function add(a, b)\n  return (a + b)\nend\n```", "claude", "")
  assert_eq(result.status, "diff", "balanced replacement opens cleanly")
  assert(
    not (result.session.warnings and #result.session.warnings > 0),
    "balanced replacement does not raise a false-positive truncation warning"
  )
  require("nvime.diff").reject_all()
end

(function()
  -- Plan module smoke tests: schema, CRUD, status transitions.
  local plan = require("nvime.plan")
  local plans_dir = tmp .. "/plans"
  vim.fn.mkdir(plans_dir, "p")
  state = require("nvime.state")
  state.config.plan = state.config.plan or {}
  state.config.plan.dir = plans_dir
  state.plan.loaded = false
  state.plan.plans = nil

  assert_eq(#plan.plans(), 0, "plan: starts empty")
  assert_eq(plan.next_plan_number(), 1, "plan: next number starts at 1")
  assert_eq(plan.slugify("Add Provider Registry!"), "add-provider-registry", "plan: slugify normalizes title")
  assert_eq(plan.format_id(1, "demo"), "0001-demo", "plan: format_id zero-pads")

  -- Hand-write a plan to disk and load it back.
  local plan_id = "0001-demo"
  local plan_path = plans_dir .. "/" .. plan_id
  vim.fn.mkdir(plan_path, "p")
  local plan_data = {
    version = 1,
    id = plan_id,
    title = "Demo plan",
    why = "Verify plan parsing in headless tests.",
    created_at = os.time(),
    updated_at = os.time(),
    files_estimated = { "README.md" },
    acceptance = { { id = 1, text = "scripts/test passes", status = "pending" } },
    steps = {
      {
        id = 1,
        intent = "Append a banner to README.md",
        file = "README.md",
        range = { line1 = 1, line2 = 1 },
        depends_on = {},
        tests = { "./scripts/test" },
        status = "pending",
      },
      {
        id = 2,
        intent = "Add a CHANGELOG entry",
        file = "CHANGELOG.md",
        range = "new",
        depends_on = { 1 },
        tests = {},
        status = "pending",
      },
    },
  }
  local fd = io.open(plan_path .. "/plan.json", "w")
  fd:write(vim.json.encode(plan_data))
  fd:close()

  state.plan.loaded = false
  state.plan.plans = nil
  local plans = plan.plans()
  assert_eq(#plans, 1, "plan: discovers plans on disk")
  assert_eq(plans[1].id, plan_id, "plan: discovered id matches")

  local fetched = plan.get(plan_id)
  assert(fetched, "plan: get returns plan")
  assert_eq(#fetched.steps, 2, "plan: step count")

  local ok, err = plan.set_step_status(plan_id, 1, "done")
  assert(ok, "plan: status set ok: " .. tostring(err))
  state.plan.loaded = false
  state.plan.plans = nil
  fetched = plan.get(plan_id)
  assert_eq(fetched.steps[1].status, "done", "plan: persisted status update")

  local rejected = plan.set_step_status(plan_id, 99, "done")
  assert(not rejected, "plan: rejects unknown step id")

  -- Picker rendering is exercised via direct call; should not error.
  plan.picker()
  local picker_buf = vim.fn.bufnr("nvime://plans")
  assert(picker_buf ~= -1, "plan: picker buffer exists")
  local picker_lines = vim.api.nvim_buf_get_lines(picker_buf, 0, -1, false)
  local found_plan_row = false
  for _, line in ipairs(picker_lines) do
    if line:find(plan_id, 1, true) then
      found_plan_row = true
      break
    end
  end
  assert(found_plan_row, "plan: picker shows the plan id")

  -- Plan view buffer renders without error.
  plan.open(plan_id)
  local view_buf = vim.fn.bufnr("nvime://plan/" .. plan_id)
  assert(view_buf ~= -1, "plan: plan view buffer exists")
  local view_lines = vim.api.nvim_buf_get_lines(view_buf, 0, -1, false)
  local saw_steps_header = false
  for _, line in ipairs(view_lines) do
    if line:find("STEPS", 1, true) then
      saw_steps_header = true
      break
    end
  end
  assert(saw_steps_header, "plan: view renders STEPS header")

  -- Plan view advertises its keys through the shared g? overlay.
  do
    local keyhelp = require("nvime.keyhelp")
    keyhelp.close()
    local g_help
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(view_buf, "n")) do
      if m.lhs == "g?" then
        g_help = m
      end
    end
    assert(g_help and g_help.callback, "plan view binds g? to a help callback")
    g_help.callback()
    assert(keyhelp.is_open(), "plan g? opens the keyhelp overlay")
    local plan_help = table.concat(vim.api.nvim_buf_get_lines(state.panels.keyhelp.bufnr, 0, -1, false), "\n")
    assert(plan_help:find("Phase 0", 1, true), "plan help shows the Phase 0 section")
    assert(plan_help:find("agree to the plan", 1, true), "plan help documents the agree gate")
    assert(plan_help:find("Navigate", 1, true), "plan help shows the Navigate section")
    keyhelp.close()
  end

  -- Critic verdict parsing — robust against markdown emphasis, list
  -- markers, headers, em/en dashes, mixed case, bare verbs.
  local critic = require("nvime.critic")
  local lenient_cases = {
    { "APPROVE: minimal rename, semantics unchanged.", "APPROVE" },
    { "**APPROVE**: minimal rename.", "APPROVE" },
    { "**APPROVE** — minimal rename.", "APPROVE" },
    { "approve: rename ok", "APPROVE" },
    { "Approve - rename ok", "APPROVE" },
    { "## APPROVE: looks fine", "APPROVE" },
    { "- REJECT: bad approach", "REJECT" },
    { "1. REJECT: bad approach", "REJECT" },
    { "`APPROVE`: minimal", "APPROVE" },
    { "REJECT", "REJECT" },
    { "FLAG", "FLAG" },
    { "> APPROVE: looks fine", "APPROVE" },
    { "*APPROVE*: rename only", "APPROVE" },
    { "APPROVE :: minimal change", "APPROVE" },
  }
  for _, c in ipairs(lenient_cases) do
    local v = critic._parse_verdict(c[1])
    assert(v and v.decision == c[2], "critic parser fails on: " .. vim.inspect(c[1]) .. " → got " .. vim.inspect(v))
  end
  assert(critic._parse_verdict("not a verdict") == nil, "critic: garbage returns nil")
  assert(critic._parse_verdict("APPROVED for landing") == nil, "critic: word boundary stops APPROVED")
  assert(critic._parse_verdict("REJECTION is harsh") == nil, "critic: word boundary stops REJECTION")

  -- on_resolved exposes the pre-step snapshot for rollback
  vim.cmd.edit(tmp .. "/rollback_target.lua")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local x = 1", "local y = 2" })
  local rollback_target = vim.api.nvim_get_current_buf()
  local rollback_result = require("nvime.diff").start_session({
    bufnr = rollback_target,
    line1 = 1,
    line2 = 2,
    path = "rollback_target.lua",
    source = "test",
  }, "NVIME_REPLACEMENT\n```lua\nlocal a = 1\nlocal b = 2\n```", "claude", "")
  assert(rollback_result.session, "rollback test: session opened")
  local captured = nil
  rollback_result.session.on_resolved = function(s)
    captured = s
  end
  require("nvime.diff").accept_all()
  assert(captured and captured.original_lines, "rollback test: original_lines exposed in summary")
  assert(captured.original_lines[1] == "local x = 1", "rollback test: snapshot preserved")
  assert(captured.target_bufnr == rollback_target, "rollback test: target_bufnr exposed")
  -- Rollback by restoring (mirrors plan.rollback_step)
  vim.api.nvim_buf_set_lines(rollback_target, 0, -1, false, captured.original_lines)
  local rolled_back = vim.api.nvim_buf_get_lines(rollback_target, 0, -1, false)
  assert(rolled_back[1] == "local x = 1", "rollback test: restored to pre-step")

  -- ── Phased plan flow (phase 0 research → 1 scaffold → 2 implement) ──────────
  do
    local bc_store = require("nvime.bigchange.store")
    local bc_build = require("nvime.bigchange.build")
    local bc_review = require("nvime.bigchange.review")

    -- Migration: a v1 plan loads as phase 0 / v2.
    local pdir = tmp .. "/phased"
    vim.fn.mkdir(pdir .. "/0001-phased", "p")
    local v1 = {
      version = 1,
      id = "0001-phased",
      title = "Phased demo",
      why = "Demonstrate the phased flow.",
      created_at = os.time(),
      updated_at = os.time(),
      files_estimated = { "lua/foo.lua" },
      acceptance = { { id = 1, text = "tests pass", status = "pending" } },
      steps = {
        {
          id = 1,
          intent = "Add helper",
          file = "lua/foo.lua",
          range = { line1 = 1, line2 = 2 },
          depends_on = {},
          tests = {},
          status = "pending",
        },
        {
          id = 2,
          intent = "Wire it up",
          file = "lua/bar.lua",
          range = "new",
          depends_on = { 1 },
          tests = {},
          status = "pending",
        },
      },
    }
    local pfd = io.open(pdir .. "/0001-phased/plan.json", "w")
    pfd:write(vim.json.encode(v1))
    pfd:close()

    state.config.plan.dir = pdir
    state.plan.loaded = false
    state.plan.plans = nil
    local p = plan.get("0001-phased")
    assert(p, "phased: plan loads")
    assert_eq(p.version, 2, "phased: v1 migrates to v2")
    assert_eq(plan._plan_phase(p), 0, "phased: migrated plan starts at phase 0")
    assert(p.phase0_agreed == false, "phased: not yet agreed")

    -- Spec markdown carries title / why / steps / acceptance.
    local spec = plan._plan_spec_markdown(p)
    assert(spec:find("# Phased demo", 1, true), "phased: spec has title")
    assert(spec:find("## Ordered steps", 1, true), "phased: spec has steps")
    assert(spec:find("Add helper", 1, true), "phased: spec lists step intent")
    assert(spec:find("## Acceptance criteria", 1, true), "phased: spec has acceptance")

    -- Scaffold + implement prompts hold their guardrails.
    local sp = plan._scaffold_prompt(p)
    assert(sp:find("TODO(nvime)", 1, true), "phased: scaffold prompt names the TODO marker")
    assert(sp:find("Implement NO behavior", 1, true), "phased: scaffold prompt forbids behavior")
    local ip = plan._implement_prompt(p)
    assert(ip:find("REMOVE the marker", 1, true), "phased: implement prompt removes markers")
    assert(ip:find("authoritative", 1, true), "phased: implement prompt honors user edits")

    -- Stub the Big Change engine so transitions don't spawn an agent or persist.
    local bc_mod = require("nvime.bigchange")
    local fake = { sessions = {}, next = 500, build_starts = {}, review_closed = 0, discarded = {} }
    local saved = {
      create = bc_store.create,
      get = bc_store.get,
      touch = bc_store.touch,
      set_active = bc_store.set_active,
      save_now = bc_store.save_now,
      b_start = bc_build.start,
      b_open = bc_build.open,
      r_open = bc_review.open,
      r_close = bc_review.close,
      discard = bc_mod.discard,
    }
    bc_store.create = function(opts)
      fake.next = fake.next + 1
      local s = {
        id = fake.next,
        title = opts.title,
        difficulty = opts.difficulty,
        provider = opts.provider,
        status = bc_store.STATUS.INTAKE,
        blocks = {},
      }
      fake.sessions[s.id] = s
      return s
    end
    bc_store.get = function(id)
      return fake.sessions[tonumber(id)]
    end
    bc_store.touch = function() end
    bc_store.set_active = function() end
    bc_store.save_now = function() end
    bc_build.start = function(session, o)
      fake.build_starts[#fake.build_starts + 1] = { session = session, opts = o or {} }
    end
    bc_build.open = function() end
    bc_review.open = function() end
    bc_review.close = function()
      fake.review_closed = fake.review_closed + 1
    end
    bc_mod.discard = function(id)
      fake.discarded[#fake.discarded + 1] = id
      fake.sessions[tonumber(id)] = nil
    end

    local ok_pcall, err_pcall = pcall(function()
      -- Phase 0 → 1: agree gate transition.
      plan._enter_scaffold("0001-phased")
      local after1 = plan.get("0001-phased")
      assert_eq(plan._plan_phase(after1), 1, "phased: enter_scaffold flips to phase 1")
      assert(after1.phase0_agreed == true, "phased: phase0_agreed set")
      assert(after1.bigchange_session_id, "phased: linked bigchange session created")
      local sess = plan._linked_session(after1)
      assert(sess and sess.plan_id == "0001-phased", "phased: session links back to plan")
      assert_eq(#fake.build_starts, 1, "phased: scaffold build kicked")
      assert(
        fake.build_starts[1].opts.prompt:find("TODO(nvime)", 1, true),
        "phased: scaffold build uses the scaffold prompt"
      )
      assert_eq(sess.difficulty, "vibe", "phased: phase 1 review is vibe")

      -- Phase 1 → 2: choose "require understanding" = yes → easy.
      plan._enter_implement("0001-phased", true)
      local after2 = plan.get("0001-phased")
      assert_eq(plan._plan_phase(after2), 2, "phased: enter_implement flips to phase 2")
      assert(after2.require_understanding == true, "phased: require_understanding recorded")
      assert(after2.phase1_agreed == true, "phased: phase1_agreed set")
      local sess2 = plan._linked_session(after2)
      assert_eq(sess2.difficulty, "easy", "phased: yes → easy difficulty")
      assert(type(sess2.blocks) == "table" and #sess2.blocks == 0, "phased: phase-2 review starts fresh (empty blocks)")
      assert_eq(fake.review_closed, 1, "phased: phase-1 review tab closed")
      assert_eq(#fake.build_starts, 2, "phased: implement build kicked")
      assert(
        fake.build_starts[2].opts.prompt:find("REMOVE the marker", 1, true),
        "phased: implement build uses the implement prompt"
      )

      -- Finalize after merge records the branch + completion.
      sess2.merged_branch = "plan/0001-phased"
      plan._finalize_plan("0001-phased")
      local done = plan.get("0001-phased")
      assert_eq(done.merged_branch, "plan/0001-phased", "phased: finalize records the branch")
      assert(done.completed_at, "phased: finalize stamps completion")

      -- Deleting a plan refuses while its session is building, then discards the
      -- linked session (worktree + record) so nothing is orphaned.
      local live = plan._linked_session(plan.get("0001-phased"))
      live.busy = true
      assert(plan.delete("0001-phased") == false, "phased: delete refused while build is busy")
      assert(plan.get("0001-phased"), "phased: plan survives a refused delete")
      live.busy = false
      assert(plan.delete("0001-phased"), "phased: delete succeeds when idle")
      assert_eq(#fake.discarded, 1, "phased: delete discards the linked session")
    end)

    -- Restore the real Big Change engine regardless of outcome.
    bc_store.create, bc_store.get, bc_store.touch, bc_store.set_active, bc_store.save_now =
      saved.create, saved.get, saved.touch, saved.set_active, saved.save_now
    bc_build.start, bc_build.open = saved.b_start, saved.b_open
    bc_review.open, bc_review.close = saved.r_open, saved.r_close
    bc_mod.discard = saved.discard
    assert(ok_pcall, "phased: transitions run cleanly: " .. tostring(err_pcall))

    -- Restore the prior plan dir so later assertions in this block still resolve.
    state.config.plan.dir = plans_dir
    state.plan.loaded = false
    state.plan.plans = nil
  end

  -- Review completion-label seam: default merges; a plan hook overrides it, and
  -- the grade prompt carries an optional lane note.
  do
    local bc_review = require("nvime.bigchange.review")
    assert_eq(bc_review._complete_label({}), "merge", "review: default completion verb is merge")
    assert_eq(
      bc_review._complete_label({ review_complete = { label = "advance → implement" } }),
      "advance → implement",
      "review: plan hook overrides the completion verb"
    )
    local gp = bc_review._grade_prompt({ difficulty = "easy", review_prompt_note = "EDIT-NOTE-XYZ" }, {})
    assert(gp:find("EDIT-NOTE-XYZ", 1, true), "review: grade prompt includes the lane note")
  end

  -- ── Update-plan chat: author streaming hooks + keymap wiring ───────────────
  do
    local agents = require("nvime.agents")
    local saved_run = agents.run

    local udir = tmp .. "/update-plans"
    vim.fn.mkdir(udir .. "/0001-upd", "p")
    local ufd = io.open(udir .. "/0001-upd/plan.json", "w")
    ufd:write(vim.json.encode({
      version = 1,
      id = "0001-upd",
      title = "Upd",
      why = "x",
      created_at = os.time(),
      updated_at = os.time(),
      files_estimated = {},
      acceptance = {},
      steps = { { id = 1, intent = "a", file = "a.lua", range = "new", depends_on = {}, tests = {} } },
    }))
    ufd:close()
    state.config.plan.dir = udir
    state.plan.loaded = false
    state.plan.plans = nil

    -- M.create streams to on_stream and calls on_complete (no run float opened).
    agents.run = function(opts)
      vim.schedule(function()
        if opts.on_session_id then
          opts.on_session_id("sess-1")
        end
        if opts.on_text then
          opts.on_text("working on it")
        end
        if opts.on_exit then
          opts.on_exit({ code = 0, nvime_synced_plan_files = { ".nvime/plans/0001-upd/plan.json" } })
        end
      end)
      return { kill = function() end }
    end
    local streamed, completed = {}, nil
    plan.create({
      intent = "rework step 1",
      refine_id = "0001-upd",
      on_stream = function(t)
        streamed[#streamed + 1] = t
      end,
      on_complete = function(pid, status)
        completed = { id = pid, status = status }
      end,
    })
    vim.wait(2000, function()
      return completed ~= nil
    end)
    agents.run = saved_run
    assert(completed, "update: on_complete fired")
    assert_eq(completed.status, "ok", "update: completion status ok")
    assert_eq(completed.id, "0001-upd", "update: completion carries the plan id")
    assert(
      #streamed > 0 and table.concat(streamed):find("working on it", 1, true),
      "update: on_stream received the agent text"
    )

    -- Keymap wiring: phase-0 view binds gu (not gd); update_chat is exported.
    assert(type(plan.update_chat) == "function", "update: update_chat is exported")
    plan.open("0001-upd")
    local vbuf = vim.fn.bufnr("nvime://plan/0001-upd")
    local maps = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(vbuf, "n")) do
      maps[m.lhs] = true
    end
    assert(maps["gu"], "update: phase-0 view binds gu")
    assert(not maps["gd"], "update: phase-0 view no longer binds gd")

    -- The chat is a 2-window layout (plan + single chat pane), and an unsent
    -- draft survives close/reopen (no more lost text on q).
    -- The chat pane is the UNNAMED scratch buffer (the plan pane is a named
    -- nvime://plan/<id> buffer whose footer also mentions "update plan").
    local function chat_buf_of_tab()
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local b = vim.api.nvim_win_get_buf(w)
        if
          vim.api.nvim_buf_get_name(b) == ""
          and table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("update plan", 1, true)
        then
          return b
        end
      end
    end
    plan.update_chat("0001-upd")
    assert_eq(#vim.api.nvim_tabpage_list_wins(0), 2, "update: chat is a 2-window layout")
    local cbuf = chat_buf_of_tab()
    assert(cbuf, "update: chat buffer present")
    vim.bo[cbuf].modifiable = true
    vim.api.nvim_buf_set_lines(cbuf, -1, -1, false, { "my unsent draft" })
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(cbuf, "n")) do
      if m.lhs == "q" and m.callback then
        m.callback()
      end
    end
    plan.update_chat("0001-upd")
    local cbuf2 = chat_buf_of_tab()
    local ctext = table.concat(vim.api.nvim_buf_get_lines(cbuf2, 0, -1, false), "\n")
    assert(ctext:find("my unsent draft", 1, true), "update: unsent draft restored on reopen")
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(cbuf2, "n")) do
      if m.lhs == "q" and m.callback then
        m.callback()
      end
    end

    state.config.plan.dir = plans_dir
    state.plan.loaded = false
    state.plan.plans = nil
  end

  -- ── Plan author stale-session self-recovery ───────────────────────────────
  -- A resumed author session the provider has forgotten ("No conversation
  -- found") must clear the bad id and retry once from a fresh conversation.
  do
    local agents = require("nvime.agents")
    local saved_run = agents.run
    local rdir = tmp .. "/recover-plans"
    vim.fn.mkdir(rdir .. "/0001-rec", "p")
    local rfd = io.open(rdir .. "/0001-rec/plan.json", "w")
    rfd:write(vim.json.encode({
      version = 1,
      id = "0001-rec",
      title = "Rec",
      why = "x",
      created_at = os.time(),
      updated_at = os.time(),
      files_estimated = {},
      acceptance = {},
      author_provider_sessions = { claude = "stale-id" },
      steps = { { id = 1, intent = "a", file = "a.lua", range = "new", depends_on = {}, tests = {} } },
    }))
    rfd:close()
    state.config.plan.dir = rdir
    state.plan.loaded = false
    state.plan.plans = nil

    local calls = {}
    agents.run = function(opts)
      -- Record the resume id ("<fresh>" when none — Lua tables can't store nil).
      calls[#calls + 1] = opts.resume_session_id or "<fresh>"
      vim.schedule(function()
        if opts.resume_session_id then
          -- resume fails: the provider forgot the session.
          if opts.on_text then
            opts.on_text("No conversation found with session ID: stale-id\n")
          end
          if opts.on_exit then
            opts.on_exit({ code = 1, nvime_synced_plan_files = {} })
          end
        else
          -- a fresh run succeeds and captures a new session id.
          if opts.on_session_id then
            opts.on_session_id("fresh-id")
          end
          if opts.on_exit then
            opts.on_exit({ code = 0, nvime_synced_plan_files = { ".nvime/plans/0001-rec/plan.json" } })
          end
        end
      end)
      return { kill = function() end }
    end

    local completed
    plan.create({
      intent = "tweak step 1",
      refine_id = "0001-rec",
      provider = "claude",
      on_stream = function() end, -- suppress the run-log float (chat-style)
      on_complete = function(pid, status)
        completed = { id = pid, status = status }
      end,
    })
    vim.wait(3000, function()
      return completed ~= nil
    end)
    agents.run = saved_run
    state.plan.active_run = nil -- don't leak the author-run state into later tests

    assert(completed, "recover: on_complete fired after the retry")
    assert_eq(completed.status, "ok", "recover: the fresh retry succeeded")
    assert_eq(#calls, 2, "recover: retried exactly once (resume fail → fresh)")
    assert_eq(calls[1], "stale-id", "recover: first attempt resumed the stale id")
    assert_eq(calls[2], "<fresh>", "recover: the retry ran without resuming")
    state.plan.loaded = false
    state.plan.plans = nil
    local rp = plan.get("0001-rec")
    assert_eq(rp.author_provider_sessions.claude, "fresh-id", "recover: stale id replaced by the fresh one")

    state.config.plan.dir = plans_dir
    state.plan.loaded = false
    state.plan.plans = nil
  end

  -- Render must survive multi-line fields in plan.json (intent/notes/why/
  -- acceptance/title may all contain embedded newlines from JSON-encoded
  -- agent output; nvim_buf_set_lines rejects items with embedded \n).
  do
    local nl_dir = tmp .. "/nl-plans"
    vim.fn.mkdir(nl_dir .. "/0099-nl/", "p")
    local nl_data = {
      version = 1,
      id = "0099-nl",
      title = "Title\nwith newline",
      why = "Multi-line\nwhy",
      created_at = os.time(),
      updated_at = os.time(),
      files_estimated = {},
      acceptance = { { id = 1, text = "Multi-line\nacceptance", status = "pending" } },
      steps = {
        {
          id = 1,
          intent = "Step intent\nwith newlines",
          file = "foo.lua",
          range = { line1 = 1, line2 = 3 },
          notes = "Step notes\nalso multi-line",
          depends_on = {},
          tests = {},
          status = "pending",
        },
      },
    }
    local nl_fd = io.open(nl_dir .. "/0099-nl/plan.json", "w")
    nl_fd:write(vim.json.encode(nl_data))
    nl_fd:close()
    state.config.plan.dir = nl_dir
    state.plan.loaded = false
    state.plan.plans = nil
    local ok_view = pcall(plan.open, "0099-nl")
    assert(ok_view, "plan.open survives multi-line fields")
    local ok_picker = pcall(plan.picker)
    assert(ok_picker, "plan.picker survives multi-line plan.title")
    -- Restore previous dir for downstream tests
    state.config.plan.dir = plans_dir
    state.plan.loaded = false
    state.plan.plans = nil
  end

  -- test runner auto-detection (cargo / zig / go / py / npm / etc.)
  assert(type(plan.detect_test_runner) == "function", "plan: detect_test_runner is exported")
  -- Without project markers and with the default scripts/test in this repo,
  -- the runner falls back to ./scripts/test:
  do
    local runner = plan.detect_test_runner()
    assert(runner == "./scripts/test", "in this repo, runner detects ./scripts/test, got: " .. tostring(runner))
  end

  -- Per-plan session continuity helpers exist and persist correctly
  assert(type(plan.reset_session) == "function", "plan: reset_session is exported")
  vim.fn.mkdir(plans_dir .. "/0002-continuity", "p")
  local cont_path = plans_dir .. "/0002-continuity/plan.json"
  local cont_fd = io.open(cont_path, "w")
  cont_fd:write(vim.json.encode({
    version = 1,
    id = "0002-continuity",
    title = "Continuity",
    why = "test",
    created_at = os.time(),
    updated_at = os.time(),
    files_estimated = {},
    acceptance = {},
    provider_sessions = { claude = "session-from-disk" },
    steps = {},
  }))
  cont_fd:close()
  state.plan.loaded = false
  state.plan.plans = nil
  local cont_plan = plan.get("0002-continuity")
  assert(
    cont_plan.provider_sessions and cont_plan.provider_sessions.claude == "session-from-disk",
    "plan loads provider_sessions from disk"
  )
  assert(plan.reset_session("0002-continuity", "claude"), "reset_session ok")
  state.plan.loaded = false
  state.plan.plans = nil
  cont_plan = plan.get("0002-continuity")
  assert(
    not (cont_plan.provider_sessions and cont_plan.provider_sessions.claude),
    "reset_session cleared the captured id"
  )
  plan.delete("0002-continuity")

  -- Public escape hatches exist for the user when a backdrop sticks.
  assert(type(plan.close_all) == "function", "plan: close_all is exported")
  assert(type(plan.focus) == "function", "plan: focus is exported")
  assert(vim.fn.exists(":NvimePlanClose") == 2, "NvimePlanClose command exists")
  assert(vim.fn.exists(":NvimePlanFocus") == 2, "NvimePlanFocus command exists")
  -- close_all is safe to call when nothing is open.
  plan.close_all()
  -- focus() returns false when there's no float to focus on.
  assert(plan.focus() == false, "plan.focus returns false when nothing is open")

  -- Compose buffer is persistent: open, edit, close, reopen, draft survives.
  plan.compose({})
  local compose_buf = vim.fn.bufnr("nvime://plan/compose")
  assert(compose_buf ~= -1, "plan: compose buffer exists")
  -- Inject a multi-line draft to verify that the title/intent extraction works
  -- and that submission with a multi-line intent does not crash plan.create
  -- (regresses the nvim_buf_set_lines newline bug seen by the live user).
  vim.api.nvim_buf_set_lines(compose_buf, 0, -1, false, {
    "# Title",
    "",
    "Smoke test plan from headless",
    "",
    "# Intent",
    "",
    "Line one of the intent.",
    "Line two of the intent.",
    "",
    "# Notes",
    "",
    "Quick note.",
  })

  -- Stub out agents.run so we don't actually spawn a provider in the test;
  -- we only want to confirm M.create accepts multi-line intents without
  -- raising the 'replacement string item contains newlines' error.
  local agents_mod = require("nvime.agents")
  local original_run = agents_mod.run
  local captured_intent = nil
  agents_mod.run = function(opts)
    captured_intent = opts.prompt
    return { kill = function() end }
  end
  local extract = nil
  -- Manually invoke the compose-extract logic by simulating the <C-s> path.
  -- We can't trigger keymaps headlessly without focus, so call M.create
  -- directly with an intent containing newlines.
  local multi_intent = "Plan title: Smoke test plan from headless\n\nLine one of the intent.\nLine two of the intent."
  local ok = pcall(plan.create, { intent = multi_intent })
  agents_mod.run = original_run
  assert(ok, "plan.create accepts multi-line intent without crashing")
  assert(captured_intent and captured_intent:find("Smoke test plan", 1, true), "plan author prompt contains the intent")

  -- Delete cleans up.
  assert(plan.delete(plan_id), "plan: delete returns true")
  state.plan.loaded = false
  state.plan.plans = nil
  assert_eq(#plan.plans(), 0, "plan: delete removes plan from disk")
end)();

-- Attribution ledger: every accepted diff block records a rationale +
-- critic + plan linkage anchored to the accepted text content.
(function()
  local attribution = require("nvime.attribution")
  -- Use a temp ledger for this test so we don't pollute the real
  -- .nvime/attribution.json in the dev tree.
  local ledger_path = tmp .. "/attribution.json"
  require("nvime.state").config.attribution = { enabled = true, path = ledger_path, max = 500 }

  local target = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(target, tmp .. "/attribution_target.lua")
  vim.api.nvim_buf_set_lines(target, 0, -1, false, {
    "local function greet()",
    "  return 'hello'",
    "end",
  })
  -- Write the buffer so repo_relative_path can resolve.
  vim.fn.writefile(vim.api.nvim_buf_get_lines(target, 0, -1, false), tmp .. "/attribution_target.lua")

  local diff = require("nvime.diff")
  local response = table.concat({
    "RATIONALE: bug: greeting is too quiet; patch: shout it; why: matches caller expectation.",
    "NVIME_DIFF",
    "```diff",
    "--- a/" .. tmp .. "/attribution_target.lua",
    "+++ b/" .. tmp .. "/attribution_target.lua",
    "@@ -2,1 +2,1 @@",
    "-  return 'hello'",
    "+  return 'HELLO'",
    "```",
  }, "\n")
  local result = diff.start_session({
    bufnr = target,
    line1 = 2,
    line2 = 2,
    path = tmp .. "/attribution_target.lua",
    source = "test",
  }, response, "claude", "")
  assert(result and result.session, "attribution test: diff session opened")
  -- Tag the session with plan linkage to confirm plumbing.
  result.session.plan_id = "0001-test-plan"
  result.session.plan_step_id = 7
  -- Accept the only block.
  diff.accept_all()
  local applied = vim.api.nvim_buf_get_lines(target, 0, -1, false)
  assert_eq(applied[2], "  return 'HELLO'", "attribution test: block applied to buffer")

  local ledger_raw = vim.fn.readfile(ledger_path)
  assert(#ledger_raw > 0, "attribution: ledger file written")
  local ledger = vim.json.decode(table.concat(ledger_raw, "\n"))
  assert_eq(ledger.version, 1, "attribution: ledger version is 1")
  assert(ledger.entries and #ledger.entries == 1, "attribution: one entry recorded")
  local entry = ledger.entries[1]
  assert_eq(entry.plan_id, "0001-test-plan", "attribution: plan id forwarded")
  assert_eq(entry.step_id, 7, "attribution: step id forwarded")
  assert_eq(entry.provider, "claude", "attribution: provider recorded")
  assert(
    entry.rationale and entry.rationale:find("greeting is too quiet", 1, true),
    "attribution: rationale captured from RATIONALE: line"
  )
  assert(
    entry.anchor and entry.anchor.head and entry.anchor.head[1] == "  return 'HELLO'",
    "attribution: anchor head matches accepted text"
  )

  -- Lookup: a query at the accepted line should return the entry.
  local matches =
    attribution.for_line(tmp .. "/attribution_target.lua", 2, vim.api.nvim_buf_get_lines(target, 0, -1, false))
  assert(#matches >= 1, "attribution: lookup finds the entry by anchor")
  assert_eq(matches[1].plan_id, "0001-test-plan", "attribution: lookup result carries plan_id")

  -- Anchor survives a benign edit elsewhere in the file: insert a line
  -- above and confirm we still match.
  vim.api.nvim_buf_set_lines(target, 0, 0, false, { "-- newer comment" })
  local shifted = vim.api.nvim_buf_get_lines(target, 0, -1, false)
  local shifted_matches = attribution.for_line(tmp .. "/attribution_target.lua", 3, shifted)
  assert(#shifted_matches >= 1, "attribution: anchor survives line shift")
  assert_eq(shifted_matches[1].match_line1, 3, "attribution: anchor reports new line position")

  -- Cap test: write 502 entries, expect the trim to keep only the most recent 500.
  vim.fn.delete(ledger_path)
  for i = 1, 502 do
    attribution.record({
      file = "tests/fixture_" .. i .. ".lua",
      line1 = 1,
      line2 = 1,
      lines = { "line " .. i },
      rationale = "r" .. i,
      provider = "claude",
    })
  end
  local capped = vim.json.decode(table.concat(vim.fn.readfile(ledger_path), "\n"))
  assert(#capped.entries <= 500, "attribution: ledger trims to max")
  assert(capped.entries[#capped.entries].file == "tests/fixture_502.lua", "attribution: newest entry survives")
  assert(capped.entries[1].file ~= "tests/fixture_1.lua", "attribution: oldest entry trimmed")

  vim.fn.delete(ledger_path)
  require("nvime.state").config.attribution = { enabled = true, path = nil, max = 500 }
end)()

-- :NvimeAttribute command surface
assert(vim.fn.exists(":NvimeAttribute") == 2, "NvimeAttribute command exists");

-- Audit summarizer (#2): walk a synthetic audit log, check stats and the
-- risky-event subset.
(function()
  local digest = require("nvime.digest")
  local synthetic = tmp .. "/digest_audit.jsonl"
  local function write_event(t)
    local fd = assert(io.open(synthetic, "a"))
    fd:write(vim.json.encode(t))
    fd:write("\n")
    fd:close()
  end
  vim.fn.delete(synthetic)
  local now = os.time()
  local recent_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", now)
  local stale_iso = os.date("!%Y-%m-%dT%H:%M:%SZ", now - 14 * 86400)
  write_event({ event = "agent_start", lane = "edit", provider = "claude", ts = recent_iso })
  write_event({ event = "agent_exit", lane = "edit", provider = "claude", ts = recent_iso })
  write_event({ event = "agent_start", lane = "plan", provider = "codex", ts = recent_iso })
  write_event({
    event = "block_force_applied",
    file = "lua/nvime/diff.lua",
    block_id = 7,
    start_line = 100,
    end_line = 120,
    ts = recent_iso,
  })
  write_event({
    event = "block_conflict",
    file = "lua/nvime/diff.lua",
    block_id = 8,
    start_line = 200,
    end_line = 210,
    ts = recent_iso,
  })
  write_event({
    event = "plan_step_rollback",
    plan_id = "0001-test",
    step_id = 3,
    file = "lua/nvime/plan.lua",
    ts = recent_iso,
  })
  write_event({ event = "diff_resolved", accepted = 2, total = 3, provider = "claude", ts = recent_iso })
  write_event({ event = "diff_resolved", accepted = 0, total = 1, provider = "codex", ts = recent_iso })
  -- Old event, outside the 7-day window.
  write_event({ event = "agent_start", lane = "edit", provider = "claude", ts = stale_iso })

  local events = digest.read_events({ path = synthetic, window_days = 7 })
  assert(#events == 8, "digest: 7-day window excludes stale event (got " .. #events .. ")")
  local all_events = digest.read_events({ path = synthetic })
  assert(#all_events == 9, "digest: no window returns all events (got " .. #all_events .. ")")

  local stats = digest.summarize(events)
  assert_eq(stats.total, 8, "digest: total events")
  -- by_lane counts every event tagged with a lane (start + exit etc.).
  assert_eq(stats.by_lane.edit, 2, "digest: edit-lane events (start + exit)")
  assert_eq(stats.by_lane.plan, 1, "digest: plan-lane events")
  -- sessions counts agent_start only, so it represents distinct sessions.
  assert_eq(stats.sessions.edit, 1, "digest: edit sessions started")
  assert_eq(stats.sessions.plan, 1, "digest: plan sessions started")
  assert_eq(stats.by_provider.claude, 3, "digest: claude provider events")
  assert_eq(stats.by_provider.codex, 2, "digest: codex provider events")
  assert(#stats.risky == 3, "digest: risky events bucketed (force/conflict/rollback)")
  assert_eq(stats.plans["0001-test"], 1, "digest: plan id surfaced")
  assert_eq(stats.acceptance.resolutions, 2, "digest: diff_resolved count")
  assert_eq(stats.acceptance.accepted, 2, "digest: accepted blocks summed")
  assert_eq(stats.acceptance.total, 4, "digest: total blocks summed")
  assert_eq(stats.acceptance.by_provider.claude.accepted, 2, "digest: claude accepted")
  assert_eq(stats.acceptance.by_provider.claude.total, 3, "digest: claude total")
  assert_eq(stats.acceptance.by_provider.codex.accepted, 0, "digest: codex accepted")
  assert_eq(stats.acceptance.by_provider.codex.total, 1, "digest: codex total")

  local forces = digest.force_review(events)
  assert(#forces == 1, "digest: exactly one force_applied")
  assert_eq(forces[1].file, "lua/nvime/diff.lua", "digest: force_review carries file")
end)()

-- :NvimeAudit subcommands
assert(vim.fn.exists(":NvimeAudit") == 2, "NvimeAudit command exists");

-- Plan.md as living changelog (#7): set_step_status to "done" appends a
-- new section to plan.md including the rationale + critic verdict + tests.
(function()
  local plan = require("nvime.plan")
  local plan_dir = tmp .. "/changelog_plans"
  vim.fn.mkdir(plan_dir, "p")
  require("nvime.state").config.plan = require("nvime.state").config.plan or {}
  require("nvime.state").config.plan.dir = plan_dir
  require("nvime.state").plan = require("nvime.state").plan or {}
  require("nvime.state").plan.loaded = false
  require("nvime.state").plan.plans = nil

  local plan_id = "0099-changelog"
  local plan_path = plan_dir .. "/" .. plan_id
  vim.fn.mkdir(plan_path, "p")
  local plan_obj = {
    version = 1,
    id = plan_id,
    title = "Changelog test plan",
    why = "exercise the plan.md execution log",
    created_at = os.time(),
    updated_at = os.time(),
    files_estimated = { "lua/nvime/plan.lua" },
    acceptance = {},
    steps = {
      {
        id = 1,
        intent = "do the thing",
        file = "lua/nvime/plan.lua",
        range = { line1 = 1, line2 = 5 },
        depends_on = {},
        tests = {},
        status = "pending",
      },
      {
        id = 2,
        intent = "do the second thing",
        file = "lua/nvime/plan.lua",
        range = "new",
        depends_on = {},
        tests = {},
        status = "pending",
      },
    },
  }
  vim.fn.writefile({ vim.json.encode(plan_obj) }, plan_path .. "/plan.json")
  vim.fn.writefile({ "# Changelog test plan", "", "Original plan.md body." }, plan_path .. "/plan.md")
  require("nvime.state").plan.loaded = false

  -- Manual gx-style transition records a minimal entry.
  assert(plan.set_step_status(plan_id, 1, "done"), "changelog: step 1 marked done")
  local md_after_first = table.concat(vim.fn.readfile(plan_path .. "/plan.md"), "\n")
  assert(md_after_first:find("nvime execution log", 1, true), "changelog: log header initialized")
  assert(md_after_first:find("### Step 1 executed @", 1, true), "changelog: step 1 entry written")
  assert(md_after_first:find("manual `gx` mark%-done"), "changelog: manual transition flagged")

  -- Rich-context transition (post-execute) carries rationale + critic + tests.
  assert(
    plan.set_step_status(plan_id, 2, "done", {
      provider = "claude",
      rationale = "bug: thing missing; patch: add thing; why: makes it correct.",
      verdict = { decision = "APPROVE", justification = "minimal addition" },
      accepted = 3,
      total = 3,
      forced = 1,
      tests_cmd = "./scripts/test",
      tests_pass = true,
      tests_tail = "All 42 tests passed",
    }),
    "changelog: step 2 marked done with rich context"
  )
  local md_after_second = table.concat(vim.fn.readfile(plan_path .. "/plan.md"), "\n")
  assert(md_after_second:find("### Step 2 executed @", 1, true), "changelog: step 2 entry written")
  assert(md_after_second:find("Rationale: bug: thing missing", 1, true), "changelog: rationale captured")
  assert(md_after_second:find("Critic: %*%*APPROVE%*%*"), "changelog: critic verdict captured")
  assert(md_after_second:find("Force%-accepts: %*%*1%*%*"), "changelog: force-accept count flagged")
  assert(md_after_second:find("./scripts/test", 1, true), "changelog: tests command captured")
  assert(md_after_second:find("All 42 tests passed", 1, true), "changelog: tests output tail captured")

  -- Re-flipping done should not double-write because prior_status check
  -- guards on transition.
  local before = md_after_second
  plan.set_step_status(plan_id, 2, "done", { provider = "claude" })
  local md_after_third = table.concat(vim.fn.readfile(plan_path .. "/plan.md"), "\n")
  assert_eq(md_after_third, before, "changelog: redundant done→done writes nothing")

  -- Restore plan dir to default and clear cache so other tests don't see it.
  require("nvime.state").config.plan.dir = nil
  require("nvime.state").plan.loaded = false
  require("nvime.state").plan.plans = nil
end)();

-- Markdown renderer: heading levels, inline code, bold/italic, links,
-- numbered lists, blockquote gutter. Confirms the structure-aware spans
-- get the right highlight groups without modifying buffer text.
(function()
  local render = require("nvime.render")

  local function find_span(line, hl)
    for _, s in ipairs(render.inline_spans(line)) do
      if s[3] == hl then
        return s
      end
    end
    return nil
  end

  local function span_text(line, span)
    return line:sub(span[1], span[2])
  end

  local strong_line = "a **bold** word"
  local strong = find_span(strong_line, "NvimeMarkdownStrong")
  assert(strong, "renderer: bold span detected")
  assert_eq(span_text(strong_line, strong), "**bold**", "renderer: bold span covers the whole **...**")

  local em_line = "an *italic* word"
  local em = find_span(em_line, "NvimeMarkdownEmphasis")
  assert(em, "renderer: italic span detected")
  assert_eq(span_text(em_line, em), "*italic*", "renderer: italic span covers *...*")

  local conflict_spans = render.inline_spans("**super** strong")
  local saw_bold = false
  for _, s in ipairs(conflict_spans) do
    if s[3] == "NvimeMarkdownStrong" then
      saw_bold = true
    end
    assert(s[3] ~= "NvimeMarkdownEmphasis", "renderer: bold takes priority over italic when nested")
  end
  assert(saw_bold, "renderer: bold detected in **super**")

  local stray = render.inline_spans("you wrote *foo bar")
  for _, s in ipairs(stray) do
    assert(s[3] ~= "NvimeMarkdownEmphasis", "renderer: unbalanced * is not italic")
  end

  local code_line = "call `foo()` here"
  local code = find_span(code_line, "NvimeMarkdownInlineCode")
  assert(code, "renderer: inline code detected")
  assert_eq(span_text(code_line, code), "`foo()`", "renderer: inline code covers the backtick span")

  assert(find_span("this ~~old~~ way", "NvimeMarkdownStrike"), "renderer: strikethrough detected")
  assert(find_span("see [docs](https://x)", "NvimeMarkdownLinkText"), "renderer: link text styled")
  assert(find_span("see [docs](https://x)", "NvimeMarkdownLinkUrl"), "renderer: link url styled")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "nvime"
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "# Top-level title",
    "## Subsection",
    "### Tertiary",
    "#### Quaternary",
    "",
    "Body with **strong** and *em* and `code` and ~~old~~ and [docs](https://x).",
    "",
    "1. first numbered",
    "2. second numbered",
    "- bullet alpha",
    "* bullet beta",
    "",
    "> quoted line one",
    "> quoted line two",
    "",
    "```lua",
    "local x = 1",
    "```",
  })
  local ns = vim.api.nvim_create_namespace("nvime.test.render")
  render.scrollback(buf, ns)
  local marks = vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
  local seen = {}
  for _, m in ipairs(marks) do
    local hl = m[4] and m[4].hl_group
    if hl then
      seen[hl] = (seen[hl] or 0) + 1
    end
    if m[4] and m[4].virt_text then
      for _, chunk in ipairs(m[4].virt_text) do
        if chunk[2] and chunk[2] ~= "" then
          seen[chunk[2]] = (seen[chunk[2]] or 0) + 1
        end
      end
    end
  end
  for _, group in ipairs({
    "NvimeMarkdownH1",
    "NvimeMarkdownH2",
    "NvimeMarkdownH3",
    "NvimeMarkdownH4",
    "NvimeMarkdownHeadingMarker",
    "NvimeMarkdownStrong",
    "NvimeMarkdownEmphasis",
    "NvimeMarkdownInlineCode",
    "NvimeMarkdownStrike",
    "NvimeMarkdownLinkText",
    "NvimeMarkdownLinkUrl",
    "NvimeBullet",
    "NvimeBulletNumber",
    "NvimeQuote",
    "NvimeQuoteGutter",
    "NvimeCodeFence",
    "NvimeCode",
  }) do
    assert(seen[group], "renderer: missing highlight group " .. group)
  end
end)();

-- Decorative virt_lines above headings: H1/H2 get a thin rule, H3 gets a
-- blank line, but ONLY when the previous buffer line is non-empty (so we
-- don't double the spacing) and we're not at the top of the buffer.
-- Levels 4+ never get a virt_line (already muted-italic, doesn't need it).
-- Crucially, the buffer text is unchanged — every `#` stays visible, so
-- copy/paste returns exactly what the agent wrote.
(function()
  local render = require("nvime.render")
  local buf = vim.api.nvim_create_buf(false, true)
  local body = {
    "intro line",
    "## After prose H2", -- row 1: prev row 0 = "intro line" → ABOVE rule
    "more prose",
    "### After prose H3", -- row 3: prev row 2 = "more prose" → ABOVE blank
    "",
    "### After blank H3", -- row 5: prev row 4 = blank → NO virt_line
    "body",
    "#### Level four", -- row 7: level > 3 → NO virt_line
    "# Top-level when not at top", -- row 8: prev row 7 has prose → ABOVE rule
  }
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body)
  local ns = vim.api.nvim_create_namespace("nvime.test.virt")
  render.scrollback(buf, ns)

  -- Snapshot buffer text — must NOT have changed.
  local after = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  for i, original in ipairs(body) do
    assert_eq(after[i], original, "virt_lines: buffer text unchanged at row " .. i)
  end

  local function virt_at(row)
    local marks = vim.api.nvim_buf_get_extmarks(buf, ns, { row, 0 }, { row, -1 }, { details = true })
    for _, m in ipairs(marks) do
      if m[4] and m[4].virt_lines and m[4].virt_lines_above then
        local first_chunk = m[4].virt_lines[1] and m[4].virt_lines[1][1]
        return first_chunk and first_chunk[1] or ""
      end
    end
    return nil
  end

  assert(virt_at(1) and virt_at(1):find("─", 1, true), "virt_lines: H2-after-prose has rule above")
  local h3 = virt_at(3)
  assert(h3 ~= nil and h3 == "", "virt_lines: H3-after-prose has blank above")
  assert(virt_at(5) == nil, "virt_lines: H3-after-blank has nothing above (would double space)")
  assert(virt_at(7) == nil, "virt_lines: level-4 heading never gets virt_line")
  assert(virt_at(8) and virt_at(8):find("─", 1, true), "virt_lines: H1-after-prose has rule above")
end)();

-- :NvimeRecap (#10): prompt building, hash stability, command parsing.
(function()
  local recap = require("nvime.recap")
  assert(vim.fn.exists(":NvimeRecap") == 2, "NvimeRecap command exists")

  local diff_a = "--- a/foo.lua\n+++ b/foo.lua\n@@ -1,1 +1,1 @@\n-old\n+new\n"
  local diff_b = "--- a/bar.lua\n+++ b/bar.lua\n@@ -1,1 +1,1 @@\n-x\n+y\n"

  local id_a1 = recap._ensure_recap_id(diff_a)
  local id_a2 = recap._ensure_recap_id(diff_a)
  local id_b = recap._ensure_recap_id(diff_b)
  assert(id_a1:find("^recap%-"), "recap: id has recap- prefix")
  assert_eq(id_a1, id_a2, "recap: same diff yields same id")
  assert(id_a1 ~= id_b, "recap: different diff yields different id")

  local prompt = recap._build_recap_prompt(diff_a, "working tree", id_a1)
  assert(prompt:find("NVIME RECAP MODE", 1, true), "recap: prompt has mode header")
  assert(prompt:find("MUST NOT modify any source code", 1, true), "recap: prompt forbids source edits")
  assert(prompt:find(id_a1, 1, true), "recap: prompt embeds recap id")
  assert(
    prompt:find("`.nvime/plans/" .. id_a1 .. "/plan.md`", 1, true),
    "recap: prompt cites the only writable plan.md"
  )
  assert(prompt:find("NVIME_PLAN", 1, true), "recap: prompt requires the NVIME_PLAN marker")
  assert(prompt:find("```diff\n", 1, true), "recap: prompt fences the diff body")

  -- Empty-diff bailout: stub the diff computation (so we don't depend on
  -- real git state) and the agents.run entry point (so this test never
  -- spawns a real provider).
  local agents_mod = require("nvime.agents")
  local original_run = agents_mod.run
  local agent_called = false
  agents_mod.run = function()
    agent_called = true
    return { kill = function() end }
  end
  local original_compute = recap._compute_diff
  recap._compute_diff = function()
    return "", { "git", "diff" }
  end
  recap.start({})
  assert(not agent_called, "recap: empty diff does not spawn the agent")

  -- Non-empty diff path: confirm recap.start delegates to agents.run with
  -- lane="plan" and a prompt containing the recap id.
  recap._compute_diff = function()
    return diff_a, { "git", "diff" }
  end
  local captured_lane, captured_prompt
  agents_mod.run = function(o)
    agent_called = true
    captured_lane = o.lane
    captured_prompt = o.prompt
    return { kill = function() end }
  end
  recap.start({})
  assert(agent_called, "recap: non-empty diff invokes the agent")
  assert_eq(captured_lane, "plan", "recap: invokes the plan lane (workspace + sync filter)")
  assert(
    captured_prompt and captured_prompt:find("NVIME RECAP MODE", 1, true),
    "recap: prompt is the recap-mode header"
  )

  recap._compute_diff = original_compute
  agents_mod.run = original_run
end)();

-- PROTOCOL drift guard: PROTOCOL.md is the public contract; the live prompt
-- builders in edit.lua / plan.lua / critic.lua MUST keep the load-bearing
-- sentences verbatim. If any of these strings vanishes from a source file
-- without PROTOCOL.md being updated in the same commit, this test fails.
(function()
  local function read_file(path)
    local fd = io.open(path, "r")
    if not fd then
      error("cannot open " .. path)
    end
    local body = fd:read("*a")
    fd:close()
    return body
  end
  local edit_src = read_file(root .. "/lua/nvime/edit.lua")
  local plan_src = read_file(root .. "/lua/nvime/plan.lua")
  local chat_src = read_file(root .. "/lua/nvime/chat.lua")
  local critic_src = read_file(root .. "/lua/nvime/critic.lua")
  local protocol_md = read_file(root .. "/PROTOCOL.md")

  local function require_in(haystack, needle, where)
    if not haystack:find(needle, 1, true) then
      error("PROTOCOL drift: missing in " .. where .. ": " .. needle)
    end
  end

  -- Edit lane invariants
  require_in(edit_src, "You are a constrained patch worker, not a reviewer.", "edit.lua")
  require_in(edit_src, "Return exactly one machine-readable response block.", "edit.lua")
  require_in(edit_src, "You may only propose changes for the selected range in the current file.", "edit.lua")
  require_in(edit_src, "Do not edit files directly.", "edit.lua")
  require_in(edit_src, "Prefer NVIME_DIFF for any change to existing nonblank text.", "edit.lua")
  require_in(edit_src, "If nvime MCP tools are available", "edit.lua")
  require_in(edit_src, "Do not narrate tool use", "edit.lua")
  require_in(edit_src, "verification pass", "edit.lua")
  require_in(edit_src, "consume/validate the full input", "edit.lua")
  require_in(edit_src, "Precomputed nvime project context", "edit.lua")
  require_in(edit_src, "Detected test runner", "edit.lua")

  -- Perf lane invariants
  require_in(edit_src, "If you cannot prove a real win with numbers, return NVIME_NO_CHANGE.", "edit.lua")
  require_in(edit_src, "Use Bash to create a scratch directory under /tmp", "edit.lua")
  require_in(edit_src, "NEVER write inside the user's repository.", "edit.lua")

  -- Plan author invariants
  require_in(plan_src, "You are an architect drafting a structured implementation plan", "plan.lua")
  require_in(plan_src, "Do not narrate tool use, investigation progress", "plan.lua")
  require_in(plan_src, "You MUST NOT modify any source code", "plan.lua")
  require_in(plan_src, "ONLY for paths under `.nvime/plans/<plan-id>/`.", "plan.lua")
  require_in(plan_src, "Decompose into ORDERED steps", "plan.lua")
  require_in(plan_src, "Match the NUMBER of steps to the ACTUAL scope", "plan.lua")

  -- General chat invariants
  require_in(chat_src, "Never edit non-Markdown files from this lane", "chat.lua")
  require_in(chat_src, "Do not narrate tool use or progress", "chat.lua")

  -- Critic invariants
  require_in(critic_src, "You are a critical reviewer of a proposed patch", "critic.lua")
  require_in(critic_src, "you cannot edit anything", "critic.lua")
  require_in(critic_src, "APPROVE", "critic.lua")
  require_in(critic_src, "FLAG", "critic.lua")
  require_in(critic_src, "REJECT", "critic.lua")
  require_in(critic_src, "prefer FLAG over REJECT unless the patch is unambiguously wrong", "critic.lua")

  -- And the inverse: PROTOCOL.md must keep referring to the markers it
  -- documents, so a doc rewrite that drops them surfaces here too.
  require_in(protocol_md, "NVIME_NO_CHANGE", "PROTOCOL.md")
  require_in(protocol_md, "NVIME_REPLACEMENT", "PROTOCOL.md")
  require_in(protocol_md, "Precomputed nvime project context", "PROTOCOL.md")
  require_in(protocol_md, "Do not narrate tool use, investigation progress", "PROTOCOL.md")
  require_in(protocol_md, "Match the number of steps to the actual scope", "PROTOCOL.md")
  require_in(protocol_md, "NVIME_DIFF", "PROTOCOL.md")
  require_in(protocol_md, "NVIME_PLAN", "PROTOCOL.md")
  require_in(protocol_md, "RATIONALE:", "PROTOCOL.md")
end)();

-- Plan view inline-span decoration: opening a plan with backticked
-- intent / notes runs the prose through render.inline_spans so the
-- buffer picks up the same NvimeMarkdownInlineCode highlights as
-- agent scrollback. Without changing buffer text — every backtick
-- must remain visible in the buffer.
(function()
  local plan = require("nvime.plan")
  local plan_dir = tmp .. "/inline_plans"
  vim.fn.mkdir(plan_dir, "p")
  require("nvime.state").config.plan = require("nvime.state").config.plan or {}
  require("nvime.state").config.plan.dir = plan_dir
  require("nvime.state").plan = require("nvime.state").plan or {}
  require("nvime.state").plan.loaded = false
  require("nvime.state").plan.plans = nil

  local plan_id = "0098-inline-render"
  local plan_path = plan_dir .. "/" .. plan_id
  vim.fn.mkdir(plan_path, "p")
  local plan_obj = {
    version = 1,
    id = plan_id,
    title = "Inline span render",
    why = "Make `backticked` prose readable inside the plan view.",
    created_at = os.time(),
    updated_at = os.time(),
    files_estimated = { "lua/nvime/plan.lua" },
    acceptance = { { text = "uses `inline_spans`", status = "pending" } },
    steps = {
      {
        id = 1,
        intent = "Wrap `fd:close()` in `pcall`",
        file = "lua/nvime/plan.lua",
        range = { line1 = 71, line2 = 90 },
        depends_on = {},
        tests = { "stylua --check `lua/nvime/plan.lua`" },
        notes = "Reference: `chat.lua:120-145`.",
        status = "pending",
      },
    },
  }
  vim.fn.writefile({ vim.json.encode(plan_obj) }, plan_path .. "/plan.json")
  vim.fn.writefile({ "# Inline render", "" }, plan_path .. "/plan.md")
  require("nvime.state").plan.loaded = false

  -- Open the plan view and check the buffer text + extmarks.
  plan.open(plan_id)
  local view_buf = nil
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(b)
    if name:find(plan_id, 1, true) and vim.bo[b].filetype == "nvimeplan" then
      view_buf = b
      break
    end
  end
  assert(view_buf, "plan view: buffer was created")

  local lines = vim.api.nvim_buf_get_lines(view_buf, 0, -1, false)
  local intent_row = nil
  local notes_row = nil
  local tests_row = nil
  local why_row = nil
  for i, line in ipairs(lines) do
    if line:find("Wrap `fd:close()` in `pcall`", 1, true) then
      intent_row = i - 1
    elseif line:find("notes · Reference: `chat.lua:120-145`.", 1, true) then
      notes_row = i - 1
    elseif line:find("tests · stylua --check `lua/nvime/plan.lua`", 1, true) then
      tests_row = i - 1
    elseif line:find("Make `backticked` prose readable", 1, true) then
      why_row = i - 1
    end
  end
  assert(intent_row, "plan view: step intent line present")
  assert(notes_row, "plan view: notes line present")
  assert(tests_row, "plan view: tests line present")
  assert(why_row, "plan view: why paragraph present")

  -- Buffer text MUST still contain literal backticks — no concealment.
  assert(lines[intent_row + 1]:find("`fd:close()`", 1, true), "plan view: backticks remain in intent line")
  assert(lines[notes_row + 1]:find("`chat.lua:120-145`", 1, true), "plan view: backticks remain in notes line")

  -- Collect extmarks across all namespaces and look for the
  -- NvimeMarkdownInlineCode highlight on the backticked spans.
  local function has_hl_at(row, hl)
    local marks = vim.api.nvim_buf_get_extmarks(view_buf, -1, { row, 0 }, { row, -1 }, { details = true })
    for _, m in ipairs(marks) do
      if m[4] and m[4].hl_group == hl then
        return true
      end
    end
    return false
  end

  assert(has_hl_at(intent_row, "NvimeMarkdownInlineCode"), "plan view: intent line has NvimeMarkdownInlineCode mark")
  assert(has_hl_at(notes_row, "NvimeMarkdownInlineCode"), "plan view: notes line has NvimeMarkdownInlineCode mark")
  assert(has_hl_at(tests_row, "NvimeMarkdownInlineCode"), "plan view: tests line has NvimeMarkdownInlineCode mark")
  assert(has_hl_at(why_row, "NvimeMarkdownInlineCode"), "plan view: why paragraph has NvimeMarkdownInlineCode mark")

  -- The "tests · " label gets the NvimePlanMetaLabel highlight separate
  -- from the body, so the eye lands on the label first.
  assert(has_hl_at(tests_row, "NvimePlanMetaLabel"), "plan view: tests label gets NvimePlanMetaLabel")
  assert(has_hl_at(notes_row, "NvimePlanMetaLabel"), "plan view: notes label gets NvimePlanMetaLabel")

  -- Section heading: an icon-led "WHY" row carrying the heading highlight.
  local why_heading_row = nil
  for i, line in ipairs(lines) do
    if line:find("WHY%s*$") then
      why_heading_row = i - 1
      break
    end
  end
  assert(why_heading_row, "plan view: WHY section heading present")
  assert(has_hl_at(why_heading_row, "NvimePlanHeading"), "plan view: WHY heading row gets NvimePlanHeading")

  -- Step file/range row separates the path from the L<n>-<m> label.
  local file_row = nil
  for i, line in ipairs(lines) do
    if line:find("lua/nvime/plan.lua  L71-90", 1, true) then
      file_row = i - 1
      break
    end
  end
  assert(file_row, "plan view: file/range row present")
  assert(has_hl_at(file_row, "NvimePlanFile"), "plan view: file row has NvimePlanFile mark")
  assert(has_hl_at(file_row, "NvimePlanRange"), "plan view: file row has NvimePlanRange mark")

  -- Cleanup so other tests don't see this plan.
  pcall(vim.api.nvim_buf_delete, view_buf, { force = true })
  require("nvime.state").config.plan.dir = nil
  require("nvime.state").plan.loaded = false
  require("nvime.state").plan.plans = nil
end)(); -- --------------------------------------------------------------------------- -- nvime.usage parsing & ledger -- ---------------------------------------------------------------------------
(function()
  local usage_path = tmp .. "/usage-test.json"
  vim.fn.delete(usage_path)
  require("nvime.state").config.usage = {
    enabled = true,
    path = usage_path,
    max_days = 90,
    statusline = true,
    rates = {},
  }
  local usage = require("nvime.usage")
  package.loaded["nvime.usage"] = nil
  usage = require("nvime.usage")
  usage.reset()

  local claude_decoded = vim.json.decode([[
    {"type":"result","subtype":"success","is_error":false,"session_id":"abc",
     "total_cost_usd":0.5,"usage":{"input_tokens":100,"output_tokens":50,
       "cache_creation_input_tokens":1000,"cache_read_input_tokens":250},
     "modelUsage":{"claude-opus-4-8":{"costUSD":0.49},"claude-haiku-4-5":{"costUSD":0.01}}}
  ]])
  local claude_sample = usage.parse_claude(claude_decoded)
  assert_eq(claude_sample.input, 100, "usage: claude input parsed")
  assert_eq(claude_sample.output, 50, "usage: claude output parsed")
  assert_eq(claude_sample.cache_creation, 1000, "usage: claude cache_creation parsed")
  assert_eq(claude_sample.cache_read, 250, "usage: claude cache_read parsed")
  assert_eq(claude_sample.cost_usd, 0.5, "usage: claude cost taken from total_cost_usd")
  assert_eq(claude_sample.model, "claude-opus-4-8", "usage: claude model picked by highest cost")

  local codex_decoded = vim.json.decode([[
    {"type":"turn.completed","usage":{"input_tokens":2000,"cached_input_tokens":1500,"output_tokens":40,"reasoning_output_tokens":120}}
  ]])
  local codex_sample = usage.parse_codex(codex_decoded)
  -- Codex reports input_tokens as the TOTAL (cached + fresh). parse_codex
  -- subtracts cached so input + cache_read never double-counts: 2000 - 1500 = 500.
  assert_eq(codex_sample.input, 500, "usage: codex fresh input = input_tokens - cached")
  assert_eq(codex_sample.cache_read, 1500, "usage: codex cached input mapped to cache_read")
  assert_eq(codex_sample.reasoning, 120, "usage: codex reasoning parsed")

  local rec =
    usage.record({ sample = claude_sample, provider = "claude", lane = "review", model = claude_sample.model })
  assert(rec, "usage: record returns last_run")
  assert_eq(rec.lane, "review", "usage: record lane preserved")

  local crec = usage.record({ sample = codex_sample, provider = "codex", lane = "plan", model = codex_sample.model })
  assert(crec, "usage: codex record returns last_run")
  assert(crec.sample.cost_usd > 0, "usage: codex cost computed from rates when missing")

  local ledger = usage.read()
  assert_eq(ledger.totals.runs, 2, "usage: ledger totals.runs counts both records")
  assert(ledger.by_lane.review and ledger.by_lane.plan, "usage: ledger has per-lane buckets")
  assert(vim.fn.filereadable(usage_path) == 1, "usage: ledger persisted to disk")
  local summary = usage.summary_text()
  assert(summary:find("totals", 1, true), "usage: summary_text mentions totals")
  assert(summary:find("review", 1, true) and summary:find("plan", 1, true), "usage: summary lists per-lane")
end)(); -- --------------------------------------------------------------------------- -- nvime.usage: dashboard render -- ---------------------------------------------------------------------------
(function()
  local state = require("nvime.state")
  local dash_path = tmp .. "/usage-dash.json"
  vim.fn.delete(dash_path)
  local saved_usage = state.config.usage
  state.config.usage = {
    enabled = true,
    path = dash_path,
    max_days = 90,
    statusline = false,
    rates = {},
    budgets = { total_usd = 50.0 },
  }
  package.loaded["nvime.usage"] = nil
  local usage = require("nvime.usage")
  usage.reset()

  -- Empty ledger → a friendly empty state, never an error or fabricated zeros.
  local ebuf = usage.open_panel()
  assert(ebuf and vim.api.nvim_buf_is_valid(ebuf), "usage dashboard: empty render returns a buffer")
  local empty_joined = table.concat(vim.api.nvim_buf_get_lines(ebuf, 0, -1, false), "\n")
  assert(empty_joined:find("No usage recorded yet", 1, true), "usage dashboard: empty state message")
  usage.close_panel()

  usage.record({
    lane = "edit",
    provider = "claude",
    sample = { input = 2000, output = 6000, cache_read = 200000, cache_creation = 30000, model = "claude-opus-4-8" },
  })
  usage.record({
    lane = "review",
    provider = "claude",
    sample = { input = 1000, output = 3000, cache_read = 90000, cache_creation = 10000, model = "claude-opus-4-8" },
  })

  local buf, win = usage.open_panel()
  assert(buf and vim.api.nvim_buf_is_valid(buf), "usage dashboard: render returns a valid buffer")
  assert(win and vim.api.nvim_win_is_valid(win), "usage dashboard: opens a float window")
  local joined = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  for _, want in ipairs({ "RUNWAY", "DAILY COST", "COST BY LANE", "TOKENS & EFFICIENCY", "STATS", "edit", "cache hit" }) do
    assert(joined:find(want, 1, true), "usage dashboard: section present — " .. want)
  end
  -- A total budget is set and is far from exhausted, so the runway hero shows a
  -- days-left headline and a calendar run-out date.
  assert(joined:find("DAYS LEFT", 1, true), "usage dashboard: runway shows days-left")
  assert(joined:find("runs out", 1, true), "usage dashboard: runway shows a run-out date")
  -- Palette highlight extmarks were applied to the rendered lines.
  local dash_ns = vim.api.nvim_get_namespaces()["nvime.usage.dashboard"]
  assert(dash_ns, "usage dashboard: namespace created")
  assert(#vim.api.nvim_buf_get_extmarks(buf, dash_ns, 0, -1, {}) > 0, "usage dashboard: highlight extmarks applied")

  -- The `t` key toggles the plot metric; the heading must follow it (cost view
  -- says DAILY COST, token view says DAILY TOKENS — not a stale hardcoded label).
  vim.cmd("normal t")
  local toggled = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(toggled:find("DAILY TOKENS", 1, true), "usage dashboard: t toggles the plot to tokens")
  vim.cmd("normal t") -- back to cost

  -- A dimmed backdrop window is opened behind the float; it must be torn down
  -- even when the float is closed by a path other than the q/<Esc> keymap
  -- (e.g. :q / <C-w>c / programmatic close) — via the WinClosed autocmd.
  local function backdrop_count()
    local n = 0
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      local ok_wh, wh = pcall(function()
        return vim.wo[w].winhighlight
      end)
      if ok_wh and tostring(wh):find("NvimeBackdrop", 1, true) then
        n = n + 1
      end
    end
    return n
  end
  assert(backdrop_count() >= 1, "usage dashboard: a backdrop window is open behind the float")
  local float_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_close(float_win, true)
  assert(backdrop_count() == 0, "usage dashboard: backdrop torn down on a non-keymap close")

  usage.close_panel()
  assert(not (win and vim.api.nvim_win_is_valid(win)), "usage dashboard: close tears down the window")

  state.config.usage = saved_usage
  package.loaded["nvime.usage"] = nil
end)(); -- --------------------------------------------------------------------------- -- nvime.attribution: blame popup -- ---------------------------------------------------------------------------
(function()
  local file = vim.fn.tempname() .. ".lua"
  vim.fn.writefile({
    "local M = {}",
    "function M.greet(name)",
    "  return 'hello ' .. name",
    "end",
    "return M",
  }, file)
  vim.cmd("edit " .. vim.fn.fnameescape(file))
  local bufnr = vim.api.nvim_get_current_buf()
  -- Derive rel from the BUFFER NAME (what show_at_cursor uses), not the raw
  -- tempname: on macOS `:edit` resolves /var/... to /private/var/..., so keying
  -- the record off the tempname would not match the cursor lookup.
  local buf_name = vim.api.nvim_buf_get_name(bufnr)
  local rel = require("nvime.git").repo_relative_path(buf_name) or buf_name
  -- Record an attribution entry covering lines 2-3
  require("nvime.attribution").record({
    file = rel,
    line1 = 2,
    line2 = 3,
    lines = { "function M.greet(name)", "  return 'hello ' .. name" },
    rationale = "added a greeting helper",
    provider = "claude",
    plan_id = "P1",
    step_id = 1,
  })
  vim.api.nvim_win_set_cursor(0, { 3, 0 })
  local matches = require("nvime.attribution").show_at_cursor()
  assert(matches, "blame: show_at_cursor returns matches when an entry covers the line")
  assert(#matches >= 1, "blame: at least one match")
  local popup = vim.g.nvime_blame_popup
  assert(popup and popup.bufnr and vim.api.nvim_buf_is_valid(popup.bufnr), "blame: popup buffer created")
  local popup_lines = vim.api.nvim_buf_get_lines(popup.bufnr, 0, -1, false)
  local joined = table.concat(popup_lines, "\n")
  assert(joined:find(rel, 1, true), "blame: popup header lists file:line")
  assert(joined:find("added a greeting helper", 1, true), "blame: popup includes rationale")
  assert(joined:find("P1", 1, true), "blame: popup mentions plan id")
  require("nvime.attribution").close_popup()
  pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
end)(); -- --------------------------------------------------------------------------- -- nvime.mcp_server: JSON-RPC over the in-process API -- ---------------------------------------------------------------------------
(function()
  -- Earlier IIFEs (notably test_loop) chdir into temp dirs and may not
  -- restore. Anchor the MCP server's repo_root via env so its tools
  -- resolve against the actual project regardless of process cwd.
  local prior_cwd = vim.fn.getcwd()
  vim.env.NVIME_REPO_ROOT = root

  local server = require("nvime.mcp_server")
  local function send(req)
    return server.handle_line(vim.json.encode(req))
  end

  local init = send({ jsonrpc = "2.0", id = 1, method = "initialize", params = { protocolVersion = "2025-03-26" } })
  assert(init.result and init.result.serverInfo, "mcp: initialize returns serverInfo")
  assert_eq(init.result.serverInfo.name, "nvime", "mcp: serverInfo.name is nvime")
  assert_eq(init.result.protocolVersion, "2025-03-26", "mcp: initialize echoes a supported protocol version")

  local bogus = send({ jsonrpc = "2.0", id = 99, method = "initialize", params = { protocolVersion = "9999-99-99" } })
  assert(
    bogus.result.protocolVersion ~= "9999-99-99",
    "mcp: initialize does NOT echo unsupported client protocol version"
  )

  local list = send({ jsonrpc = "2.0", id = 2, method = "tools/list" })
  assert(list.result and list.result.tools, "mcp: tools/list returns tools")
  local names = {}
  for _, tool in ipairs(list.result.tools) do
    names[tool.name] = true
  end
  assert(names["nvime.list_plans"], "mcp: list_plans tool advertised")
  assert(names["nvime.recent_audits"], "mcp: recent_audits tool advertised")
  assert(names["nvime.usage_summary"], "mcp: usage_summary tool advertised")
  assert(names["nvime.search_attribution"], "mcp: search_attribution tool advertised")
  assert(names["nvime.get_plan"], "mcp: get_plan tool advertised")
  assert(names["nvime.tree_sitter_symbols"], "mcp: tree_sitter_symbols tool advertised")
  assert(names["nvime.git_log"], "mcp: git_log tool advertised")
  assert(names["nvime.git_blame"], "mcp: git_blame tool advertised")
  assert(names["nvime.test_run"], "mcp: test_run tool advertised")
  assert(names["nvime.session_search"], "mcp: session_search tool advertised")
  assert(names["nvime.session_recent"], "mcp: session_recent tool advertised")
  assert(names["nvime.recent_diffs"], "mcp: recent_diffs tool advertised")
  assert(names["nvime.check_policy"], "mcp: check_policy tool advertised")
  assert(names["nvime.find_symbol"], "mcp: find_symbol tool advertised")

  local plans = send({
    jsonrpc = "2.0",
    id = 3,
    method = "tools/call",
    params = { name = "nvime.list_plans", arguments = {} },
  })
  assert(plans.result and plans.result.content, "mcp: list_plans returns content")
  assert_eq(plans.result.content[1].type, "text", "mcp: list_plans content is text")

  local bad = send({
    jsonrpc = "2.0",
    id = 4,
    method = "tools/call",
    params = { name = "does.not.exist", arguments = {} },
  })
  assert(bad.error and bad.error.code == -32601, "mcp: unknown tool returns method-not-found")

  local unknown_method = send({ jsonrpc = "2.0", id = 5, method = "no_such_method" })
  assert(unknown_method.error and unknown_method.error.code == -32601, "mcp: unknown method returns -32601")

  local notification = send({ jsonrpc = "2.0", method = "notifications/initialized" })
  assert(notification == nil, "mcp: notifications produce no response")

  local unknown_notification = send({ jsonrpc = "2.0", method = "no_such_notification" })
  assert(unknown_notification == nil, "mcp: unknown notifications produce no response")

  -- Path traversal must be refused.
  local traversal_search = send({
    jsonrpc = "2.0",
    id = 10,
    method = "tools/call",
    params = { name = "nvime.search_attribution", arguments = { file = "../../etc/passwd", line = 1 } },
  })
  assert(
    traversal_search.result and traversal_search.result.isError,
    "mcp: search_attribution rejects parent traversal"
  )

  local absolute_search = send({
    jsonrpc = "2.0",
    id = 11,
    method = "tools/call",
    params = { name = "nvime.search_attribution", arguments = { file = "/etc/passwd", line = 1 } },
  })
  assert(absolute_search.result and absolute_search.result.isError, "mcp: search_attribution rejects absolute paths")

  do
    local mcp_repo = vim.fn.tempname() .. "/mcp-repo"
    local outside = vim.fn.tempname() .. "/outside"
    vim.fn.mkdir(mcp_repo .. "/inside", "p")
    vim.fn.mkdir(outside, "p")
    vim.fn.writefile({ "return 'secret'" }, outside .. "/secret.lua")
    local link_ok = pcall(vim.loop.fs_symlink, outside, mcp_repo .. "/inside/link")
    if link_ok then
      vim.env.NVIME_REPO_ROOT = mcp_repo
      local symlink_escape = send({
        jsonrpc = "2.0",
        id = 13,
        method = "tools/call",
        params = { name = "nvime.tree_sitter_symbols", arguments = { file = "inside/link/secret.lua" } },
      })
      assert(
        symlink_escape.result and symlink_escape.result.isError,
        "mcp: tree_sitter_symbols rejects symlink escapes"
      )
      vim.env.NVIME_REPO_ROOT = root
    end
  end

  local traversal_plan = send({
    jsonrpc = "2.0",
    id = 12,
    method = "tools/call",
    params = { name = "nvime.get_plan", arguments = { id = "../../.." } },
  })
  assert(traversal_plan.result and traversal_plan.result.isError, "mcp: get_plan rejects parent traversal")

  -- tree_sitter_symbols on a real Lua file should yield > 0 symbols when
  -- the lua tree-sitter parser is reachable; under -u NONE that's not
  -- always the case, so we accept either a successful symbol list or
  -- the documented "no parser" error.
  local ts_call = send({
    jsonrpc = "2.0",
    id = 20,
    method = "tools/call",
    params = { name = "nvime.tree_sitter_symbols", arguments = { file = "lua/nvime/git.lua" } },
  })
  assert(ts_call.result and ts_call.result.content, "mcp: tree_sitter_symbols returns content")
  if not ts_call.result.isError then
    local ts_payload = vim.json.decode(ts_call.result.content[1].text)
    assert_eq(ts_payload.filetype, "lua", "mcp: tree_sitter_symbols infers .lua filetype")
    assert(ts_payload.count > 0, "mcp: tree_sitter_symbols returns at least one symbol")
  else
    -- Accept any documented error path: missing parser / parse failure /
    -- unknown filetype. We're only verifying we got a structured failure.
    assert(
      ts_call.result.content[1].text:sub(1, 6) == "error:",
      "mcp: tree_sitter_symbols failure path returns a structured error"
    )
  end

  local ts_traversal = send({
    jsonrpc = "2.0",
    id = 21,
    method = "tools/call",
    params = { name = "nvime.tree_sitter_symbols", arguments = { file = "../../etc/passwd" } },
  })
  assert(ts_traversal.result and ts_traversal.result.isError, "mcp: tree_sitter_symbols rejects parent traversal")

  -- git_log + git_blame against the project itself. The test runs from
  -- the nvime checkout cwd which IS a git repo, so the happy path
  -- exercises here. If it fails for any reason (e.g. a sandboxed CI
  -- with no git binary) we want a clear failure rather than a json
  -- decode crash.
  local log_call = send({
    jsonrpc = "2.0",
    id = 30,
    method = "tools/call",
    params = { name = "nvime.git_log", arguments = { limit = 3 } },
  })
  assert(log_call.result and log_call.result.content, "mcp: git_log returns content")
  assert(
    not log_call.result.isError,
    "mcp: git_log succeeds in a git repo (got: " .. (log_call.result.content[1].text or ""):sub(1, 200) .. ")"
  )
  local log_payload = vim.json.decode(log_call.result.content[1].text)
  assert(log_payload.commits and #log_payload.commits > 0, "mcp: git_log surfaces real commits")
  assert(
    log_payload.commits[1].sha and log_payload.commits[1].author and log_payload.commits[1].subject,
    "mcp: git_log entries carry sha+author+subject"
  )

  local blame_call = send({
    jsonrpc = "2.0",
    id = 31,
    method = "tools/call",
    params = { name = "nvime.git_blame", arguments = { path = "README.md", line = 1 } },
  })
  assert(blame_call.result and blame_call.result.content, "mcp: git_blame returns content")
  assert(
    not blame_call.result.isError,
    "mcp: git_blame succeeds (got: " .. (blame_call.result.content[1].text or ""):sub(1, 200) .. ")"
  )
  local blame_payload = vim.json.decode(blame_call.result.content[1].text)
  assert(blame_payload.sha and blame_payload.author, "mcp: git_blame returns sha+author")

  -- test_run against a synthetic command we know exits 0
  local run_call = send({
    jsonrpc = "2.0",
    id = 40,
    method = "tools/call",
    params = { name = "nvime.test_run", arguments = { runner = "echo from-test && exit 0", timeout = 5000 } },
  })
  assert(run_call.result and run_call.result.content, "mcp: test_run returns content")
  local run_payload = vim.json.decode(run_call.result.content[1].text)
  assert_eq(run_payload.exit_code, 0, "mcp: test_run captures exit code 0")
  assert(run_payload.stdout_tail:find("from-test", 1, true), "mcp: test_run captures stdout")

  local run_fail = send({
    jsonrpc = "2.0",
    id = 41,
    method = "tools/call",
    params = { name = "nvime.test_run", arguments = { runner = "echo broke 1>&2 && exit 7", timeout = 5000 } },
  })
  local fail_payload = vim.json.decode(run_fail.result.content[1].text)
  assert_eq(fail_payload.exit_code, 7, "mcp: test_run captures non-zero exit")
  assert(fail_payload.stderr_tail:find("broke", 1, true), "mcp: test_run captures stderr")

  local blocked_runner = "git commit --allow-empty -m blocked-by-nvime"
  local run_blocked = send({
    jsonrpc = "2.0",
    id = 42,
    method = "tools/call",
    params = { name = "nvime.test_run", arguments = { runner = blocked_runner, timeout = 5000 } },
  })
  assert(run_blocked.result and run_blocked.result.content, "mcp: test_run shellguard block returns content")
  local blocked_payload = vim.json.decode(run_blocked.result.content[1].text)
  assert_eq(blocked_payload.runner, blocked_runner, "mcp: test_run preserves blocked runner")
  assert_eq(blocked_payload.exit_code, 126, "mcp: test_run returns shellguard exit code")
  assert_eq(blocked_payload.timed_out, false, "mcp: test_run shellguard block does not time out")
  assert(
    blocked_payload.stderr_tail:find("nvime shellguard blocked: git commit", 1, true),
    "mcp: test_run captures shellguard stderr"
  )

  local recent = send({
    jsonrpc = "2.0",
    id = 50,
    method = "tools/call",
    params = { name = "nvime.session_recent", arguments = { limit = 5 } },
  })
  assert(recent.result and recent.result.content, "mcp: session_recent returns content")
  local recent_payload = vim.json.decode(recent.result.content[1].text)
  assert(recent_payload.sessions, "mcp: session_recent returns sessions array")

  local search = send({
    jsonrpc = "2.0",
    id = 51,
    method = "tools/call",
    params = { name = "nvime.session_search", arguments = { query = "asdfneverappearsxyz", limit = 5 } },
  })
  assert(search.result and search.result.content, "mcp: session_search returns content")
  local search_payload = vim.json.decode(search.result.content[1].text)
  assert_eq(search_payload.count, 0, "mcp: session_search returns 0 for impossible query")

  local search_missing_query = send({
    jsonrpc = "2.0",
    id = 52,
    method = "tools/call",
    params = { name = "nvime.session_search", arguments = {} },
  })
  assert(
    search_missing_query.result and search_missing_query.result.isError,
    "mcp: session_search rejects missing query"
  )

  -- #5: nvime.check_policy returns CONSTRAINTS only (never a risk score / green
  -- light). A human-only path is blocked; a normal path is not "approved", just
  -- unconstrained; traversal is rejected.
  local pol_block = send({
    jsonrpc = "2.0",
    id = 60,
    method = "tools/call",
    params = { name = "nvime.check_policy", arguments = { file = "migrations/0001_init.sql" } },
  })
  assert(pol_block.result and pol_block.result.content, "mcp: check_policy returns content")
  local pol_block_payload = vim.json.decode(pol_block.result.content[1].text)
  assert_eq(pol_block_payload.require_human, true, "mcp: check_policy flags migrations as human-only")
  assert_eq(pol_block_payload.blocked, true, "mcp: check_policy blocks a human-only path")
  -- The response must NOT carry a risk score / green-light field (regression
  -- guard against re-adding a "looks safe, proceed" signal).
  assert(pol_block_payload.risk == nil, "mcp: check_policy returns no risk field")
  assert(pol_block_payload.level == nil, "mcp: check_policy returns no level field")
  assert(pol_block_payload.score == nil, "mcp: check_policy returns no score field")

  local pol_ok = send({
    jsonrpc = "2.0",
    id = 61,
    method = "tools/call",
    params = { name = "nvime.check_policy", arguments = { file = "lua/nvime/init.lua" } },
  })
  local pol_ok_payload = vim.json.decode(pol_ok.result.content[1].text)
  assert_eq(pol_ok_payload.blocked, false, "mcp: check_policy does not block an ordinary source path")
  assert_eq(pol_ok_payload.matched_rule, nil, "mcp: check_policy reports no matched rule for an ordinary path")

  local pol_traversal = send({
    jsonrpc = "2.0",
    id = 62,
    method = "tools/call",
    params = { name = "nvime.check_policy", arguments = { file = "../../etc/passwd" } },
  })
  assert(pol_traversal.result and pol_traversal.result.isError, "mcp: check_policy rejects parent-traversal paths")

  -- find_symbol: bounded, language-agnostic git-grep navigation. Searched
  -- against the project itself (a git repo). `repo_root` is defined and used
  -- many times inside mcp_server.lua, so a path-scoped word search must hit it.
  local fs_call = send({
    jsonrpc = "2.0",
    id = 70,
    method = "tools/call",
    params = { name = "nvime.find_symbol", arguments = { name = "repo_root", path = "lua/nvime/mcp_server.lua" } },
  })
  assert(fs_call.result and fs_call.result.content, "mcp: find_symbol returns content")
  assert(
    not fs_call.result.isError,
    "mcp: find_symbol succeeds in a git repo (got: " .. (fs_call.result.content[1].text or ""):sub(1, 200) .. ")"
  )
  local fs_payload = vim.json.decode(fs_call.result.content[1].text)
  assert_eq(fs_payload.source, "git", "mcp: find_symbol uses git grep inside a git repo")
  assert(fs_payload.count > 0, "mcp: find_symbol locates a known identifier")
  assert(
    fs_payload.hits[1].file and fs_payload.hits[1].line and fs_payload.hits[1].text,
    "mcp: find_symbol hits carry file+line+text"
  )
  assert_eq(fs_payload.hits[1].file, "lua/nvime/mcp_server.lua", "mcp: find_symbol respects the path scope")

  -- Word-boundary matching: "repo_roo" (a strict prefix) must NOT match the
  -- whole word "repo_root" in fixed-word mode -> zero hits, no error.
  local fs_prefix = send({
    jsonrpc = "2.0",
    id = 71,
    method = "tools/call",
    params = { name = "nvime.find_symbol", arguments = { name = "repo_roo", path = "lua/nvime/mcp_server.lua" } },
  })
  local fs_prefix_payload = vim.json.decode(fs_prefix.result.content[1].text)
  assert_eq(fs_prefix_payload.count, 0, "mcp: find_symbol word-boundary rejects a strict prefix")

  -- A genuinely-absent identifier returns an empty, non-error result. The
  -- needle is assembled from parts so the literal string never appears in
  -- this test file (git grep searches the working tree, which includes it).
  local absent = "zzz" .. "nosuch" .. "symbol" .. "qqq"
  local fs_none = send({
    jsonrpc = "2.0",
    id = 72,
    method = "tools/call",
    params = { name = "nvime.find_symbol", arguments = { name = absent } },
  })
  assert(not fs_none.result.isError, "mcp: find_symbol no-match is not an error")
  assert_eq(
    vim.json.decode(fs_none.result.content[1].text).count,
    0,
    "mcp: find_symbol returns 0 hits for an absent symbol"
  )

  -- Missing name and path traversal are rejected.
  local fs_missing = send({
    jsonrpc = "2.0",
    id = 73,
    method = "tools/call",
    params = { name = "nvime.find_symbol", arguments = {} },
  })
  assert(fs_missing.result and fs_missing.result.isError, "mcp: find_symbol rejects a missing name")

  local fs_traversal = send({
    jsonrpc = "2.0",
    id = 74,
    method = "tools/call",
    params = { name = "nvime.find_symbol", arguments = { name = "x", path = "../../etc" } },
  })
  assert(fs_traversal.result and fs_traversal.result.isError, "mcp: find_symbol rejects parent-traversal paths")

  vim.env.NVIME_REPO_ROOT = nil
  pcall(vim.api.nvim_set_current_dir, prior_cwd)
end)(); -- --------------------------------------------------------------------------- -- nvime.mcp client: merged config has type=stdio + env on self entry -- ---------------------------------------------------------------------------
(function()
  require("nvime.state").config.mcp = {
    enabled = true,
    expose_self = true,
    servers = {},
    config_path = nil,
  }
  local mcp = require("nvime.mcp")
  local cfg = mcp.build_config()
  assert(cfg.mcpServers.nvime, "mcp client: self server present")
  assert_eq(cfg.mcpServers.nvime.type, "stdio", "mcp client: self server has type=stdio")
  assert(
    cfg.mcpServers.nvime.env and cfg.mcpServers.nvime.env.NVIME_REPO_ROOT,
    "mcp client: self server passes NVIME_REPO_ROOT env"
  )

  -- expose_self=false drops the self entry
  require("nvime.state").config.mcp.expose_self = false
  local cfg2 = require("nvime.mcp").build_config()
  assert(not cfg2.mcpServers.nvime, "mcp client: self entry omitted when expose_self=false")
  require("nvime.state").config.mcp.expose_self = true
end)(); -- --------------------------------------------------------------------------- -- nvime.test_loop: pass / fail / max-retries -- ---------------------------------------------------------------------------
(function()
  local proj = vim.fn.tempname() .. "/loop-proj"
  vim.fn.mkdir(proj .. "/scripts", "p")
  local script = proj .. "/scripts/test"
  vim.fn.writefile({
    "#!/usr/bin/env sh",
    'if [ -f "$(dirname "$0")/../broken" ]; then echo \'fail\' >&2; exit 1; fi',
    "echo 'ok'; exit 0",
  }, script)
  vim.fn.setfperm(script, "rwxr-xr-x")
  vim.fn.writefile({ "stub" }, proj .. "/broken")

  local target = proj .. "/main.lua"
  vim.fn.writefile({ "-- placeholder", "return {}" }, target)
  vim.cmd("edit " .. vim.fn.fnameescape(target))
  local target_bufnr = vim.api.nvim_get_current_buf()

  local prior_cwd = vim.fn.getcwd()
  vim.api.nvim_set_current_dir(proj)

  require("nvime.state").config.test_loop = {
    enabled = true,
    runner = "./scripts/test",
    auto_fix = false,
    max_retries = 1,
    capture_lines = 100,
  }
  package.loaded["nvime.test_loop"] = nil
  local test_loop = require("nvime.test_loop")
  test_loop.reset_counters()

  -- Stub vim.fn.confirm so the prompt path resolves immediately.
  local original_confirm = vim.fn.confirm
  vim.fn.confirm = function()
    return 2
  end
  local notifications = {}
  local original_notify = vim.notify
  vim.notify = function(msg, level)
    notifications[#notifications + 1] = { msg = msg, level = level }
  end

  local payload_fail = {
    accepted = 1,
    total = 1,
    target_bufnr = target_bufnr,
    path = "main.lua",
    provider = "claude",
  }
  test_loop.maybe_run(payload_fail)
  vim.wait(15000, function()
    for _, n in ipairs(notifications) do
      if n.msg:find("exit=1", 1, true) then
        return true
      end
    end
    return false
  end, 50)
  local saw_fail = false
  for _, n in ipairs(notifications) do
    if n.msg:find("exit=1", 1, true) then
      saw_fail = true
    end
  end
  assert(saw_fail, "test_loop: failure path notifies with exit code")

  -- Now make tests pass and verify the success path
  vim.fn.delete(proj .. "/broken")
  notifications = {}
  test_loop.reset_counters()
  test_loop.maybe_run(payload_fail)
  vim.wait(15000, function()
    for _, n in ipairs(notifications) do
      if n.msg:find("passed", 1, true) then
        return true
      end
    end
    return false
  end, 50)
  local saw_pass = false
  for _, n in ipairs(notifications) do
    if n.msg:find("passed", 1, true) then
      saw_pass = true
    end
  end
  assert(saw_pass, "test_loop: success path emits a 'passed' notification")

  -- Disabled config short-circuits without notifying
  require("nvime.state").config.test_loop.enabled = false
  notifications = {}
  test_loop.maybe_run(payload_fail)
  vim.wait(500, function()
    return false
  end, 50)
  assert(#notifications == 0, "test_loop: disabled config produces no notifications")
  require("nvime.state").config.test_loop.enabled = true

  -- accepted=0 short-circuits even when enabled
  notifications = {}
  test_loop.maybe_run({ accepted = 0, total = 1, target_bufnr = target_bufnr, path = "main.lua" })
  vim.wait(500, function()
    return false
  end, 50)
  assert(#notifications == 0, "test_loop: zero accepted blocks short-circuits")

  vim.notify = original_notify
  vim.fn.confirm = original_confirm
  vim.api.nvim_set_current_dir(prior_cwd)
  pcall(vim.api.nvim_buf_delete, target_bufnr, { force = true })
end)();

(function()
  -- nvime.verify — pre-accept verify lane.
  local diff = require("nvime.diff")
  local verify = require("nvime.verify")
  local state = require("nvime.state")
  local diff_state = state

  -- Unit: glob_to_pattern + path_matches_any
  assert(verify._path_matches_any("src/foo.py", { "*.py" }), "glob matches simple extension")
  assert(
    verify._path_matches_any("a/b/c.py", { "*.py" }),
    "extension glob is path-tolerant by stripping the leading dir match"
  )
  assert(not verify._path_matches_any("src/foo.go", { "*.py" }), "wrong-extension glob does not match")
  assert(verify._path_matches_any("migrations/0001_init.sql", { "migrations/**" }), "dir-glob matches nested file")
  assert(verify._path_matches_any("a/b/secrets/key.pem", { "**/secrets/**" }), "double-star prefix matches nested dir")

  -- Build a session with parseable lua and confirm verify.status == "ok"
  diff_state.current_diff = nil
  diff_state.diffs = {
    active_by_bufnr = {},
    active_by_path = {},
    queue_by_path = {},
  }
  local clean_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(clean_buf, tmp .. "/verify-clean.lua")
  vim.api.nvim_buf_set_lines(clean_buf, 0, -1, false, { "local x = 1" })
  vim.api.nvim_set_current_buf(clean_buf)
  local clean_response = table.concat({
    "RATIONALE: bug=undefined y; patch=define y; why=satisfies callers.",
    "VERIFY: ok",
    "NVIME_DIFF",
    "```diff",
    "--- a/verify-clean.lua",
    "+++ b/verify-clean.lua",
    "@@ -1,1 +1,1 @@",
    "-local x = 1",
    "+local x = 2",
    "```",
  }, "\n")
  local clean_result = diff.start_session({
    bufnr = clean_buf,
    line1 = 1,
    line2 = 1,
    path = "verify-clean.lua",
    source = "test",
  }, clean_response, "claude", "verify-clean")
  assert(clean_result.session, "verify-clean: session opened")
  assert_eq(clean_result.session.verify_attestation, "ok", "VERIFY: line is captured into session")
  -- verify.status should be either "ok" or "pending" (configured external
  -- checks may not have a binary on PATH; that's fine, they skip).
  local clean_verify = clean_result.session.verify
  assert(clean_verify, "verify-clean: session.verify set")
  assert(not clean_verify.parse_error, "verify-clean: clean lua has no parse error")
  assert(
    clean_verify.status == "ok" or clean_verify.status == "pending",
    "verify-clean: status ok or pending while externals run"
  )

  -- Synthetic parse-error path: inject a fake parse_error directly so the
  -- gate logic is exercised without relying on a syntactically broken lua
  -- response (which the diff parser would reject earlier).
  local broken_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(broken_buf, tmp .. "/verify-broken.lua")
  vim.api.nvim_buf_set_lines(broken_buf, 0, -1, false, { "local y = 1" })
  vim.api.nvim_set_current_buf(broken_buf)
  local broken_response = table.concat({
    "RATIONALE: bug=undefined z; patch=add z; why=satisfies callers.",
    "NVIME_DIFF",
    "```diff",
    "--- a/verify-broken.lua",
    "+++ b/verify-broken.lua",
    "@@ -1,1 +1,1 @@",
    "-local y = 1",
    "+local y = 2",
    "```",
  }, "\n")
  local broken_result = diff.start_session({
    bufnr = broken_buf,
    line1 = 1,
    line2 = 1,
    path = "verify-broken.lua",
    source = "test",
  }, broken_response, "claude", "verify-broken")
  assert(broken_result.session, "verify-broken: session opened")
  broken_result.session.verify = {
    status = "error",
    parse_error = true,
    findings = {
      { severity = "error", line = 1, source = "parse", kind = "parse", message = "fake parse error" },
    },
    by_check = { parse = { code = 1, count = 1 } },
    summary = "parse error",
  }
  local pending_blocks = {}
  for _, hunk in ipairs(broken_result.session.hunks or {}) do
    for _, block in ipairs(hunk.blocks or {}) do
      pending_blocks[#pending_blocks + 1] = block
    end
  end
  -- accept_blocks expects blocks; make sure they're built
  if #pending_blocks == 0 then
    diff.accept_all()
    -- accept_all with parse_error should refuse silently; buffer unchanged
    assert_eq(
      table.concat(vim.api.nvim_buf_get_lines(broken_buf, 0, -1, false), "\n"),
      "local y = 1",
      "verify gate refuses silent accept on parse error"
    )
  end
  -- Force-accept (gA!) bypasses the gate and writes a verify_force event.
  local audit_lines_before = vim.fn.filereadable(audit_path) == 1 and #vim.fn.readfile(audit_path) or 0
  diff.accept_all({ force = true })
  assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(broken_buf, 0, -1, false), "\n"),
    "local y = 2",
    "force-accept applies the patch even with parse error"
  )
  local audit_lines_after = vim.fn.readfile(audit_path)
  local saw_verify_force = false
  for i = audit_lines_before + 1, #audit_lines_after do
    local ok, decoded = pcall(vim.json.decode, audit_lines_after[i])
    if ok and type(decoded) == "table" and decoded.event == "verify_force" then
      saw_verify_force = true
      break
    end
  end
  assert(saw_verify_force, "verify gate writes verify_force audit event on force-accept")

  -- verify.verify_path on parseable content returns status = "ok"
  local probe_path = tmp .. "/verify-probe.lua"
  vim.fn.writefile({ "local probe = 1" }, probe_path)
  local probe_result = verify.verify_path(probe_path, nil, { wait_ms = 0 })
  assert(probe_result, "verify_path returns a result")
  assert(not probe_result.parse_error, "verify_path on clean file: no parse error")

  -- MCP path: synthetic content with explicit lang derivation. Anchor the
  -- parse-error assertion on Lua, whose tree-sitter parser ships with every
  -- Neovim, so the contract is exercised on every machine. Stock Neovim does
  -- NOT bundle the Python parser, so the Python case runs only where it is
  -- actually installed; otherwise it skips (visibly) rather than failing here.
  local broken_lua = verify.verify_path("nonexistent.lua", "local a = = 1", { wait_ms = 0 })
  assert(broken_lua.parse_error, "verify_path on broken lua: parse_error is true")
  assert(broken_lua.status == "error", "verify_path on broken lua: status=error")

  local function ts_lang_available(lang)
    return pcall(vim.treesitter.get_string_parser, "x", lang)
  end
  if ts_lang_available("python") then
    local broken_probe = verify.verify_path("nonexistent.py", "def f(:\n    pass", { wait_ms = 0 })
    assert(broken_probe.parse_error, "verify_path on broken python: parse_error is true")
    assert(broken_probe.status == "error", "verify_path on broken python: status=error")
  else
    print("[nvime-test] SKIP: python tree-sitter parser unavailable; broken-python parse-error case not exercised")
  end

  local clean_probe = verify.verify_path("nonexistent.lua", "local a = 1", { wait_ms = 0 })
  assert(not clean_probe.parse_error, "verify_path on clean lua: no parse error")

  -- Regression-only gate: synthetic content where the *original* doesn't
  -- parse should not gate accept, because there is no regression to flag.
  local synthetic_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(synthetic_buf, tmp .. "/synthetic.lua")
  vim.api.nvim_buf_set_lines(synthetic_buf, 0, -1, false, { "alpha", "beta" })
  vim.api.nvim_set_current_buf(synthetic_buf)
  local synthetic_response = table.concat({
    "RATIONALE: rename placeholders",
    "NVIME_DIFF",
    "```diff",
    "--- a/synthetic.lua",
    "+++ b/synthetic.lua",
    "@@ -1,2 +1,2 @@",
    "-alpha",
    "-beta",
    "+ALPHA",
    "+BETA",
    "```",
  }, "\n")
  local synthetic_result = require("nvime.diff").start_session({
    bufnr = synthetic_buf,
    line1 = 1,
    line2 = 2,
    path = "synthetic.lua",
    source = "test",
  }, synthetic_response, "claude", "synthetic")
  assert(synthetic_result.session, "synthetic: session opened")
  assert(
    not synthetic_result.session.verify.parse_error,
    "regression-only gate: parse_error not set when original was already unparseable"
  )
end)();

(function()
  -- nvime.risk — blast-radius badge.
  local risk = require("nvime.risk")

  -- Unit: classify thresholds
  local low_level = risk._classify({ lines_added = 1, lines_removed = 0, ai_share = 0, sensitive_tags = {} })
  assert_eq(low_level, "low", "tiny diff with no tags is low risk")

  local medium_level = risk._classify({ lines_added = 50, lines_removed = 0, ai_share = 0, sensitive_tags = {} })
  assert_eq(medium_level, "medium", "diff above lines.medium threshold is medium")

  local high_level = risk._classify({ lines_added = 130, lines_removed = 0, ai_share = 0, sensitive_tags = {} })
  assert_eq(high_level, "high", "diff above lines.high threshold is high")

  local sensitive_level = risk._classify({
    lines_added = 1,
    lines_removed = 0,
    ai_share = 0,
    sensitive_tags = { "sensitive" },
  })
  assert_eq(sensitive_level, "high", "sensitive tag promotes to high regardless of size")

  local ai_high = risk._classify({ lines_added = 1, lines_removed = 0, ai_share = 0.6, sensitive_tags = {} })
  assert_eq(ai_high, "high", "ai_share above threshold promotes to high")

  -- Unit: sensitive tag matching against defaults
  local tags = risk._sensitive_tags("migrations/0001_init.sql")
  assert(vim.tbl_contains(tags, "sensitive"), "migrations/** is tagged sensitive by default")
  local lock_tags = risk._sensitive_tags("package-lock.json")
  assert(vim.tbl_contains(lock_tags, "sensitive"), "*.lock is tagged sensitive by default")
  local plain_tags = risk._sensitive_tags("src/util.lua")
  assert_eq(#plain_tags, 0, "plain source file is not tagged sensitive")

  -- Integration: score on a real session
  local diff = require("nvime.diff")
  local diff_state = require("nvime.state")
  diff_state.current_diff = nil
  diff_state.diffs = {
    active_by_bufnr = {},
    active_by_path = {},
    queue_by_path = {},
  }
  local risk_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(risk_buf, tmp .. "/risk-target.lua")
  vim.api.nvim_buf_set_lines(risk_buf, 0, -1, false, { "local a = 1" })
  vim.api.nvim_set_current_buf(risk_buf)
  local risk_response = table.concat({
    "RATIONALE: bug=trivial; patch=rename; why=safe.",
    "NVIME_DIFF",
    "```diff",
    "--- a/risk-target.lua",
    "+++ b/risk-target.lua",
    "@@ -1,1 +1,1 @@",
    "-local a = 1",
    "+local a = 2",
    "```",
  }, "\n")
  local risk_result = diff.start_session({
    bufnr = risk_buf,
    line1 = 1,
    line2 = 1,
    path = "risk-target.lua",
    source = "test",
  }, risk_response, "claude", "risk")
  assert(risk_result.session, "risk: session opened")
  local score = risk.score(risk_result.session)
  assert(score, "risk.score returns a table")
  assert_eq(score.lines_added, 1, "risk counts +1 line")
  assert_eq(score.lines_removed, 1, "risk counts −1 line")
  assert(score.level == "low" or score.level == "medium", "small clean diff is low or medium risk")

  -- Banner row renders
  local row = risk.banner_row(risk_result.session, function()
    return ""
  end)
  assert(row, "risk.banner_row returns a row")
  assert(row[1]:find("risk", 1, true), "banner row mentions risk")
end)();

(function()
  -- nvime.policy_rules — per-path policy gate.
  local policy_rules = require("nvime.policy_rules")

  -- Default rules block migrations/lockfiles/secrets even without a project
  -- policy file. The test setup does not write one, so defaults apply.
  local mig = policy_rules.evaluate("migrations/0001_init.sql", "edit")
  assert(not mig.allowed, "default policy: migrations blocked")
  assert(mig.require_human, "default policy: migrations require_human")

  local lock = policy_rules.evaluate("package-lock.json", "edit")
  assert(not lock.allowed, "default policy: lockfiles blocked")

  local secrets = policy_rules.evaluate("secrets/api.key", "ask")
  assert(not secrets.allowed, "default policy: secrets blocked even on ask")

  local clean = policy_rules.evaluate("src/util.lua", "edit")
  assert(clean.allowed, "default policy: clean source file allowed")

  -- Switch to a custom rule file with max_changed_lines + allow_lanes
  local policy_path = policy_rules.path()
  vim.fn.mkdir(vim.fn.fnamemodify(policy_path, ":h"), "p")
  vim.fn.writefile({
    "{",
    '  "version": 1,',
    '  "rules": [',
    '    { "match": "**/*.py", "max_changed_lines": 5, "allow_lanes": ["edit"] },',
    '    { "match": "fixed.py", "require_human": true }',
    "  ]",
    "}",
  }, policy_path)

  local py_small = policy_rules.evaluate("src/foo.py", "edit", { changed_lines = 3 })
  assert(py_small.allowed, "small py change under max_changed_lines is allowed")

  local py_big = policy_rules.evaluate("src/foo.py", "edit", { changed_lines = 50 })
  assert(not py_big.allowed, "large py change above max_changed_lines is blocked")

  local py_ask = policy_rules.evaluate("src/foo.py", "ask")
  assert(not py_ask.allowed, "ask lane not in allow_lanes is blocked")

  local fixed = policy_rules.evaluate("fixed.py", "edit")
  assert(not fixed.allowed, "more-specific require_human rule wins on tie")

  -- require_rationale_typed_by_user: the matched rule asks for a one-line
  -- justification at accept time, attached to the attribution entry.
  vim.fn.writefile({
    "{",
    '  "version": 1,',
    '  "rules": [',
    '    { "match": "rationale-required.lua", "require_rationale_typed_by_user": true }',
    "  ]",
    "}",
  }, policy_path)
  local rationale_eval = policy_rules.evaluate("rationale-required.lua", "accept")
  assert(
    rationale_eval.require_rationale_typed_by_user,
    "policy: require_rationale_typed_by_user surfaced in evaluate result"
  )

  local rationale_buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(rationale_buf, tmp .. "/rationale-required.lua")
  vim.api.nvim_buf_set_lines(rationale_buf, 0, -1, false, { "local x = 1" })
  vim.api.nvim_set_current_buf(rationale_buf)
  local rationale_diff = require("nvime.diff")
  rationale_diff.start_session(
    {
      bufnr = rationale_buf,
      line1 = 1,
      line2 = 1,
      path = "rationale-required.lua",
      source = "test",
    },
    "RATIONALE: test\nNVIME_DIFF\n```diff\n--- a/rationale-required.lua\n+++ b/rationale-required.lua\n@@ -1,1 +1,1 @@\n-local x = 1\n+local x = 2\n```",
    "claude",
    "rationale-required"
  )

  -- Without a typed rationale (non-interactive), accept refuses.
  vim.env.NVIME_NONINTERACTIVE = "1"
  rationale_diff.accept_all()
  assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(rationale_buf, 0, -1, false), "\n"),
    "local x = 1",
    "policy require_rationale: refuses accept without user rationale"
  )

  -- With opts.user_rationale supplied, accept succeeds and the attribution
  -- entry carries the typed rationale.
  rationale_diff.accept_all({ user_rationale = "intentional config bump" })
  assert_eq(
    table.concat(vim.api.nvim_buf_get_lines(rationale_buf, 0, -1, false), "\n"),
    "local x = 2",
    "policy require_rationale: accepts when user_rationale supplied"
  )
  vim.env.NVIME_NONINTERACTIVE = nil
  local attribution = require("nvime.attribution")
  local entries = attribution.for_file("rationale-required.lua") or {}
  local saw_typed = false
  for _, entry in ipairs(entries) do
    if entry.user_rationale == "intentional config bump" then
      saw_typed = true
      break
    end
  end
  assert(saw_typed, "policy require_rationale: attribution entry records user_rationale")

  -- Restore default behavior for downstream tests
  vim.fn.delete(policy_path)
end)();

(function()
  -- nvime.intent — local intent linter.
  local intent = require("nvime.intent")

  -- Vague: short
  local vague_short = intent.classify("fix it")
  assert_eq(vague_short.verdict, "vague", "very short intent is vague")

  -- Vague: phrase
  local vague_phrase = intent.classify("Please clean this up so it looks nicer")
  assert_eq(vague_phrase.verdict, "vague", "intent containing 'clean this up' is vague")

  -- Vague: only vague verbs, no concrete verb
  local vague_only = intent.classify("polish improve enhance optimize")
  assert_eq(vague_only.verdict, "vague", "only vague verbs is vague")

  -- Questionable: enough words but no concrete pair
  local questionable = intent.classify("does this look right to you")
  assert(questionable.verdict == "vague" or questionable.verdict == "questionable", "review-shaped intent is not ok")

  -- Ok: concrete verb + concrete object
  local ok_intent = intent.classify("rename foo() to bar() in users.py because the spec changed")
  assert_eq(ok_intent.verdict, "ok", "concrete verb + concrete object intent is ok")

  local ok_simple = intent.classify("add validation for the empty input case")
  assert_eq(ok_simple.verdict, "ok", "simple concrete intent is ok")

  -- Model classifier mode: heuristic still primary; model only consulted
  -- on `questionable`. Stub agents.run so we don't spawn a real provider.
  local agents_mod = require("nvime.agents")
  local original_run = agents_mod.run
  local agents_calls = 0
  local model_verdict_text = "VERDICT: ok\n"
  agents_mod.run = function(opts)
    agents_calls = agents_calls + 1
    vim.schedule(function()
      if opts.on_text then
        opts.on_text(model_verdict_text)
      end
      if opts.on_exit then
        opts.on_exit({ code = 0, signal = 0 })
      end
    end)
    return { kill = function() end }
  end
  require("nvime.state").config.intent.classifier = "model"

  local questionable_intent = "does this look right to you and the team"
  local model_result = intent.classify(questionable_intent)
  assert_eq(model_result.verdict, "ok", "model classifier promotes questionable → ok when model says so")
  assert(agents_calls >= 1, "model classifier actually invoked agents.run")

  -- Second call hits the cache, no extra agents.run invocation.
  local agents_calls_before = agents_calls
  local cached_result = intent.classify(questionable_intent)
  assert_eq(cached_result.verdict, "ok", "cached model verdict reused")
  assert_eq(agents_calls, agents_calls_before, "second classify hits cache, does not call agents.run")

  -- Vague is short-circuited by the heuristic — no model call.
  local vague_calls_before = agents_calls
  local vague_via_model = intent.classify("clean this up please")
  assert_eq(vague_via_model.verdict, "vague", "vague heuristic short-circuits model")
  assert_eq(agents_calls, vague_calls_before, "vague intent does not invoke the model")

  -- Restore
  agents_mod.run = original_run
  require("nvime.state").config.intent.classifier = "heuristic"
  -- Clean up intent cache so it doesn't survive into other test files
  local cache_root = require("nvime.git").root((vim.uv or vim.loop).cwd())
  if cache_root then
    pcall(vim.fn.delete, cache_root .. "/.nvime/intent-cache.json")
  end
end)();

(function()
  -- nvime.hooks + nvime.pr — commit hook installer and PR sidecar.
  -- The hook installer needs a real git directory; we set one up under
  -- `tmp` and chdir into it so git.root resolves.
  local repo = tmp .. "/hooks-repo"
  vim.fn.mkdir(repo, "p")
  local prior_cwd = vim.fn.getcwd()
  vim.fn.system({ "git", "init", "-q", repo })
  -- Earlier in this test file, the plan stale-session test monkey-patches
  -- nvime.git.root to always return tmp and never restores it. That makes
  -- every subsequent git.root call return tmp instead of the real repo.
  -- Reload the module to get a clean copy for hooks + pr tests.
  package.loaded["nvime.git"] = nil
  require("nvime.git").clear_root_cache()
  vim.fn.system({ "git", "-C", repo, "config", "user.email", "test@nvime" })
  vim.fn.system({ "git", "-C", repo, "config", "user.name", "test" })
  vim.fn.system({ "git", "-C", repo, "config", "commit.gpgSign", "false" })
  vim.api.nvim_set_current_dir(repo)
  require("nvime.audit").clear_cache()

  local hooks = require("nvime.hooks")

  -- Pre-install: not installed
  local status_before = hooks.status()
  assert(status_before.installed == false, "hooks: not installed before install")

  -- Install
  local ok_install, install_err = hooks.install()
  assert(ok_install, "hooks: install succeeds (" .. tostring(install_err) .. ")")
  local status_after = hooks.status()
  assert(status_after.installed == true, "hooks: status reports installed=true")
  assert(vim.fn.filereadable(repo .. "/.git/hooks/prepare-commit-msg") == 1, "hooks: prepare-commit-msg file exists")

  -- Reinstall is idempotent
  local ok_reinstall = hooks.install()
  assert(ok_reinstall, "hooks: reinstall succeeds")
  assert(hooks.status().installed, "hooks: still installed after reinstall")

  -- Chaining: write a user hook, install over it, ensure we save it as .nvime-prev
  hooks.uninstall()
  vim.fn.writefile({ "#!/usr/bin/env sh", "echo user-hook" }, repo .. "/.git/hooks/prepare-commit-msg")
  local ok_chain = hooks.install()
  assert(ok_chain, "hooks: install chains over a pre-existing hook")
  assert(
    vim.fn.filereadable(repo .. "/.git/hooks/prepare-commit-msg.nvime-prev") == 1,
    "hooks: previous hook moved aside"
  )
  local chain_status = hooks.status()
  assert(chain_status.chained == true, "hooks: status reports chained=true")

  -- Uninstall restores the previous hook
  hooks.uninstall()
  local restored = vim.fn.readfile(repo .. "/.git/hooks/prepare-commit-msg")
  assert(restored[2] == "echo user-hook", "hooks: uninstall restores the chained-prev hook")

  -- pr.render --dry-run on a repo with one commit; should not write a file.
  vim.fn.writefile({ "hello" }, repo .. "/README.md")
  vim.fn.system({ "git", "-C", repo, "add", "README.md" })
  vim.fn.system({ "git", "-C", repo, "commit", "-q", "-m", "init" })
  vim.fn.writefile({ "hello world" }, repo .. "/README.md")
  vim.fn.system({ "git", "-C", repo, "commit", "-aq", "-m", "more" })

  local pr = require("nvime.pr")
  local body, path = pr.render({ dry_run = true, base = "HEAD~1" })
  assert_eq(path, nil, "pr.render dry-run does not write")
  assert(type(body) == "string" and body:find("nvime PR sidecar", 1, true), "pr.render produces sidecar header")
  assert(body:find("README.md", 1, true), "pr.render lists changed file")

  vim.api.nvim_set_current_dir(prior_cwd)
end)();

(function()
  -- Wave 1: ledger integrity — fslock, schema versioning, audit rotation, and
  -- the verify/user-rationale provenance that accept used to discard.
  local fslock = require("nvime.fslock")
  local attribution = require("nvime.attribution")
  local schema = require("nvime.schema")
  local state = require("nvime.state")
  local uv = vim.uv or vim.loop

  -- fslock.atomic_write replaces the file and leaves no scratch behind.
  local awpath = tmp .. "/atomic.json"
  assert(fslock.atomic_write(awpath, vim.json.encode({ a = 1 }) .. "\n") == true, "fslock.atomic_write returns true")
  assert(
    vim.fn.filereadable(awpath .. ".tmp." .. vim.fn.getpid()) ~= 1,
    "fslock.atomic_write leaves no per-pid .tmp on success"
  )
  assert_eq(vim.json.decode(table.concat(vim.fn.readfile(awpath), "\n")).a, 1, "fslock.atomic_write content decodes")

  -- with_lock runs fn, returns its result, and cleans the lock file.
  local ran = false
  local r = fslock.with_lock(awpath, function()
    ran = true
    return "done"
  end)
  assert(ran and r == "done", "fslock.with_lock runs fn and returns its result")
  assert(vim.fn.filereadable(awpath .. ".lock") ~= 1, "fslock.with_lock removes its lock after running")

  -- A stale lock (old mtime) is stolen so a crashed holder can't wedge writes.
  local lp = awpath .. ".lock"
  vim.fn.writefile({ "99999 1" }, lp)
  local long_ago = os.time() - 3600
  uv.fs_utime(lp, long_ago, long_ago)
  assert_eq(
    fslock.with_lock(awpath, function()
      return "stole"
    end, { stale_seconds = 10 }),
    "stole",
    "fslock.with_lock steals a stale lock"
  )

  -- A fresh lock soft-fails (no hang, no corruption of the target).
  vim.fn.writefile({ tostring(vim.fn.getpid()) .. " " .. tostring(os.time()) }, lp)
  uv.fs_utime(lp, os.time(), os.time())
  local before = table.concat(vim.fn.readfile(awpath), "\n")
  local start = uv.hrtime()
  local res, err = fslock.with_lock(awpath, function()
    return fslock.atomic_write(awpath, "CLOBBERED")
  end, { stale_seconds = 600 })
  local elapsed_ms = (uv.hrtime() - start) / 1e6
  assert(res == nil and err == "locked", "fslock.with_lock soft-fails on a fresh lock")
  assert(elapsed_ms < 2000, "fslock.with_lock does not hang on contention")
  assert_eq(
    table.concat(vim.fn.readfile(awpath), "\n"),
    before,
    "fslock.with_lock leaves the target intact when locked"
  )
  vim.fn.delete(lp)

  -- #2: the pre-accept verify snapshot + user rationale persist and surface.
  local vpath = tmp .. "/verify-attribution.json"
  vim.fn.delete(vpath)
  state.config.attribution = { enabled = true, path = vpath, max = 500 }
  local stored = attribution.record({
    file = "z.lua",
    line1 = 1,
    line2 = 2,
    lines = { "alpha", "beta" },
    rationale = "fix the thing",
    user_rationale = "I read this and it is correct",
    verdict = { decision = "APPROVE", justification = "looks right" },
    verify = { status = "issues", parse_ok = true, forced = false, checks = { ruff = 2, mypy = 0 } },
    provider = "claude",
  })
  assert(stored, "attribution.record returns the stored entry")
  local vledger = vim.json.decode(table.concat(vim.fn.readfile(vpath), "\n"))
  local ve = vledger.entries[#vledger.entries]
  assert_eq(ve.verify.checks.ruff, 2, "attribution: verify check count persisted")
  assert_eq(ve.verify.parse_ok, true, "attribution: verify parse_ok persisted")
  assert_eq(ve.user_rationale, "I read this and it is correct", "attribution: user_rationale persisted")
  local blame = attribution._build_blame_lines("z.lua", 1, {
    vim.tbl_extend("keep", { match_line1 = 1, match_line2 = 2 }, ve),
  })
  local joined = table.concat(blame, "\n")
  assert(joined:find("user:", 1, true), "attribution: blame surfaces the user rationale")
  assert(joined:find("verify:", 1, true), "attribution: blame surfaces the verify summary")
  assert(joined:find("ruff 2", 1, true), "attribution: blame verify summary lists the ruff finding count")
  assert(
    attribution._verify_summary(nil) == nil,
    "attribution: absent verify renders as nil, not a fabricated clean bill"
  )
  local forced_sum = attribution._verify_summary({ status = "error", parse_ok = false, forced = true, checks = {} })
  assert(
    forced_sum:find("parse ERROR", 1, true) and forced_sum:find("forced", 1, true),
    "attribution: a gate-forced accept is annotated"
  )
  state.config.attribution = { enabled = true, path = nil, max = 500 }

  -- #4: schema reconcile never silently downgrades a newer ledger.
  schema._reset()
  local fv, is_future = schema.reconcile({ version = 999 }, 1, "test")
  assert(fv == 999 and is_future == true, "schema.reconcile flags + preserves a future version")
  local cv, is_cur = schema.reconcile({ version = 1 }, 1, "test")
  assert(cv == 1 and is_cur == false, "schema.reconcile normalizes the current version")
  assert((schema.reconcile({}, 1, "test")) == 1, "schema.reconcile treats an unversioned ledger as current")

  -- attribution refuses to rewrite a future-versioned ledger on disk.
  local future_ledger = tmp .. "/future-attribution.json"
  vim.fn.writefile(
    { vim.json.encode({ version = 999, entries = { { file = "x", note = "from-newer-nvime" } } }) },
    future_ledger
  )
  state.config.attribution = { enabled = true, path = future_ledger, max = 500 }
  attribution.record({ file = "y.lua", lines = { "a" }, rationale = "r", provider = "claude" })
  local after = vim.json.decode(table.concat(vim.fn.readfile(future_ledger), "\n"))
  assert_eq(after.version, 999, "attribution: future-versioned ledger left at v999 (not downgraded)")
  assert_eq(#after.entries, 1, "attribution: future-versioned ledger not appended to")
  assert_eq(after.entries[1].note, "from-newer-nvime", "attribution: future ledger contents preserved intact")
  state.config.attribution = { enabled = true, path = nil, max = 500 }

  -- #16: size-based audit rotation keeps one backup and bounds disk use.
  local saved_audit = state.config.audit
  local rotpath = tmp .. "/rotate-audit.jsonl"
  vim.fn.delete(rotpath)
  vim.fn.delete(rotpath .. ".1")
  state.audit_write_disabled = false
  state.config.audit = { enabled = true, path = rotpath, log_prompts = true, max_bytes = 200 }
  local audit = require("nvime.audit")
  for i = 1, 8 do
    audit.write({ event = "rotate_probe", i = i, pad = string.rep("x", 60) })
  end
  assert(vim.fn.filereadable(rotpath .. ".1") == 1, "audit: log rotates to .1 once it exceeds max_bytes")
  assert(vim.fn.getfsize(rotpath) < 4096, "audit: live log stays bounded after rotation")
  state.config.audit = saved_audit
  state.audit_write_disabled = false

  -- #1: real cross-process concurrency — 3 separate Neovim instances appending
  -- to one audit log produce every line intact (the lock prevents interleaving
  -- and lost appends). This is the corruption the whole module exists to stop.
  local cpath = tmp .. "/concurrent-audit.jsonl"
  vim.fn.delete(cpath)
  local child_lua = string.format(
    "require('nvime').setup({ audit = { path = %q, max_bytes = 0, log_prompts = true }, guard = { enabled = false } }) "
      .. "local a = require('nvime.audit') for i = 1, 15 do a.write({ event = 'concur', i = i }) end",
    cpath
  )
  local ok_spawn, procs = pcall(function()
    local handles = {}
    for _ = 1, 3 do
      handles[#handles + 1] = vim.system({
        vim.v.progpath,
        "--headless",
        "-u",
        "NONE",
        "-c",
        "set rtp^=" .. root,
        "-c",
        "lua " .. child_lua,
        "-c",
        "qa!",
      }, { text = true })
    end
    for _, h in ipairs(handles) do
      h:wait(30000)
    end
    return handles
  end)
  if ok_spawn and procs and vim.fn.filereadable(cpath) == 1 then
    local cl = vim.fn.readfile(cpath)
    assert_eq(#cl, 45, "fslock: 3 concurrent writers produce 45 audit lines (no lost appends)")
    local all_valid = true
    for _, line in ipairs(cl) do
      if not pcall(vim.json.decode, line) then
        all_valid = false
        break
      end
    end
    assert(all_valid, "fslock: every concurrent audit line is valid JSON (no interleaving)")
  else
    print("[nvime-test] SKIP: cross-process fslock concurrency test (could not spawn child Neovim)")
  end
end)();

(function()
  -- Wave 2: visible uncertainty — silent parser/diff ambiguity becomes a
  -- review event (banner / conflict / audit) instead of landing quietly.
  local shared = require("nvime.diff.shared")
  local parser = require("nvime.diff.parser")
  local hunkmeta = require("nvime.diff.hunkmeta")
  local risk = require("nvime.risk")
  local verify = require("nvime.verify")
  local diff = require("nvime.diff")
  local state = require("nvime.state")

  -- #7: deletion-context confidence (both leading + trailing).
  local del_session = { original_lines = { "A", "B", "DEL1", "DEL2", "C", "D" } }
  local del_block = { old_start = 3, old_count = 2, old_lines = { "DEL1", "DEL2" }, new_lines = {} }
  assert(
    shared.deletion_confidence(del_session, del_block, { "A", "B", "C", "D" }, 2) >= 0.7,
    "deletion_confidence: unique leading+trailing context scores high"
  )
  assert(
    shared.deletion_confidence(del_session, del_block, { "X", "Y", "C", "D" }, 2) < 0.7,
    "deletion_confidence: broken leading context lowers confidence"
  )
  assert_eq(
    shared.live_block_status(del_session, del_block, { "A", "B", "C", "D" }, 0),
    "accepted",
    "live_block_status: a confident deletion is accepted"
  )
  assert_eq(
    shared.live_block_status(del_session, del_block, { "X", "Y", "C", "D" }, 0),
    "conflict",
    "live_block_status: an ambiguous deletion escalates to conflict (not a silent accept)"
  )
  local eof_session = { original_lines = { "keep", "GONE" } }
  local eof_block = { old_start = 2, old_count = 1, old_lines = { "GONE" }, new_lines = {} }
  assert(
    shared.deletion_confidence(eof_session, eof_block, { "keep" }, 1) >= 0.7,
    "deletion_confidence: an end-of-file deletion still resolves confidently"
  )

  -- #9: hunk @@-count drift is recorded (apply still uses the corrected count).
  local drift_lines = { "@@ -1,1 +1,3 @@", "-old" }
  for i = 1, 10 do
    drift_lines[#drift_lines + 1] = "+new" .. i
  end
  local _, drift_hunks = parser.parse_hunks(drift_lines)
  assert_eq(drift_hunks[1].declared_new, 3, "hunk: declared_new preserved verbatim")
  assert_eq(drift_hunks[1].new_count, 10, "hunk: recount still corrects new_count for apply")
  assert(drift_hunks[1].count_divergence >= 7, "hunk: count_divergence computed")
  assert(
    hunkmeta.exceeds(drift_hunks[1].declared_new, drift_hunks[1].count_divergence),
    "hunk: drift exceeds tolerance"
  )
  local drift_row = hunkmeta.banner_row({ hunks = drift_hunks }, nil)
  assert(drift_row and drift_row[1]:find("count drift", 1, true), "hunk: banner row reports the drift")
  local _, ok_hunks = parser.parse_hunks({ "@@ -1,1 +1,3 @@", "-old", "+n1", "+n2", "+n3" })
  assert_eq(ok_hunks[1].count_divergence, 0, "hunk: matching counts show no divergence")
  assert(
    not hunkmeta.exceeds(ok_hunks[1].declared_new, ok_hunks[1].count_divergence),
    "hunk: in-tolerance is not flagged"
  )

  -- #3: anchor ambiguity primitives + an end-to-end non-unique unranged apply.
  assert_eq(#parser.locate_all_sequences({ "x", "a", "b", "a", "b", "y" }, { "a", "b" }), 2, "locate_all: finds both")
  local best, conf, cands = parser.anchor_matches({ "a", "b", "a", "b" }, { "a", "b" }, 3)
  assert(conf == "ambiguous" and cands and #cands == 2, "anchor_matches: flags >1 match as ambiguous")
  assert_eq(best, 3, "anchor_matches: picks the match nearest the recorded start")
  local ub, uconf = parser.anchor_matches({ "x", "a", "b", "y" }, { "a", "b" }, nil)
  assert(uconf == "unique" and ub == 2, "anchor_matches: a single match is unique")

  local abuf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(abuf, tmp .. "/anchor_target.lua")
  vim.api.nvim_buf_set_lines(
    abuf,
    0,
    -1,
    false,
    { "local x = 1", "dup_line", "local y = 2", "dup_line", "local z = 3" }
  )
  vim.api.nvim_set_current_buf(abuf)
  local anchor_before = vim.fn.filereadable(audit_path) == 1 and #vim.fn.readfile(audit_path) or 0
  local anchor_result = diff.start_session({
    bufnr = abuf,
    line1 = 1,
    line2 = 5,
    path = tmp .. "/anchor_target.lua",
    source = "test",
  }, table.concat({ "NVIME_DIFF", "```diff", "@@", "-dup_line", "+CHANGED", "```" }, "\n"), "claude", "anchor-test")
  assert(anchor_result.session, "anchor: session opened for ambiguous unranged diff")
  assert_eq(anchor_result.session.hunks[1].anchor_confidence, "ambiguous", "anchor: hunk flagged ambiguous")
  local saw_anchor_warning = false
  for _, w in ipairs(anchor_result.session.warnings or {}) do
    if w:find("anchor ambiguous", 1, true) then
      saw_anchor_warning = true
    end
  end
  assert(saw_anchor_warning, "anchor: ambiguity surfaced as a session warning (rides the SUSPICIOUS-PATCH banner)")
  local saw_anchor_audit = false
  for _, line in ipairs(vim.fn.readfile(audit_path)) do
    local ok_d, d = pcall(vim.json.decode, line)
    if ok_d and type(d) == "table" and d.event == "anchor_ambiguous" then
      saw_anchor_audit = true
    end
  end
  assert(saw_anchor_audit, "anchor: anchor_ambiguous audit event written")
  assert(anchor_before >= 0, "anchor: audit baseline captured")

  -- #13: risk why-explainer, verify per-tool breakdown, protocol-violation audit.
  local why = risk.explain_level({ level = "high", breaches = { "lines" }, lines_added = 150, lines_removed = 0 })
  assert(#why >= 1 and why[1]:find("threshold", 1, true), "risk.explain_level: explains the line breach with a ratio")

  local saved_verify = state.config.verify
  state.config.verify = vim.tbl_extend("force", {}, saved_verify or {}, { detail_in_banner = true })
  local vrows = verify.banner_rows({
    verify = {
      status = "issues",
      summary = "3 issues",
      findings = {
        { source = "ruff", message = "E501 line too long" },
        { source = "ruff", message = "E502 x" },
        { source = "shellcheck", message = "SC2086 y" },
      },
    },
  }, nil)
  local vtext = ""
  for _, row in ipairs(vrows) do
    vtext = vtext .. row[1] .. "\n"
  end
  assert(vtext:find("ruff 2", 1, true), "verify: per-tool breakdown lists the ruff finding count")
  state.config.verify = saved_verify

  local pbuf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(pbuf, tmp .. "/proto_target.lua")
  vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, { "local a = 1" })
  vim.api.nvim_set_current_buf(pbuf)
  local proto_before = vim.fn.filereadable(audit_path) == 1 and #vim.fn.readfile(audit_path) or 0
  local proto_result = diff.start_session({
    bufnr = pbuf,
    line1 = 1,
    line2 = 1,
    path = tmp .. "/proto_target.lua",
    source = "test",
  }, "NVIME_DIFF\n(no diff here)", "claude", "proto-test")
  assert_eq(proto_result.status, "no_change", "protocol: a malformed NVIME_DIFF yields no_change")
  assert(
    proto_result.message:find("PROTOCOL.md", 1, true),
    "protocol: the no_change message carries a PROTOCOL.md hint"
  )
  local saw_proto = false
  local proto_after = vim.fn.readfile(audit_path)
  for i = proto_before + 1, #proto_after do
    local ok_d, d = pcall(vim.json.decode, proto_after[i])
    if ok_d and type(d) == "table" and d.event == "protocol_violation" then
      saw_proto = true
    end
  end
  assert(saw_proto, "protocol: a malformed response writes a protocol_violation audit event")
end)();

(function()
  -- Wave 3: #19 attribution gutter age-awareness.
  local attribution = require("nvime.attribution")
  assert(attribution._relative_age(os.time() - 5) == "1m", "relative_age: floors sub-hour to >=1m")
  assert(attribution._relative_age(os.time() - 3 * 86400) == "3d", "relative_age: days")
  assert(attribution._relative_age(os.time() - 2 * 7 * 86400) == "2w", "relative_age: weeks")
  assert(attribution._relative_age(nil) == nil, "relative_age: nil ts → nil")

  -- Wave 3: #17 per-lane/daily cost budgets warn (advisory) when crossed.
  local usage = require("nvime.usage")
  local state = require("nvime.state")
  local saved_usage = state.config.usage
  state.config.usage = {
    enabled = true,
    path = tmp .. "/usage-budget.json",
    max_days = 90,
    statusline = false,
    rates = {},
    budgets = { daily_usd = 0.0001 },
  }
  usage._reset_budget_warnings()
  usage.reset()
  local notes = {}
  local orig_notify = vim.notify
  vim.notify = function(msg, ...)
    notes[#notes + 1] = tostring(msg)
    return orig_notify(msg, ...)
  end
  usage.record({
    lane = "edit",
    provider = "claude",
    sample = { input = 1000000, output = 0, model = "claude-opus-4-8" },
  })
  vim.wait(100, function()
    return #notes > 0
  end)
  vim.notify = orig_notify
  local saw_budget = false
  for _, m in ipairs(notes) do
    if m:find("budget", 1, true) then
      saw_budget = true
    end
  end
  assert(saw_budget, "#17: crossing a daily cost budget warns")
  state.config.usage = saved_usage

  -- Wave 3: pre-flight setup validation — keymap conflict detection (#8).
  -- Bind a user mapping where a fresh-prefix nvime install will land, force a
  -- re-setup onto that prefix, and assert nvime records that it clobbered it.
  local orig_prefix = (state.config.keys or {}).prefix or "<leader>n"
  vim.keymap.set("n", "<leader>Zc", "<Cmd>echo 'user-owned'<CR>", { silent = true })
  local cfg = vim.deepcopy(state.config)
  cfg.force = true
  cfg.keys = vim.tbl_extend("force", {}, state.config.keys or {}, { prefix = "<leader>Z" })
  require("nvime").setup(cfg)
  local found = false
  for _, c in ipairs(state.last_keymap_conflicts or {}) do
    if c.lhs == "<leader>Zc" then
      found = true
    end
  end
  assert(found, "#8: setup detects and records a clobbered user keymap")
  -- Restore the original prefix so later runs are unaffected.
  local restore = vim.deepcopy(state.config)
  restore.force = true
  restore.keys = vim.tbl_extend("force", {}, restore.keys or {}, { prefix = orig_prefix })
  require("nvime").setup(restore)
  pcall(vim.keymap.del, "n", "<leader>Zc")
end)();

(function()
  -- #20: content search across the session archive (chat + selection).
  local chats = require("nvime.chats")
  local chat = require("nvime.chat")
  local selection = require("nvime.selection")
  local orig_chat, orig_sel = chat.sessions, selection.sessions
  chat.sessions = function()
    return {
      {
        id = 7,
        title = "Auth refactor",
        updated_at = 200,
        history = { { role = "user", content = "how do we handle JWT refresh token rotation safely?" } },
      },
      {
        id = 8,
        title = "Docs pass",
        updated_at = 100,
        history = { { role = "assistant", content = "updated the README install section" } },
      },
    }
  end
  selection.sessions = function()
    return {}
  end
  local hits = chats.search("jwt refresh", { no_ui = true })
  local empty = chats.search("zzz-not-present-zzz", { no_ui = true })
  chat.sessions, selection.sessions = orig_chat, orig_sel
  assert(#hits == 1, "search: finds exactly the matching session")
  assert_eq(hits[1].id, 7, "search: returns the matching session id")
  assert(hits[1].snippet:find("refresh", 1, true), "search: result carries a snippet around the match")
  assert_eq(#empty, 0, "search: no matches for an absent term")
end)();

(function()
  -- #15: per-lane agent run timeout resolution (opt-in, lane override wins).
  local agents = require("nvime.agents")
  local state = require("nvime.state")
  local saved = state.config.agents
  state.config.agents = { timeout_ms = 5000, lane_timeouts = { edit = 120000 } }
  assert_eq(agents._resolve_timeout("edit"), 120000, "timeout: lane override wins")
  assert_eq(agents._resolve_timeout("review"), 5000, "timeout: falls back to the global timeout")
  state.config.agents = { timeout_ms = nil, lane_timeouts = {} }
  assert(agents._resolve_timeout("review") == nil, "timeout: unbounded by default")
  state.config.agents = { timeout_ms = 0, lane_timeouts = {} }
  assert(agents._resolve_timeout("review") == nil, "timeout: 0 disables (treated as unbounded)")
  state.config.agents = saved
end)();

(function()
  -- keyhelp: the shared, themed g? cheat-sheet overlay.
  local keyhelp = require("nvime.keyhelp")
  local state = require("nvime.state")

  keyhelp.close()
  assert(not keyhelp.is_open(), "keyhelp starts closed")

  local sections = {
    { heading = "Compose", rows = { { "i", "type in the prompt" }, { "<CR>", "send" } } },
    { heading = "Window", rows = { { "g?", "toggle this help" } } },
  }
  keyhelp.open({ title = "demo keys", sections = sections })
  assert(keyhelp.is_open(), "keyhelp.open shows the overlay")
  local kh = state.panels.keyhelp
  assert(kh and kh.bufnr and vim.api.nvim_buf_is_valid(kh.bufnr), "keyhelp tracks a live buffer")
  local body = table.concat(vim.api.nvim_buf_get_lines(kh.bufnr, 0, -1, false), "\n")
  assert(body:find("Compose", 1, true), "keyhelp renders the section heading")
  assert(body:find("type in the prompt", 1, true), "keyhelp renders the key description")
  assert(body:find("toggle this help", 1, true), "keyhelp renders every section")
  -- The overlay buffer is non-editable scratch chrome, not content to mutate.
  assert(vim.bo[kh.bufnr].modifiable == false, "keyhelp overlay is read-only")

  keyhelp.toggle({ title = "demo", sections = sections })
  assert(not keyhelp.is_open(), "keyhelp.toggle closes an open overlay")
  keyhelp.toggle({ title = "demo", sections = sections })
  assert(keyhelp.is_open(), "keyhelp.toggle reopens a closed overlay")
  keyhelp.close()
  assert(not keyhelp.is_open(), "keyhelp.close tears the overlay down")
  assert(state.panels.keyhelp == nil, "keyhelp clears its panel slot on close")
end)();

(function()
  -- The conversation panel (chat lane) advertises its keys via a buffer-local
  -- g? that opens the themed overlay — built from the same keymaps the panel
  -- binds, so the help can't drift from the bindings.
  local keyhelp = require("nvime.keyhelp")
  local state = require("nvime.state")
  keyhelp.close()

  local chat_buf = require("nvime.chat").open()
  local function buf_map(bufnr, lhs)
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(bufnr, "n")) do
      if m.lhs == lhs then
        return m
      end
    end
    return nil
  end

  local g_help = buf_map(chat_buf, "g?")
  assert(g_help and g_help.callback, "chat panel binds g? to a help callback")
  g_help.callback()
  assert(keyhelp.is_open(), "chat g? opens the keyhelp overlay")
  local chat_help = table.concat(vim.api.nvim_buf_get_lines(state.panels.keyhelp.bufnr, 0, -1, false), "\n")
  assert(chat_help:find("Compose", 1, true), "chat help shows the Compose section")
  assert(chat_help:find("cycle provider", 1, true), "chat help documents provider cycling")
  assert(chat_help:find("toggle this help", 1, true), "chat help documents g? itself")
  assert(not chat_help:find("ask ⇄ edit", 1, true), "chat (no mode toggle) omits the ask/edit row")
  g_help.callback()
  assert(not keyhelp.is_open(), "chat g? toggles the overlay closed")
  require("nvime.chat").close()

  -- The selection lane (ask/edit) adds the mode-toggle row to the same overlay.
  local sel_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(sel_buf, 0, -1, false, { "local x = 1" })
  require("nvime.selection").open({
    provider = "claude",
    mode = "ask",
    selection = { bufnr = sel_buf, line1 = 1, line2 = 1, path = "keyhelp-probe.lua", source = "test" },
    new_session = true,
  })
  local sel_panel = state.panels.selection
  local sel_help_map = buf_map(sel_panel.bufnr, "g?")
  assert(sel_help_map and sel_help_map.callback, "selection panel binds g? to a help callback")
  sel_help_map.callback()
  assert(keyhelp.is_open(), "selection g? opens the keyhelp overlay")
  local sel_help = table.concat(vim.api.nvim_buf_get_lines(state.panels.keyhelp.bufnr, 0, -1, false), "\n")
  assert(sel_help:find("ask ⇄ edit", 1, true), "selection help documents the ask/edit mode toggle")
  keyhelp.close()
  require("nvime.selection").close()
end)();
(function()
  -- Reasoning effort: claude --effort + codex model_reasoning_effort, plus the
  -- "ultracode" = xhigh effort + dynamic workflows mapping. (IIFE so these
  -- locals don't add to the main chunk, which is near Lua's 200-local cap.)
  local provider = require("nvime.provider")
  local agents = require("nvime.agents")
  state.config.providers = state.config.providers or {}
  state.config.providers.claude = state.config.providers.claude or { cmd = "claude" }
  state.config.providers.codex = state.config.providers.codex or { cmd = "codex" }
  state.config.provider = "claude"

  assert_eq(
    table.concat(provider.effort_levels("claude"), ","),
    "low,medium,high,xhigh,max,ultracode",
    "effort: claude levels include ultracode"
  )
  assert_eq(table.concat(provider.effort_levels("codex"), ","), "low,medium,high,xhigh", "effort: codex levels")

  provider.set_effort("xhigh", "claude")
  assert_eq(provider.current_effort("claude"), "xhigh", "effort: set/current round-trips")
  provider.set_effort("nonsense", "claude")
  assert_eq(provider.current_effort("claude"), "xhigh", "effort: invalid value rejected")
  provider.set_effort("ultra", "claude")
  assert_eq(provider.current_effort("claude"), "ultracode", "effort: 'ultra' aliases to ultracode")
  provider.set_effort(nil, "claude")
  assert(provider.current_effort("claude") == nil, "effort: nil clears to provider default")

  local function has_flag(args, flag, val)
    for i, a in ipairs(args) do
      if a == flag and (val == nil or args[i + 1] == val) then
        return true
      end
    end
    return false
  end

  state.config.providers.claude.reasoning_effort = "high"
  assert(
    has_flag(agents._claude_args(state.config.providers.claude, "plan", "hi", {}), "--effort", "high"),
    "effort: claude_args passes --effort high"
  )
  -- ultracode → --effort xhigh (the flag itself can't take "ultracode")
  state.config.providers.claude.reasoning_effort = "ultracode"
  local ua = agents._claude_args(state.config.providers.claude, "plan", "hi", {})
  assert(has_flag(ua, "--effort", "xhigh"), "effort: ultracode maps to --effort xhigh")
  assert(not has_flag(ua, "--effort", "ultracode"), "effort: ultracode never reaches the flag")
  state.config.providers.claude.reasoning_effort = nil
  assert(
    not has_flag(agents._claude_args(state.config.providers.claude, "plan", "hi", {}), "--effort"),
    "effort: claude_args omits --effort when unset"
  )

  state.config.providers.codex.reasoning_effort = "xhigh"
  local koargs = agents._codex_args(state.config.providers.codex, "plan", "hi", nil, {})
  local saw_codex = false
  for _, a in ipairs(koargs) do
    if type(a) == "string" and a:find('model_reasoning_effort="xhigh"', 1, true) then
      saw_codex = true
    end
  end
  assert(saw_codex, "effort: codex passes model_reasoning_effort")
  state.config.providers.codex.reasoning_effort = nil

  assert(vim.fn.exists(":NvimeEffort") == 2, "effort: :NvimeEffort command exists")
end)();
-- Plan-author prompt selection: the full ~8KB header only for a NEW conversation
-- (fresh author or re-plan); the lean follow-up only for a RESUMED conversational
-- update (gu). (IIFE: keep locals out of the main chunk's 200-local cap.)
(function()
  local plan = require("nvime.plan")
  local agents = require("nvime.agents")
  local pdir = vim.fn.tempname()
  vim.fn.mkdir(pdir .. "/0001-ps", "p")
  local fd = io.open(pdir .. "/0001-ps/plan.json", "w")
  fd:write(vim.json.encode({
    version = 1,
    id = "0001-ps",
    title = "PS",
    why = "x",
    created_at = os.time(),
    updated_at = os.time(),
    files_estimated = {},
    acceptance = {},
    author_provider_sessions = { claude = "sess-1" },
    steps = { { id = 1, intent = "a", file = "a.lua", range = "new", depends_on = {}, tests = {} } },
  }))
  fd:close()
  state.config.plan = state.config.plan or {}
  local saved_dir = state.config.plan.dir
  state.config.plan.dir = pdir
  state.plan.loaded = false
  state.plan.plans = nil

  -- The lean follow-up: no header, carries the user message + load-bearing rules.
  local lean = plan._build_refine_followup_prompt("change step 2", "0001-ps")
  assert(not lean:find("NVIME PLAN AUTHOR MODE", 1, true), "promptsel: lean prompt omits the full header")
  assert(lean:find("change step 2", 1, true), "promptsel: lean prompt carries the user message")
  assert(
    lean:find("range_anchor", 1, true) and lean:find("needs a test", 1, true),
    "promptsel: lean prompt keeps the load-bearing rules"
  )
  assert(#lean < 1500, "promptsel: lean prompt stays lean")

  local saved_run = agents.run
  local captured
  agents.run = function(o)
    captured = o.prompt
    vim.schedule(function()
      if o.on_exit then
        o.on_exit({ code = 0, nvime_synced_plan_files = { ".nvime/plans/0001-ps/plan.json" } })
      end
    end)
    return { kill = function() end }
  end
  local function fire(opts)
    captured = nil
    local d = false
    plan.create(vim.tbl_extend("force", {
      provider = "claude",
      on_stream = function() end,
      on_complete = function()
        d = true
      end,
    }, opts))
    vim.wait(2000, function()
      return d
    end)
    return captured or ""
  end
  local has_header = function(p)
    return p:find("NVIME PLAN AUTHOR MODE", 1, true) ~= nil
  end

  assert(has_header(fire({ intent = "new" })), "promptsel: a fresh plan gets the full header")
  local up = fire({ intent = "tweak it", refine_id = "0001-ps", conversational = true })
  assert(
    not has_header(up) and up:find("tweak it", 1, true),
    "promptsel: conversational resume (gu) gets the lean prompt"
  )
  assert(
    has_header(fire({ intent = "rewrite", refine_id = "0001-ps" })),
    "promptsel: re-plan (non-conversational) keeps the full header"
  )

  agents.run = saved_run
  state.plan.active_run = nil
  state.config.plan.dir = saved_dir
  state.plan.loaded = false
  state.plan.plans = nil
end)();
-- The update chat renders a CLEAN transcript: agent prose only (internal progress
-- + the NVIME_PLAN marker/JSON filtered out), a calm footer, no scary warning.
(function()
  local plan = require("nvime.plan")
  local agents = require("nvime.agents")
  local cdir = vim.fn.tempname()
  vim.fn.mkdir(cdir .. "/0001-cc", "p")
  local fd = io.open(cdir .. "/0001-cc/plan.json", "w")
  fd:write(vim.json.encode({
    version = 1,
    id = "0001-cc",
    title = "CC",
    why = "x",
    created_at = os.time(),
    updated_at = os.time(),
    files_estimated = {},
    acceptance = {},
    author_provider_sessions = { claude = "s1" },
    steps = { { id = 1, intent = "a", file = "a.lua", range = "new", depends_on = {}, tests = {} } },
  }))
  fd:close()
  local saved_dir = state.config.plan.dir
  state.config.plan.dir = cdir
  state.plan.loaded = false
  state.plan.plans = nil
  local saved_run = agents.run
  agents.run = function(o)
    vim.schedule(function()
      if o.on_progress then
        o.on_progress("[claude] session started\n")
      end
      if o.on_text then
        o.on_text('Here is my answer.\n\nNVIME_PLAN\n```json\n{"id":"0001-cc"}\n```\n')
      end
      if o.on_exit then
        o.on_exit({ code = 0, nvime_synced_plan_files = { ".nvime/plans/0001-cc/plan.json" } })
      end
    end)
    return { kill = function() end }
  end
  plan.update_chat("0001-cc")
  local cb
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local b = vim.api.nvim_win_get_buf(w)
    if
      vim.api.nvim_buf_get_name(b) == ""
      and table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n"):find("update plan", 1, true)
    then
      cb = b
    end
  end
  vim.bo[cb].modifiable = true
  vim.api.nvim_buf_set_lines(cb, -1, -1, false, { "make step 1 use a deque" })
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(cb, "n")) do
    if (m.lhs == "<C-S>" or m.lhs == "<C-s>") and m.callback then
      m.callback()
    end
  end
  vim.wait(2500)
  local txt = table.concat(vim.api.nvim_buf_get_lines(cb, 0, -1, false), "\n")
  assert(txt:find("Here is my answer", 1, true), "cleanchat: agent prose shown")
  assert(not txt:find("session started", 1, true), "cleanchat: internal progress filtered out")
  assert(not txt:find("NVIME_PLAN", 1, true) and not txt:find('"id"', 1, true), "cleanchat: marker + JSON stripped")
  assert(txt:find("updated the plan", 1, true), "cleanchat: calm updated footer")
  assert(not txt:find("try rephrasing", 1, true), "cleanchat: no scary warning")
  for _, m in ipairs(vim.api.nvim_buf_get_keymap(cb, "n")) do
    if m.lhs == "q" and m.callback then
      m.callback()
    end
  end
  agents.run = saved_run
  state.plan.active_run = nil
  state.config.plan.dir = saved_dir
  state.plan.loaded = false
  state.plan.plans = nil
end)()

print("nvime headless spec passed")
