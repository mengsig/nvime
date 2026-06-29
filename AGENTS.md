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

## Big Change comprehension gate

- The forced-comprehension review (`bigchange/review.lua`) gates the merge on every
  block reaching `state == "cleared"`. Three independent mechanisms feed it, all in
  `bigchange/`:
  - **Trivial auto-clear** (`triviality.lua`): genuinely self-evident blocks
    (imports/requires, doc/markdown prose, comment-only edits, docstrings,
    version/config bumps, and pure whitespace/formatting) clear with NO explanation.
    This frictionless instant-approve is intentional — *enhance* it, never add friction.
    Whitespace detection (`_is_whitespace_only`) pairs non-blank del/add lines in order
    and compares a `ws_sig` that drops leading indent + collapses internal runs but
    preserves string contents verbatim; it is order-sensitive and conservative
    (token-adjacency changes like `mut x`↔`mutx` never match). Leading indentation is
    treated as significant for `py`/`yaml` (a re-indent there is not cosmetic). Every
    relaxation is guarded so an executable code line is never waved through.
  - **Independent grader** (`review.lua` `submit_round`): explanations are graded by a
    FRESH, READ-ONLY `critic`-lane turn that never resumes the worktree author
    (`grade_turn = {lane="critic", resume=false, scope="grade"}`). The author's resumed
    write session (`scope="worktree"`) only runs to act on `request_changes` critiques.
    Keeping the grader independent removes the self-grading conflict-of-interest.
  - **Devil's-advocate critic** (`critic.lua`, opt-in via `bigchange.critic.enabled`):
    one fresh read-only pass annotates each gradeable block with an APPROVE/FLAG/REJECT
    verdict before review opens. Advisory only — it never blocks.
- `agent.turn` session buckets are scoped (`agent.lua` `session_bucket`): `worktree`
  (resumable author), `intake`, plus read-only `grade`/`critic` buckets kept SEPARATE so
  a stray session id from a read-only turn can never overwrite the author's resumable id.
- Binary / pure-rename / mode-only diffs carry no `@@` hunk, so `diffparse.parse` emits a
  synthetic **meta hunk** (`meta = "binary"|"rename"|"copy"|"mode"`) for them; `blocks.lua`
  flags those blocks `meta_kind` (never trivial-auto-cleared) and `review.lua` requires an
  explicit acknowledgment (`a`) to clear them — otherwise they'd merge unreviewed via
  `merge.lua`'s `git diff --binary`.

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
