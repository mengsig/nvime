local agents = require("nvime.agents")
local chat = require("nvime.chat")

local M = {}

local function git_diff(args)
  local cmd = { "git", "-C", vim.loop.cwd(), "diff", "--no-ext-diff", "--no-color", "--find-renames", "--find-copies", "--unified=80" }
  vim.list_extend(cmd, args or {})
  return table.concat(vim.fn.systemlist(cmd), "\n")
end

function M.start(opts)
  opts = opts or {}
  local provider = opts.provider or require("nvime.state").config.provider
  local prompt = opts.prompt
  if not prompt or prompt == "" then
    prompt =
      "Review the current repository state. Be concrete, prioritize bugs and behavioral regressions. You may create or update Markdown documentation files only; do not edit source/config files."
  end

  local input = opts.input
  if not input and opts.diff ~= false then
    input = git_diff(opts.cached and { "--cached" } or {})
  end

  chat.open()
  chat.append("\n\n[" .. provider .. " review]$ " .. prompt .. "\n\n")
  chat.append("[" .. provider .. " response]\n" .. string.rep("-", 78) .. "\n\n")
  chat.set_busy(true)
  agents.run({
    provider = provider,
    lane = "review",
    prompt = prompt,
    input = input,
    on_text = function(text)
      chat.append(text)
    end,
    on_progress = function(text)
      chat.append(text)
    end,
    on_exit = function(result)
      chat.set_busy(false)
      local synced = result.nvime_synced_markdown or {}
      if #synced > 0 then
        vim.notify("nvime synced markdown: " .. table.concat(synced, ", "), vim.log.levels.INFO)
      end
      if result.code ~= 0 then
        chat.append("\n[nvime] review failed with code " .. tostring(result.code) .. "\n")
      end
    end,
  })
end

return M
