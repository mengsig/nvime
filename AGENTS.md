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
- Key hints (footers, hint rows) go through `ui.keyhint_line(items, opts)` (returns a
  string + `{col_start, col_end, hl}` byte-range marks) or `ui.keyhint_segments` (a
  `virt_lines` segment list). Keys render `NvimeKey`, descriptions `NvimeMuted`,
  separators `NvimeFaint` — so every surface's keys read the same. Don't hand-build a
  flat single-colour footer; thread these instead (see `plan.lua`/`diff/session.lua`/
  `bigchange/*` callers). The usage dashboard footer is the original precedent.

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

## Providers

- The supported providers live in ONE place: the `ADAPTERS` registry in
  `provider.lua`. The brand names are written exactly once there; `provider.names`
  (cycle order) and `provider.adapters` (name → adapter lookup) both derive from it,
  as do the effort levels/aliases. `agents.lua` registers each adapter's `build_args`
  at load, and `agents.build_args` dispatches through `provider.adapters[name].build_args`
  rather than an `if provider == "claude" … elseif "codex"` chain. Add a provider, or
  fix a per-brand divergence, by editing the registry — not by adding another branch.
- A plan remembers its authoring provider in `plan.provider` (and per-provider author
  sessions in `plan.author_provider_sessions`; the implement-phase executor's sessions
  live separately in `plan.provider_sessions`). The phase-0 continuity badge and the
  `gN` reset must target the plan's own provider/author bucket, never the global
  `config.provider` default. `plan._plan_provider(plan)` resolves it.
