# Project agent memory

This file is the project's committed home for project-intrinsic agent knowledge: build, test, release, architecture, and sharp-edge notes that should travel with the code.

- Add durable project-specific notes here as they are discovered through real work.

## Testing

- Run the suite with `./scripts/test` (headless Neovim against `tests/fixtures/claude`).
  It exits non-zero on any failed assertion. Lint is `stylua --check lua/ plugin/ tests/`
  and `luacheck lua plugin tests` (configs: `.stylua.toml`, `.luacheckrc`).
- Tests in `tests/headless_spec.lua` are top-level IIFEs; separate them with `;`
  (`end)()` immediately followed by `(function()` is a Lua "ambiguous syntax" error).
- Shell fixtures must use `test -e .git`, not `test -d .git`: in a git worktree (e.g.
  the disposable checkouts CI/agents use) `.git` is a pointer *file*, not a directory,
  so a `-d` check fails there even though it passes in a normal clone.

## Sharp edges

- `vim.system()` **throws synchronously** when `args[1]` (the provider/tool binary) is
  not on `PATH`, or when `cwd` does not exist. Every spawn site must guard against this
  (pcall + a synthetic failure path), or the throw escapes the caller, leaks temp
  workspaces, and wedges busy/`in_flight` state that is only cleared from the exit
  callback. See `agents.lua` `M.run`, `verify.lua` `run_check`, `test_loop.lua`.
- `vim.system`'s `kill` is a method: call `handle:kill("sigterm")` /
  `pcall(handle.kill, handle, "sigterm")`. `pcall(handle.kill)` passes nil self and
  silently no-ops.
- `plan.json`, `usage.json`, session/MCP JSON, and per-model rate overrides are all
  untrusted/agent- or user-authored. JSON readers must `type(decoded) == "table"`
  before indexing; per-model rate overrides must be deep-merged onto defaults.
