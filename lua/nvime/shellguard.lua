-- nvime.shellguard
--
-- Editor-discipline guard for the agents' Bash surface. Materializes a
-- directory of POSIX shell wrappers under stdpath('cache')/nvime/shellguard/bin
-- and prepends it to PATH for spawned agents. Wrappers reject destructive
-- subcommands/flags before re-exec'ing the real binary via NVIME_GUARD_REAL_PATH
-- (which strips the guard dir back out of PATH so the wrappers don't recurse).
--
-- Scope is deliberately narrow and matches the project's contract: prevent an
-- agent from mutating the repo/working tree behind your back (git history,
-- recursive force-deletes). It is NOT a security sandbox — it does not police
-- system binaries like mkfs/dd/sudo. The README is explicit that nvime cannot
-- stop a renamed binary, an external terminal, or a hostile plugin, so a PATH
-- shim over those tools would be theater, not protection.

local M = {}

local uv = vim.uv or vim.loop

local BLOCKED_GIT = {
  "commit",
  "push",
  "pull",
  "fetch",
  "reset",
  "rebase",
  "merge",
  "revert",
  "tag",
  "clean",
  "checkout",
  "switch",
  "restore",
  "remote",
  "config",
  "apply",
  "am",
  "cherry-pick",
  "init",
  "submodule",
  "worktree",
  "filter-branch",
  "filter-repo",
  "gc",
  "prune",
  "repack",
  "update-ref",
  "symbolic-ref",
  "fast-import",
  "fast-export",
}

local BRANCH_DELETE_FLAGS = { "-d", "-D", "--delete" }
local STASH_DESTRUCTIVE = { "drop", "clear", "pop" }

local GIT_WRAPPER = [==[#!/usr/bin/env bash
set -u
blocked=(__BLOCKED__)
value_flags=' -C -c --git-dir --work-tree --namespace --super-prefix --exec-path '
is_value_flag() {
  case "$value_flags" in *" $1 "*) return 0 ;; esac
  return 1
}

sub=""
sub_args=()
i=1
while [ $i -le $# ]; do
  arg="${!i}"
  if [ -z "$sub" ]; then
    case "$arg" in
      --) i=$((i+1)); continue ;;
      *=*) i=$((i+1)); continue ;;
      -*)
        if is_value_flag "$arg"; then i=$((i+2)); else i=$((i+1)); fi
        continue ;;
      *) sub="$arg"; i=$((i+1));;
    esac
  else
    sub_args+=("$arg")
    i=$((i+1))
  fi
done

for b in "${blocked[@]}"; do
  if [ "$sub" = "$b" ]; then
    printf 'nvime shellguard blocked: git %s\n' "$sub" >&2
    exit 126
  fi
done

if [ "$sub" = "branch" ] && [ "${#sub_args[@]}" -gt 0 ]; then
  for arg in "${sub_args[@]}"; do
    case "$arg" in
      -d|-D|--delete|--delete-force)
        printf 'nvime shellguard blocked: git branch %s\n' "$arg" >&2; exit 126 ;;
    esac
  done
fi

if [ "$sub" = "stash" ]; then
  case "${sub_args[0]:-}" in
    drop|clear|pop)
      printf 'nvime shellguard blocked: git stash %s\n' "${sub_args[0]}" >&2; exit 126 ;;
  esac
fi

if [ "$sub" = "notes" ]; then
  case "${sub_args[0]:-}" in
    add|append|copy|edit|merge|prune|remove)
      printf 'nvime shellguard blocked: git notes %s\n' "${sub_args[0]}" >&2; exit 126 ;;
  esac
fi

PATH="${NVIME_GUARD_REAL_PATH:-$PATH}" exec git "$@"
]==]

local RM_WRAPPER = [==[#!/usr/bin/env bash
# Block recursive+force deletions only; ordinary file removal is allowed.
set -u
rec=0
force=0
for arg in "$@"; do
  case "$arg" in
    --) break ;;
    --recursive|-R|-r) rec=1 ;;
    --force|-f) force=1 ;;
    -*)
      stripped="${arg#-}"
      case "$stripped" in *r*|*R*) rec=1 ;; esac
      case "$stripped" in *f*) force=1 ;; esac
      ;;
  esac
