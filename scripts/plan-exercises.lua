-- nvime plan-mode exercise harness (headless).
--
-- Drives the FULL three-phase Plan flow end-to-end against a throwaway git repo:
--   phase 0 (plan given) → phase 1 scaffold (worktree) → phase 2 implement →
--   run the fixture's HIDDEN test against the produced code.
--
-- By default a deterministic MOCK agent writes each fixture's golden scaffold /
-- implementation, so the run is offline + reproducible and validates nvime's
-- orchestration (worktree, diff capture, block extraction, phase transitions,
-- review wiring). With NVIME_PLAN_LIVE=1 the real provider runs instead, so the
-- same fixtures measure model efficacy. The hidden test is injected only AFTER
-- the implement phase, so a live agent can't game it.
--
-- Run: scripts/plan-exercises   (mock)   |   NVIME_PLAN_LIVE=1 scripts/plan-exercises

local LIVE = vim.env.NVIME_PLAN_LIVE == "1"
local ONLY = vim.env.NVIME_PLAN_ONLY -- optional fixture id filter

local function sh(args)
  return vim.fn.system(args)
end

-- ---------------------------------------------------------------------------
-- Fixtures. Each: id, difficulty, intent (live author hint — the plan is given
-- here), plan (plan.json), seed (baseline files), scaffold/implement (golden
-- worktree contents for mock mode), test (hidden test file + runner).
-- ---------------------------------------------------------------------------
local FIXTURES = {
  {
    id = "0101-slugify",
    difficulty = "medium",
    intent = "Implement slugify(text): lowercase, replace any run of non-alphanumeric chars with a single '-', and trim leading/trailing '-'.",
    plan = {
      title = "slugify helper",
      why = "We need consistent slugs for filenames and anchors.",
      files_estimated = { "slug.lua" },
      acceptance = { { id = 1, text = "slug_test.lua passes", status = "pending" } },
      steps = {
        {
          id = 1,
          intent = "Implement slugify(text) per the rules",
          file = "slug.lua",
          range = "new",
          depends_on = {},
          tests = {},
        },
      },
    },
    seed = { ["slug.lua"] = { "local M = {}", "", "return M" } },
    scaffold = {
      ["slug.lua"] = {
        "local M = {}",
        "",
        "-- TODO(nvime): lowercase, replace non-alphanumeric runs with one '-', trim '-'.",
        "function M.slugify(text) end",
        "",
        "return M",
      },
    },
    implement = {
      ["slug.lua"] = {
        "local M = {}",
        "",
        "function M.slugify(text)",
        "  text = (text or ''):lower()",
        "  text = text:gsub('[^a-z0-9]+', '-')",
        "  text = text:gsub('^-+', ''):gsub('-+$', '')",
        "  return text",
        "end",
        "",
        "return M",
      },
    },
    test = {
      file = "slug_test.lua",
      runner = "luajit slug_test.lua",
      lines = {
        "package.path = './?.lua;' .. package.path",
        "local s = require('slug').slugify",
        "assert(s('Hello, World!') == 'hello-world', 'basic')",
        "assert(s('  A__B  ') == 'a-b', 'collapse + trim')",
        "assert(s('already-slug') == 'already-slug', 'idempotent-ish')",
        "assert(s('') == '', 'empty')",
        "assert(s('--Mixed @@ Case--') == 'mixed-case', 'edges')",
        "print('ok')",
      },
    },
  },
  {
    id = "0102-toposort",
    difficulty = "extreme",
    intent = "Implement toposort(graph): graph is a map node->list of deps. Return an ordered list (deps before dependents), or nil, 'cycle' if a cycle exists.",
    plan = {
      title = "topological sort with cycle detection",
      why = "Task scheduling needs a stable dependency order and must reject cycles.",
      files_estimated = { "topo.lua" },
      acceptance = { { id = 1, text = "topo_test.lua passes", status = "pending" } },
      steps = {
        {
          id = 1,
          intent = "Implement toposort(graph) with cycle detection (DFS or Kahn)",
          file = "topo.lua",
          range = "new",
          depends_on = {},
          tests = {},
        },
      },
    },
    seed = { ["topo.lua"] = { "local M = {}", "", "return M" } },
    scaffold = {
      ["topo.lua"] = {
        "local M = {}",
        "",
        "-- TODO(nvime): return deps-before-dependents order, or nil,'cycle' on a cycle.",
        "-- Visit each node; detect back-edges (node on the current DFS stack) as cycles.",
        "function M.toposort(graph) end",
        "",
        "return M",
      },
    },
    implement = {
      ["topo.lua"] = {
        "local M = {}",
        "",
        "function M.toposort(graph)",
        "  local order, state = {}, {} -- state: nil=unseen, 1=on-stack, 2=done",
        "  local nodes = {}",
        "  for n in pairs(graph) do nodes[#nodes + 1] = n end",
        "  table.sort(nodes)",
        "  local cycle = false",
        "  local function visit(n)",
        "    if state[n] == 2 then return end",
        "    if state[n] == 1 then cycle = true; return end",
        "    state[n] = 1",
        "    local deps = graph[n] or {}",
        "    local d = {}",
        "    for _, x in ipairs(deps) do d[#d + 1] = x end",
        "    table.sort(d)",
        "    for _, dep in ipairs(d) do visit(dep) end",
        "    state[n] = 2",
        "    order[#order + 1] = n",
        "  end",
        "  for _, n in ipairs(nodes) do visit(n) end",
        "  if cycle then return nil, 'cycle' end",
        "  return order",
        "end",
        "",
        "return M",
      },
    },
    test = {
      file = "topo_test.lua",
      runner = "luajit topo_test.lua",
      lines = {
        "package.path = './?.lua;' .. package.path",
        "local toposort = require('topo').toposort",
        "local function idx(t, v) for i, x in ipairs(t) do if x == v then return i end end end",
        "local o = toposort({ a = { 'b', 'c' }, b = { 'c' }, c = {} })",
        "assert(o, 'returns order')",
        "assert(idx(o, 'c') < idx(o, 'b') and idx(o, 'b') < idx(o, 'a'), 'deps first')",
        "assert(#o == 3, 'all nodes present')",
        "local _, err = toposort({ a = { 'b' }, b = { 'a' } })",
        "assert(err == 'cycle', 'detects cycle')",
        "assert(toposort({ x = {} })[1] == 'x', 'single node')",
        "print('ok')",
      },
    },
  },
  {
    id = "0103-intervals",
    difficulty = "extreme",
    intent = "Implement merge(intervals): intervals is a list of {lo, hi}. Return a new list of merged, sorted, non-overlapping intervals (touching intervals merge).",
    plan = {
      title = "merge overlapping intervals",
      why = "Calendar / range coalescing needs a canonical merged form.",
      files_estimated = { "intervals.lua" },
      acceptance = { { id = 1, text = "intervals_test.lua passes", status = "pending" } },
      steps = {
        {
          id = 1,
          intent = "Implement merge(intervals): sort by lo, fold overlapping/touching",
          file = "intervals.lua",
          range = "new",
          depends_on = {},
          tests = {},
        },
      },
    },
    seed = { ["intervals.lua"] = { "local M = {}", "", "return M" } },
    scaffold = {
      ["intervals.lua"] = {
        "local M = {}",
        "",
        "-- TODO(nvime): sort by lo; fold each interval into the last when it",
        "-- overlaps or touches (next.lo <= cur.hi), extending hi by max.",
        "function M.merge(intervals) end",
        "",
        "return M",
      },
    },
    implement = {
      ["intervals.lua"] = {
        "local M = {}",
        "",
        "function M.merge(intervals)",
        "  local xs = {}",
        "  for _, iv in ipairs(intervals or {}) do xs[#xs + 1] = { iv[1], iv[2] } end",
        "  table.sort(xs, function(a, b) return a[1] < b[1] end)",
        "  local out = {}",
        "  for _, iv in ipairs(xs) do",
        "    local last = out[#out]",
        "    if last and iv[1] <= last[2] then",
        "      if iv[2] > last[2] then last[2] = iv[2] end",
        "    else",
        "      out[#out + 1] = { iv[1], iv[2] }",
        "    end",
        "  end",
        "  return out",
        "end",
        "",
        "return M",
      },
    },
    test = {
      file = "intervals_test.lua",
      runner = "luajit intervals_test.lua",
      lines = {
        "package.path = './?.lua;' .. package.path",
        "local merge = require('intervals').merge",
        "local function eq(a, b)",
        "  if #a ~= #b then return false end",
        "  for i = 1, #a do if a[i][1] ~= b[i][1] or a[i][2] ~= b[i][2] then return false end end",
        "  return true",
        "end",
        "assert(eq(merge({ { 1, 3 }, { 2, 6 }, { 8, 10 } }), { { 1, 6 }, { 8, 10 } }), 'overlap')",
        "assert(eq(merge({ { 1, 4 }, { 4, 5 } }), { { 1, 5 } }), 'touching merges')",
        "assert(eq(merge({ { 5, 6 }, { 1, 2 } }), { { 1, 2 }, { 5, 6 } }), 'unsorted input')",
        "assert(eq(merge({}), {}), 'empty')",
        "assert(eq(merge({ { 1, 10 }, { 2, 3 } }), { { 1, 10 } }), 'nested')",
        "print('ok')",
      },
    },
  },
}

