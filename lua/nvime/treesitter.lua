local M = {}

local uv = vim.uv or vim.loop

local function is_valid_buf(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function systemlist(cmd)
  local ok, result = pcall(vim.fn.systemlist, cmd)
  if not ok then
    return {}
  end
  return result or {}
end

local function repo_root()
  local cwd = uv and uv.cwd and uv.cwd() or vim.fn.getcwd()
  local result = systemlist({ "git", "-C", cwd, "rev-parse", "--show-toplevel" })
  if vim.v.shell_error == 0 and result[1] and result[1] ~= "" then
    return vim.trim(result[1])
  end
  return cwd
end

local function normalize_path(path)
  if not path or path == "" then
    return nil
  end
  if path:sub(1, 1) == "/" then
    return vim.fn.fnamemodify(path, ":p")
  end
  local cwd_path = vim.fn.fnamemodify(path, ":p")
  if vim.fn.filereadable(cwd_path) == 1 then
    return cwd_path
  end
  local root = repo_root()
  if root and root ~= "" then
    local root_path = vim.fn.fnamemodify(root .. "/" .. path, ":p")
    if vim.fn.filereadable(root_path) == 1 then
      return root_path
    end
  end
  return cwd_path
end

local function buffer_for_path(path)
  local abs = normalize_path(path)
  if not abs then
    return nil
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      local name = vim.api.nvim_buf_get_name(bufnr)
      if name ~= "" and vim.fn.fnamemodify(name, ":p") == abs then
        return bufnr
      end
    end
  end
  if vim.fn.filereadable(abs) ~= 1 then
    return nil
  end
  local bufnr = vim.fn.bufadd(abs)
  vim.fn.bufload(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  return nil
end

function M.resolve_bufnr(range)
  if not range then
    return nil
  end
  if is_valid_buf(range.bufnr) then
    return range.bufnr
  end
  local bufnr = buffer_for_path(range.path)
  if bufnr then
    range.bufnr = bufnr
    return bufnr
  end
  range.bufnr = nil
  return nil
end

local function function_type(node_type)
  if not node_type then
    return false
  end
  if node_type == "call_expression" or node_type == "call" then
    return false
  end
  if node_type:find("function", 1, true) then
    return true
  end
  return vim.tbl_contains({
    "method_definition",
    "method_declaration",
    "function_item",
    "function_statement",
    "function_declaration",
    "function_definition",
    "arrow_function",
    "lambda_expression",
    "constructor_declaration",
  }, node_type)
end

function M.current_function(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1

  local ok = pcall(function()
    vim.treesitter.get_parser(bufnr):parse()
  end)
  if not ok then
    return nil, "Tree-sitter parser is not available for this buffer"
  end

  local node = vim.treesitter.get_node({
    bufnr = bufnr,
    pos = { row, col },
    ignore_injections = false,
  })

  while node do
    if function_type(node:type()) then
      local start_row, start_col, end_row, end_col = node:range()
      return {
        bufnr = bufnr,
        line1 = start_row + 1,
        col1 = start_col,
        line2 = end_row + 1,
        col2 = end_col,
        source = "treesitter",
        node_type = node:type(),
      }
    end
    node = node:parent()
  end

  return nil, "No function node found at cursor"
end

function M.range_from_command(opts)
  if opts and opts.range and opts.range > 0 then
    return {
      bufnr = vim.api.nvim_get_current_buf(),
      line1 = opts.line1,
      line2 = opts.line2,
      col1 = 0,
      col2 = 0,
      source = "range",
    }
  end
  return M.current_function(vim.api.nvim_get_current_buf())
end

function M.lines(range)
  local bufnr = M.resolve_bufnr(range)
  if not bufnr then
    return {}
  end
  local count = vim.api.nvim_buf_line_count(bufnr)
  local start_line = math.max(1, tonumber(range.line1) or 1)
  local end_line = math.max(start_line, tonumber(range.line2) or start_line)
  local start_idx = math.max(0, math.min(start_line - 1, count))
  local end_idx = math.max(start_idx, math.min(end_line, count))
  return vim.api.nvim_buf_get_lines(bufnr, start_idx, end_idx, false)
end

return M
