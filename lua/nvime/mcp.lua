-- nvime.mcp
--
-- Client-side MCP wiring. Synthesizes a Claude --mcp-config payload that
-- combines:
--   1. servers explicitly listed in `state.config.mcp.servers`
--   2. servers in `.nvime/mcp.json` (the same shape Claude expects, so
--      users can author it directly with `claude mcp add ...`)
--   3. nvime's own MCP server (when `state.config.mcp.expose_self` is true)
--
-- The merged config is written to a temp file per nvime session and the
-- path is passed to claude via --mcp-config. agents.lua keeps the existing
-- --strict-mcp-config so claude only ever sees servers we declared.

local git = require("nvime.git")
local state = require("nvime.state")

local M = {}

local uv = vim.uv or vim.loop
local cached_config_path
local cached_config_signature

local function cfg()
  return (state.config or {}).mcp or {}
end

local function repo_root()
  return git.root(uv.cwd()) or uv.cwd()
end

local function project_config_path()
  local override = cfg().config_path
  if override and override ~= "" then
    return vim.fn.fnamemodify(override, ":p")
  end
  return repo_root() .. "/.nvime/mcp.json"
end

-- ---------------------------------------------------------------------------
-- project-config trust gate
-- ---------------------------------------------------------------------------
-- A repo's own .nvime/mcp.json declares commands nvime would spawn as local
-- processes. Reviewing/planning over an UNTRUSTED repo is the headline use, so
-- a malicious repo could otherwise drive-by-execute its servers the moment the
-- user runs :NvimeReview / :NvimePlan / chat. Treat the repo as untrusted:
-- require an explicit, persisted, per-(repo, content) approval before honoring
-- those servers, and fail closed when we can't ask. `state.config.mcp.servers`
-- (the user's own config) is always trusted; only the project file is gated.
local function trust_store_path()
  return vim.fn.stdpath("data") .. "/nvime/mcp_trust.json"
end

local function load_trust()
  local ok, raw = pcall(vim.fn.readfile, trust_store_path())
  if ok and type(raw) == "table" and #raw > 0 then
    local dok, decoded = pcall(vim.json.decode, table.concat(raw, "\n"))
    if dok and type(decoded) == "table" then
      return decoded
    end
  end
  return {}
end

local function save_trust(store)
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(trust_store_path(), ":h"), "p")
  local fd = io.open(trust_store_path(), "w")
  if not fd then
    return
  end
  fd:write(vim.json.encode(store))
  fd:write("\n")
  pcall(function()
    fd:close()
  end)
end

