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

## UI / highlights

- All highlight groups live in `lua/nvime/ui.lua`; no other module calls
  `nvim_set_hl` or hardcodes a hex colour. Surfaces decorate exclusively through the
  named `Nvime*` groups (via extmark `hl_group` / `line_hl_group` / `winhighlight`),
  so retuning the look is a one-file change. Keep new decoration on `Nvime*` groups —
  never reference a standard group (`DiffAdd`, `Comment`, …) directly from a surface.
- The palette is **colorscheme-derived**: `resolve_palette()` reads the active theme's
  standard semantic groups (`Normal`/`NormalFloat`, `Comment`, `DiffAdd`,
  `Diagnostic*`, `Special`, `Function`, …) and maps each accent onto the *role* that
  carries it, blending raised surfaces/washes from the resolved background. `FALLBACK`
  is the curated palette used only when a source group is undefined or
  `termguicolors` is off. Pure role groups (`NvimeError`, `NvimeCursorLine`) `link`
  to standard groups so they also carry the theme's cterm colours. It re-resolves on
  `ColorScheme`. `require("nvime.ui").palette()` returns the resolved palette (tests).
- The two `syntax/*.vim` files independently `highlight default link Nvime* <Standard>`
  as a fallback for buffers that load syntax before `setup()` runs; keep them aligned
  with the role mapping in `ui.lua`.

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