done
if [ "$rec" -eq 1 ] && [ "$force" -eq 1 ]; then
  printf 'nvime shellguard blocked: rm -rf\n' >&2
  exit 126
fi
PATH="${NVIME_GUARD_REAL_PATH:-$PATH}" exec rm "$@"
]==]

local cached_dir
local cached_real_path
local cached_base_env
local cached_disallow_patterns
local scripts_written = false

local function script_dir()
  if cached_dir and vim.fn.isdirectory(cached_dir) == 1 and vim.fn.filewritable(cached_dir) == 2 then
    return cached_dir
  end

  local function writable_dir(root)
    local dir = root .. "/nvime/shellguard/bin"
    local ok = pcall(vim.fn.mkdir, dir, "p")
    if ok and vim.fn.isdirectory(dir) == 1 and vim.fn.filewritable(dir) == 2 then
      return dir
    end
    return nil
  end

  local dir = writable_dir(vim.fn.stdpath("cache")) or writable_dir(vim.fn.tempname())
  if not dir then
    error("nvime shellguard could not create a writable wrapper directory")
  end

  cached_dir = dir
  scripts_written = false
  return cached_dir
end

local function write_script(path, body)
  local fd, err = io.open(path, "w")
  if not fd then
    error("nvime shellguard could not open " .. path .. ": " .. tostring(err))
  end
  fd:write(body)
  fd:close()
  pcall(uv.fs_chmod, path, tonumber("755", 8))
end

local function quoted_git_blocklist()
  local parts = {}
  for _, item in ipairs(BLOCKED_GIT) do
    parts[#parts + 1] = vim.fn.shellescape(item)
  end
  return table.concat(parts, " ")
end

local function ensure_scripts(dir)
  local git_body = (GIT_WRAPPER:gsub("__BLOCKED__", quoted_git_blocklist()))
  write_script(dir .. "/git", git_body)
  write_script(dir .. "/rm", RM_WRAPPER)
end

local function compute_real_path()
  if not cached_real_path then
    cached_real_path = vim.env.PATH or "/usr/bin:/bin"
  end
  return cached_real_path
end

function M.ensure()
  local dir = script_dir()
  if not scripts_written then
    ensure_scripts(dir)
    scripts_written = true
  end
  return dir
end

function M.build_env(base)
  if not base and not cached_base_env then
    cached_base_env = vim.fn.environ()
  end
  local env = vim.tbl_extend("force", {}, base or cached_base_env)
  local guard_dir = M.ensure()
  local real_path = compute_real_path()
  env.NVIME_GUARD_REAL_PATH = real_path
  env.PATH = guard_dir .. ":" .. (env.PATH or real_path)
  return env
end

local function build_disallow_patterns()
  local patterns = {}
  for _, sub in ipairs(BLOCKED_GIT) do
    patterns[#patterns + 1] = "Bash(git " .. sub .. ":*)"
  end
  for _, flag in ipairs(BRANCH_DELETE_FLAGS) do
    patterns[#patterns + 1] = "Bash(git branch " .. flag .. ":*)"
  end
  for _, sub in ipairs(STASH_DESTRUCTIVE) do
    patterns[#patterns + 1] = "Bash(git stash " .. sub .. ":*)"
  end
  for _, shape in ipairs({ "rm -rf", "rm -fr", "rm -Rf", "rm -fR" }) do
    patterns[#patterns + 1] = "Bash(" .. shape .. ":*)"
  end
  return table.concat(patterns, ",")
end

-- Comma-joined Bash() patterns that mirror the wrappers. Suitable to feed
-- into Claude's --disallowedTools so the agent gets a tool-boundary refusal
-- instead of an exec-time failure. Memoized; the inputs are static.
function M.claude_disallow_patterns()
  if not cached_disallow_patterns then
    cached_disallow_patterns = build_disallow_patterns()
  end
  return cached_disallow_patterns
end

return M