-- ---------------------------------------------------------------------------
-- harness
-- ---------------------------------------------------------------------------
require("nvime").setup({})
local state = require("nvime.state")
local store = require("nvime.bigchange.store")
local plan = require("nvime.plan")
local agents = require("nvime.agents")
local real_agents_run = agents.run

local function write_files(dir, files)
  for rel, lines in pairs(files) do
    vim.fn.mkdir(vim.fn.fnamemodify(dir .. "/" .. rel, ":h"), "p")
    vim.fn.writefile(lines, dir .. "/" .. rel)
  end
end

-- The mock agent: writes a fixture's golden scaffold / implementation into the
-- worktree based on which build prompt fired; grouping/other turns succeed with
-- no output (review falls back to per-file blocks).
local function install_mock(fixture)
  agents.run = function(opts)
    vim.schedule(function()
      local p = opts.prompt or ""
      if opts.cwd and p:find("SCAFFOLDING", 1, true) then
        write_files(opts.cwd, fixture.scaffold)
      elseif opts.cwd and p:find("IMPLEMENTING", 1, true) then
        write_files(opts.cwd, fixture.implement)
      end
      if opts.on_session_id then
        opts.on_session_id("mock-session")
      end
      if opts.on_exit then
        opts.on_exit({ code = 0, signal = 0 })
      end
    end)
    return { kill = function() end }
  end
