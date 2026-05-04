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
    border = "rounded",
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
    allow_markdown_writes = true,
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
  keys = {
    enabled = true,
    prefix = "<leader>n",
    normal = {
      chat = "c",
      review = "r",
      edit = "e",
      ask = "q",
      audit = "a",
      discuss = "d",
      provider = "p",
    },
    visual = {
      edit = "e",
      ask = "q",
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
