local M = {}

M.defaults = {
  provider = "claude",
  providers = {
    claude = {
      cmd = "claude",
    },
    codex = {
      cmd = "codex",
    },
  },
  ui = {
    layout = "float",
    side = "right",
    width = 82,
    height = 24,
    float_width = 0.82,
    float_height = 0.72,
    dashboard_width = 0.86,
    dashboard_height = 0.9,
    border = "rounded",
    backdrop = 60,
    completion = "notify",
    ascii_icons = false,
    icons = {},
    spinner_frames = nil,
  },
  audit = {
    enabled = true,
    path = nil,
    log_prompts = false,
  },
  guard = {
    enabled = true,
    strict = true,
    notify = true,
    wrap_vim_system = true,
    wrap_jobstart = true,
    wrap_termopen = true,
    wrap_system_functions = true,
    wrap_uv_spawn = true,
    kill_blocked_terminals = true,
    block_cmdline = true,
  },
  review = {
    allow_shell = true,
    allow_web = true,
    allow_markdown_writes = true,
  },
  selection = {
    allow_shell = true,
    allow_web = true,
  },
  edit = {
    context_lines = 0,
  },
  diff = {
    max_visual_block_lines = 12,
  },
  chat = {
    max_history_messages = 24,
  },
  sessions = {
    enabled = true,
    path = nil,
    chat_path = nil,
    max = 100,
  },
  keys = {
    enabled = true,
    prefix = "<leader>n",
    normal = {
      dashboard = "<Space>",
      chat = "c",
      review = "r",
      edit = "e",
      ask = "q",
      audit = "a",
      discuss = "d",
      diff = "v",
      last = "n",
      provider = "p",
    },
    visual = {
      edit = "e",
      ask = "q",
    },
  },
  prompts = {
    general = {
      {
        label = "Review repository",
        prompt = "Please review this repository for correctness, maintainability, and documentation drift. Run relevant read-only checks and summarize concrete findings.",
      },
      {
        label = "Update docs",
        prompt = "Please inspect the repository and ensure the Markdown documentation is accurate, complete, and easy for future agents to use.",
      },
      {
        label = "Explain architecture",
        prompt = "Please explain the repository architecture, important modules, data flow, and the safest places to make changes.",
      },
      {
        label = "Run tests",
        prompt = "Please run the relevant tests/checks, explain failures if any, and recommend the smallest next fix.",
      },
    },
    selection = {
      {
        label = "Review selection",
        prompt = "Please review this selection for correctness, maintainability, edge cases, and whether it fits the surrounding code.",
      },
      {
        label = "Explain selection",
        prompt = "Please explain what this selected code does and how it interacts with the rest of the repository.",
      },
      {
        label = "Suggest minimal diff",
        prompt = "Please suggest the smallest approvable diff for this selection, and avoid changing unrelated lines.",
      },
      {
        label = "Proceed with fix",
        prompt = "Please proceed with the concrete fix for this selection, keeping the change minimal and inside the selected range.",
      },
    },
  },
}

local function is_list(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" then
      return false
    end
    count = count + 1
  end
  return count == #value
end

local function merge(base, override)
  local out = vim.deepcopy(base)
  for key, value in pairs(override or {}) do
    if type(value) == "table" and type(out[key]) == "table" and not is_list(value) then
      out[key] = merge(out[key], value)
    else
      out[key] = value
    end
  end
  return out
end

function M.resolve(opts)
  return merge(M.defaults, opts or {})
end

return M