end

local function wait_for(pred, ms)
  return vim.wait(ms or 15000, pred, 50)
end

local function run_fixture(fixture)
  local repo = vim.fn.tempname()
  vim.fn.mkdir(repo, "p")
  write_files(repo, fixture.seed)
  sh({ "git", "-C", repo, "init", "-q" })
  sh({ "git", "-C", repo, "config", "user.email", "t@t" })
  sh({ "git", "-C", repo, "config", "user.name", "t" })
  sh({ "git", "-C", repo, "add", "-A" })
  sh({ "git", "-C", repo, "commit", "-q", "-m", "baseline" })
  vim.cmd("cd " .. vim.fn.fnameescape(repo))

  -- Place the plan (phase 0 already authored) under a repo-local plan dir.
  local pdir = repo .. "/.nvime/plans"
  vim.fn.mkdir(pdir .. "/" .. fixture.id, "p")
  local pj = vim.deepcopy(fixture.plan)
  pj.version, pj.id, pj.created_at, pj.updated_at = 1, fixture.id, os.time(), os.time()
  local fd = io.open(pdir .. "/" .. fixture.id .. "/plan.json", "w")
  fd:write(vim.json.encode(pj))
  fd:close()
  state.config.plan = state.config.plan or {}
  state.config.plan.dir = pdir
  state.plan.loaded = false
  state.plan.plans = nil

  if not LIVE then
    install_mock(fixture)
  end

  -- Phase 0 → 1: agree + scaffold (drives worktree build + block extraction).
  plan._enter_scaffold(fixture.id)
  local p1 = plan.get(fixture.id)
  local ok1 = wait_for(function()
    local s = plan._linked_session(plan.get(fixture.id))
    return s and s.status == store.STATUS.REVIEW and s.blocks and #s.blocks > 0
  end)
  if not ok1 then
    return { id = fixture.id, phase = "scaffold", pass = false, detail = "scaffold build/extract did not reach review" }
  end

  -- Phase 1 → 2: implement at vibe (no understanding gate for the harness).
  plan._enter_implement(fixture.id, false)
  local ok2 = wait_for(function()
    local s = plan._linked_session(plan.get(fixture.id))
    return s and s.status == store.STATUS.REVIEW and s.blocks and #s.blocks > 0
  end)
  local session = plan._linked_session(plan.get(fixture.id))
  if not ok2 or not session or not session.worktree then
    return {
      id = fixture.id,
      phase = "implement",
      pass = false,
      detail = "implement build/extract did not reach review",
    }
  end

  -- Inject the HIDDEN test into the worktree and run it against the produced code.
  vim.fn.writefile(fixture.test.lines, session.worktree .. "/" .. fixture.test.file)
  local out = vim.fn.system("cd " .. vim.fn.shellescape(session.worktree) .. " && " .. fixture.test.runner .. " 2>&1")
  local code = vim.v.shell_error

  -- Clean up the worktree + session record so repeated runs stay tidy.
  pcall(function()
    require("nvime.bigchange").discard(session.id)
  end)

  return {
    id = fixture.id,
    difficulty = fixture.difficulty,
    pass = code == 0,
    detail = code == 0 and "hidden test passed" or ("hidden test FAILED:\n" .. vim.trim(out)),
    blocks = #session.blocks,
  }
end

-- ---------------------------------------------------------------------------
-- run
-- ---------------------------------------------------------------------------
io.write(string.format("\nnvime plan-exercises — mode=%s\n", LIVE and "LIVE" or "mock"))
io.write(string.rep("─", 64) .. "\n")
local results, passed = {}, 0
for _, fx in ipairs(FIXTURES) do
  if not ONLY or ONLY == fx.id then
    agents.run = real_agents_run
    local ok, res = pcall(run_fixture, fx)
    if not ok then
      res = { id = fx.id, pass = false, detail = "harness error: " .. tostring(res) }
    end
    results[#results + 1] = res
    if res.pass then
      passed = passed + 1
    end
    io.write(
      string.format(
        "  %s  %-14s [%-7s]  %s\n",
        res.pass and "PASS" or "FAIL",
        res.id,
        res.difficulty or "?",
        res.pass and ("blocks=" .. tostring(res.blocks)) or ""
      )
    )
    if not res.pass then
      io.write("        " .. tostring(res.detail):gsub("\n", "\n        ") .. "\n")
    end
  end
end
agents.run = real_agents_run
io.write(string.rep("─", 64) .. "\n")
io.write(string.format("  %d/%d fixtures passed\n\n", passed, #results))
vim.cmd(passed == #results and "qa!" or "cq")
