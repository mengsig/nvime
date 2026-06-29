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

## Accept gate / verify / policy

- The manual diff accept path (`diff/ops.lua` `accept_blocks`) runs three gate
  stages in order: (1) the verify tree-sitter **parse** gate (`verify.should_block_accept`,
  governed by `verify.block_on_parse_error`, blocks plain `ga`/`gA`, `gA!` forces);
  (2) the unified **accept policy** (`enforce_accept_policy`) — critic verdict / risk
  level / external-verify findings, each mapped to `off|warn|confirm|block` via
  `diff.accept_policy` (signals `critic_reject`, `critic_flag`, `risk_high`,
  `verify_tool_error`); (3) the legacy high-risk force-confirm (`risk.confirm_force_accept`,
  force-path only). All `accept_policy` signals default to `off` — nothing gains
  friction unless opted in. This gate is on the MANUAL accept path only; the
  trivial/auto-cleared instant-approve path (`bigchange/triviality.lua`) is untouched.
- Verify is keyed on a **changedtick + per-block-status signature**
  (`verify.lua` `content_signature`), not run-once. A *reject* changes the proposed
  content without bumping the buffer changedtick, so the signature includes block
  statuses. `accept_blocks`/`reject_blocks` call `verify.refresh` (a no-op when the
  signature is unchanged) so the parse gate never reflects content that won't exist.
- Verify findings carry `line`/`col`; they populate a quickfix list
  (`verify.quickfix`, set not opened) and are navigable on the diff target with
  `]v`/`[v` (`diff.next_finding`/`prev_finding`).
- `policy_rules` **layers** a project `.nvime/policy.json` ON TOP of the built-in
  human-only defaults (defaults listed first so project rules win ties via
  longest/last-written specificity in `evaluate`). Opt out with
  `policy_rules.inherit_defaults = false` or `"inherit_defaults": false` in the JSON.
  The glob matcher has a local fallback (`local_path_matches`) so a failure to load
  `nvime.verify` matches **closed**, never silently dropping a secret/lockfile guard.

## Sharp edges

- `vim.system()` **throws synchronously** when `args[1]` (the provider/tool binary) is
  not on `PATH`, or when `cwd` does not exist. Every spawn site must guard against this
  (pcall + a synthetic failure path), or the throw escapes the caller, leaks temp
  workspaces, and wedges busy/`in_flight` state that is only cleared from the exit
  callback. See `agents.lua` `M.run`, `verify.lua` `run_check`, `test_loop.lua`.
- `vim.system`'s `kill` is a method: call `handle:kill("sigterm")` /
  `pcall(handle.kill, handle, "sigterm")`. `pcall(handle.kill)` passes nil self and
  silently no-ops.
- `vim.system`'s `timeout` opt SIGTERMs the process and still invokes the exit
  callback, but the resulting termination surfaces in build-dependent encodings —
  the result `code` is rewritten to 124 only when the killed process reports exit
  status 0/1; other libuv/neovim builds report `code == 0` with `result.signal == 15`
  or fold the term signal into `code == 143` with `result.signal == 0` (the encoding
  that missed on CI). Reverse-engineering "which encoding means timed out" from the
  exit result is therefore NOT portable. `test_loop.lua` instead OWNS the *decision*
  (not the kill encoding): it arms its own `uv` oneshot timer at exactly `limit` that
  sets an authoritative `timed_out` flag, so the verdict reads that flag verbatim and
  never depends on the exit encoding. Killing the runner FROM that fast-event timer
  callback was itself NOT portable — `handle:kill` issued in the fast context did not
  reliably terminate the runner on CI's build, so the exit callback never fired within
  budget and the loop looked wedged. So the kill is now issued from the MAIN loop
  (`vim.schedule`) AND `vim.system`'s native `timeout` is armed as a backstop killer
  (set to `limit` + a grace so the flag is always recorded first) — the native timeout
  provably SIGTERMs the runner and fires the always-firing exit callback on every
  build even if the scheduled kill never lands. Either way the callback fires (clearing
  `in_flight`), so a hang can't wedge the loop; a genuine pass/fail leaves the flag
  false and stays a fixable failure. The timer is stopped+closed in the exit callback
  (and the kill is `pcall`-guarded for the already-reaped race).
- `plan.json`, `usage.json`, session/MCP JSON, and per-model rate overrides are all
  untrusted/agent- or user-authored. JSON readers must `type(decoded) == "table"`
  before indexing; per-model rate overrides must be deep-merged onto defaults.
- Read-only lane enforcement differs by provider (`agents.lua`). claude restricts
  per-tool (an explicit disallow-list + an allow-list, dropping the shell and web tools
  per `allow_shell`/`allow_web`). codex `exec` has no per-tool surface — it enforces at
  the OS sandbox (`-s read-only` forbids all writes and network). Two asymmetries can't
  be closed from codex flags: codex still runs commands inside a read-only sandbox (so
  `allow_shell = false` is advisory there), and a sandboxed codex lane has no network
  (so `allow_web = true` grants it no web access). The workspace-write codex lanes pin
  `sandbox_workspace_write.network_access=false` explicitly (bigchange excepted).
- NOTE: this file is the injected `project_guidance` (CLAUDE.md → AGENTS.md content
  reaches every agent prompt), and several tests grep agent-arg audit lines for the
  exact provider tool-permission tokens. Don't write those provider tool names verbatim
  here — describe the shell/web/edit tools generically (as above) so the doc text never
  collides with those assertions.
