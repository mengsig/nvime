local audit = require("nvime.audit")
local config = require("nvime.config")
local git = require("nvime.git")
local state = require("nvime.state")

local M = {}

local health = vim.health

local function report(name, ...)
  local fn = health[name] or health["report_" .. name]
  if fn then
    fn(...)
  end
end

local function audit_dir()
  local path = audit.path()
  return vim.fn.fnamemodify(path, ":h")
end

local function check_writable_dir(path)
  vim.fn.mkdir(path, "p")
  return vim.fn.isdirectory(path) == 1 and vim.fn.filewritable(path) == 2
end

local function ts_language_for(bufnr)
  local ft = vim.bo[bufnr].filetype
  if not ft or ft == "" then
    return nil
  end
  if vim.treesitter and vim.treesitter.language and vim.treesitter.language.get_lang then
    return vim.treesitter.language.get_lang(ft)
  end
  return ft
end

local function parser_available(lang)
  if not lang or lang == "" or not vim.treesitter or not vim.treesitter.language then
    return false
  end
  if vim.treesitter.language.add then
    return pcall(vim.treesitter.language.add, lang)
  end
  if vim.treesitter.language.require_language then
    return pcall(vim.treesitter.language.require_language, lang)
  end
  return false
end

local function parse_utc_ts(value)
  if type(value) ~= "string" then
    return nil
  end
  local year, month, day, hour, min, sec = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$")
  if not year then
    return nil
  end
  return os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(min),
    sec = tonumber(sec),
  })
end

local function recent_blocked_events(path)
  if vim.fn.filereadable(path) ~= 1 then
    return 0
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return 0
  end
  local cutoff = os.time() - 24 * 60 * 60
  local count = 0
  for _, line in ipairs(lines) do
    local decoded_ok, decoded = pcall(vim.json.decode, line)
    if decoded_ok and type(decoded) == "table" and decoded.event == "blocked" then
      local ts = parse_utc_ts(decoded.ts)
      if not ts or ts >= cutoff then
        count = count + 1
      end
    end
  end
  return count
end

function M.check()
  report("start", "nvime")

  if vim.fn.has("nvim-0.10") == 1 then
    report("ok", "Neovim version is 0.10 or newer")
  else
    report("error", "nvime requires Neovim 0.10 or newer")
  end

  local cfg = state.config or config.defaults
  for name, provider in pairs(cfg.providers or {}) do
    local cmd = provider and provider.cmd
    if type(cmd) == "string" and cmd ~= "" and vim.fn.executable(cmd) == 1 then
      report("ok", "provider `" .. name .. "` command found: " .. cmd)
    else
      report("warn", "provider `" .. name .. "` command is not executable: " .. tostring(cmd))
    end
  end

  local dir = audit_dir()
  if check_writable_dir(dir) then
    report("ok", "nvime state directory is writable: " .. dir)
  else
    report("error", "nvime state directory is not writable: " .. dir)
  end

  if cfg.guard and cfg.guard.enabled == false then
    report("warn", "guard is disabled by config")
  elseif state.disabled then
    report("warn", "nvime is disabled; run :NvimeEnable to restore wrappers")
  elseif state.guard_installed then
    report("ok", "guard wrappers are installed")
  else
    report("warn", "guard wrappers are not installed")
  end

  local checked = {}
  local missing = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local lang = ts_language_for(bufnr)
      if lang and not checked[lang] then
        checked[lang] = true
        if not parser_available(lang) then
          missing[#missing + 1] = lang
        end
      end
    end
  end
  if #missing == 0 then
    report("ok", "Tree-sitter parsers are available for loaded filetypes")
  else
    report("warn", "missing Tree-sitter parsers for loaded filetypes: " .. table.concat(missing, ", "))
  end

  local root = git.root()
  if root then
    report("info", "git root: " .. root)
  end

  local blocked = recent_blocked_events(audit.path())
  if blocked > 0 then
    report("warn", tostring(blocked) .. " blocked guard event(s) recorded in the last 24 hours")
  else
    report("ok", "no blocked guard events recorded in the last 24 hours")
  end
end

return M
