local git = require("nvime.git")

local M = {}

local function is_valid_buf(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function repo_root()
  local cwd = (vim.uv or vim.loop).cwd()
  return git.root(cwd) or cwd
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

-- Maps tree-sitter node types to a short symbol "kind". The kind set is
-- intentionally coarse — agents use it to filter the symbol list, not to
-- reason about language semantics. Anything not in the table is skipped.
local SYMBOL_KIND = {
  -- functions / methods (most languages)
  function_declaration = "function",
  function_definition = "function",
  function_item = "function",
  function_statement = "function",
  function_specifier = "function",
  method_declaration = "method",
  method_definition = "method",
  arrow_function = "function",
  lambda_expression = "function",
  constructor_declaration = "method",
  -- types / structures
  class_declaration = "class",
  class_definition = "class",
  class_specifier = "class",
  struct_item = "struct",
  struct_specifier = "struct",
  struct_definition = "struct",
  enum_item = "enum",
  enum_declaration = "enum",
  enum_specifier = "enum",
  union_specifier = "union",
  trait_item = "trait",
  interface_declaration = "interface",
  type_alias = "typealias",
  type_alias_declaration = "typealias",
  type_definition = "typealias",
  -- modules / namespaces
  module = "module",
  module_declaration = "module",
  namespace_definition = "namespace",
  namespace_declaration = "namespace",
  package_declaration = "package",
}

local NAME_FIELD_CANDIDATES = { "name", "declarator" }

-- Some Tree-sitter grammars wrap the name in a deeper node (e.g. C/C++
-- function_declarator → identifier). Walk down through these wrapper
-- types to reach the actual leaf identifier.
local NAME_UNWRAP_TYPES = {
  function_declarator = true,
  init_declarator = true,
  pointer_declarator = true,
  reference_declarator = true,
  identifier_pattern = true,
  scoped_identifier = true,
  qualified_identifier = true,
}

local function node_text(node, bufnr)
  if not node or not bufnr then
    return nil
  end
  local ok, text = pcall(vim.treesitter.get_node_text, node, bufnr)
  if not ok or type(text) ~= "string" then
    return nil
  end
  return text
end

local UNWRAP_MAX_DEPTH = 8

local function unwrap_to_identifier(node)
  if not node then
    return nil
  end
  local current = node
  for _ = 1, UNWRAP_MAX_DEPTH do
    if not NAME_UNWRAP_TYPES[current:type()] then
      return current
    end
    local inner = current:field("declarator")
    local next_node
    if inner and inner[1] then
      next_node = inner[1]
    else
      next_node = current:named_child(0)
    end
    if not next_node or next_node == current then
      return current
    end
    current = next_node
  end
  return current
end

local function find_name(node, bufnr)
  if not node then
    return nil
  end
  for _, field in ipairs(NAME_FIELD_CANDIDATES) do
    local ok, candidates = pcall(node.field, node, field)
    if ok and candidates and candidates[1] then
      local text = node_text(unwrap_to_identifier(candidates[1]), bufnr)
      if text and text ~= "" then
        return text
      end
    end
  end
  for child in node:iter_children() do
    local t = child:type()
    if t == "identifier" or t == "name" then
      local text = node_text(child, bufnr)
      if text and text ~= "" then
        return text
      end
    end
  end
  return nil
end

-- Walk the parse tree and emit a list of definition-like symbols. Each
-- entry has { kind, name, line_start, line_end, parent }. Parent is the
-- enclosing definition's name (or nil at the top level).
--
-- Returns nil + error string when the buffer has no Tree-sitter parser
-- (which is the common case for languages whose parser is not in the
-- runtime path of the hosting nvim — e.g. the MCP server's --clean
-- subprocess only ships nvim's builtin parsers).
function M.walk_symbols(bufnr)
  if not is_valid_buf(bufnr) then
    return nil, "invalid buffer"
  end
  local parser_ok, parser = pcall(vim.treesitter.get_parser, bufnr)
  if not parser_ok or not parser then
    return nil, "no tree-sitter parser for this buffer"
  end
  local parse_ok = pcall(function()
    parser:parse()
  end)
  if not parse_ok then
    return nil, "tree-sitter parse failed"
  end
  local trees = parser:trees()
  if not trees or not trees[1] then
    return {}
  end
  local root = trees[1]:root()
  local out = {}
  local function visit(node, parent_name)
    local kind = SYMBOL_KIND[node:type()]
    local emitted_parent = parent_name
    if kind then
      local name = find_name(node, bufnr) or "<anonymous>"
      local sr, _, er = node:range()
      out[#out + 1] = {
        kind = kind,
        name = name,
        line_start = sr + 1,
        line_end = er + 1,
        parent = parent_name,
      }
      emitted_parent = parent_name and (parent_name .. "." .. name) or name
    end
    for child in node:iter_children() do
      visit(child, emitted_parent)
    end
  end
  visit(root, nil)
  return out
end

return M