-- Interactive prompting is only safe with a UI and outside a fast event. In a
-- headless run (e.g. nvime's own MCP self-server) we fail closed.
local function can_prompt()
  return not vim.in_fast_event() and #vim.api.nvim_list_uis() > 0
end

local function describe_servers(servers)
  local lines = {}
  for name, entry in pairs(servers) do
    local cmd = entry.command or entry.url or "(no command)"
    if type(entry.args) == "table" and #entry.args > 0 then
      cmd = cmd .. " " .. table.concat(entry.args, " ")
    end
    lines[#lines + 1] = string.format("  • %s: %s", name, cmd)
  end
  table.sort(lines)
  return lines
end

-- Returns true when the project-declared servers may be spawned.
local function ensure_project_trust(path, content, servers)
  local c = cfg()
  if c.project_config == false then
    return false -- project file disabled entirely
  end
  if c.trust_project_config == true then
    return true -- user opted to trust every repo
  end
  local root = repo_root()
  local sig = vim.fn.sha256(content)
  local store = load_trust()
  local entry = store[root]
  if entry and entry.signature == sig then
    return entry.approved == true -- remembered decision for this exact content
  end
  if not can_prompt() then
    vim.schedule(function()
      vim.notify(
        "nvime mcp: ignoring untrusted project MCP servers in "
          .. path
          .. " (open this repo interactively to review and trust them)",
        vim.log.levels.WARN
      )
    end)
    return false
  end
  local msg = table.concat({
    "This repository's " .. path,
    "declares MCP server commands that nvime would run as local processes with your privileges:",
    "",
    table.concat(describe_servers(servers), "\n"),
    "",
    "Only trust them if you trust this repository. Run these servers?",
  }, "\n")
  local choice = vim.fn.confirm(msg, "&No, skip them\n&Yes, trust this repo", 1, "Question")
  local approved = choice == 2
  store[root] = { signature = sig, approved = approved, path = path }
  save_trust(store)
  if not approved then
    vim.schedule(function()
      vim.notify("nvime mcp: project MCP servers not trusted; skipping them", vim.log.levels.INFO)
    end)
  end
  return approved
end

-- Cache (path, mtime, size) → parsed servers. agents.lua calls servers()
-- twice per spawn (once for claude, once for codex); without this we'd
-- readfile + JSON-decode the project config twice per turn. The cached value
-- already reflects the trust decision, so a declined repo is not re-prompted.
local cached_project_key
local cached_project_servers

local function read_project_servers()
  local path = project_config_path()
  local stat = uv.fs_stat(path)
  if not stat then
    cached_project_key = nil
    cached_project_servers = nil
    return {}
  end
  local key = string.format("%s\0%d\0%d", path, stat.mtime.sec or 0, stat.size or 0)
  if cached_project_key == key and cached_project_servers then
    return cached_project_servers
  end
  local ok, raw = pcall(vim.fn.readfile, path)
  if not ok or not raw or #raw == 0 then
    return {}
  end
  local content = table.concat(raw, "\n")
  local decoded_ok, decoded = pcall(vim.json.decode, content)
  if not decoded_ok or type(decoded) ~= "table" then
    return {}
  end
  local servers = decoded.mcpServers or decoded.servers or {}
  if vim.tbl_isempty(servers) then
    cached_project_key, cached_project_servers = key, {}
    return {}
  end
  -- Gate the untrusted project-declared servers before exposing them to a spawn.
  if not ensure_project_trust(path, content, servers) then
    cached_project_key, cached_project_servers = key, {}
    return {}
  end
  cached_project_key = key
  cached_project_servers = servers
  return servers
end

-- The nvime-self entry. nvim --headless's startup is a few hundred ms
-- which is fine for MCP servers (claude pings them lazily). The cwd is
-- inherited so the server sees the same .nvime/ data.
local function self_server_entry()
  if not cfg().expose_self then
    return nil
  end
  local custom = cfg().self_command
  if custom and type(custom) == "table" and custom.command then
    -- Don't mutate the user's config in place; layer our default on top.
    return vim.tbl_extend("keep", { type = "stdio" }, custom)
  end
  if type(custom) == "string" and custom ~= "" then
    return { type = "stdio", command = "sh", args = { "-lc", custom } }
  end
  -- Default invocation. Strict-mode startup so user config can't override.
  -- The two paths the headless server needs are different:
  --   1. plugin_root  — where nvime itself lives (so `require('nvime.*')`
  --      resolves under --clean, which strips the user's RTP).
  --   2. project_root — the user's project, so the server can locate
  --      .nvime/. The host (claude/codex) often spawns the server in a
  --      transient scratch cwd, so we pass it via env, not via cwd.
  local nvim_bin = vim.v.progpath or "nvim"
  local plugin_path = vim.api.nvim_get_runtime_file("lua/nvime/mcp_server.lua", false)[1]
  local plugin_root = plugin_path and vim.fn.fnamemodify(plugin_path, ":h:h:h") or repo_root()
  local project_root = repo_root()
  return {
    type = "stdio",
    command = nvim_bin,
    args = {
      "--headless",
      "--clean",
      "--cmd",
      "set rtp+=" .. plugin_root,
      "--cmd",
      "lua require('nvime.mcp_server').run()",
    },
    env = { NVIME_REPO_ROOT = project_root },
  }
end

-- Build the merged Claude mcp-config object.
function M.build_config()
  local servers = {}
  for name, entry in pairs(cfg().servers or {}) do
    servers[name] = entry
  end
  for name, entry in pairs(read_project_servers()) do
    servers[name] = entry
  end
  local self_entry = self_server_entry()
  if self_entry then
    servers["nvime"] = self_entry
  end
  return { mcpServers = servers }
end

local function write_config(path, payload)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local fd, err = io.open(path, "w")
  if not fd then
    return false, err
  end
  fd:write(vim.json.encode(payload))
  fd:write("\n")
  pcall(function()
    fd:close()
  end)
  return true
end

-- Materialize the merged config to a stable file under stdpath('cache').
-- We rebuild only when the config has changed (signature compare) so
-- claude's --mcp-config keeps a stable path between runs.
function M.config_path()
  if cfg().enabled == false then
    return nil
  end
  local payload = M.build_config()
  if vim.tbl_isempty(payload.mcpServers) then
    return nil
  end
  local signature = vim.inspect(payload)
  if cached_config_path and cached_config_signature == signature and vim.fn.filereadable(cached_config_path) == 1 then
    return cached_config_path
  end
  local cache_root = vim.fn.stdpath("cache") .. "/nvime/mcp"
  vim.fn.mkdir(cache_root, "p")
  local path = cache_root .. "/merged.json"
  local ok, err = write_config(path, payload)
  if not ok then
    vim.schedule(function()
      vim.notify("nvime mcp: could not write merged config: " .. tostring(err), vim.log.levels.WARN)
    end)
    return nil
  end
  cached_config_path = path
  cached_config_signature = signature
  return path
end

function M.servers()
  return M.build_config().mcpServers
end

function M.project_config_path()
  return project_config_path()
end

return M
