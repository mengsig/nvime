# Contributing to nvime

`nvime` is an **editor-discipline tool**, not an autocomplete. Its one rule —
*No Vibe Coding In My Editor* — governs the code as much as the feature set:
the AI never touches code until told exactly where, how, and why, and every
edit is range-scoped, rationalized, reviewed, verified, attributed, and
audited. Contributions are held to the same bar.

## The litmus test for any change

There are exactly two sanctioned ways for AI to touch code, and every feature
must reinforce one of them:

1. **Understand before touching** — the Plan lane: read-only investigation →
   an ordered plan → execute one approved range per step through the reviewed
   inline-diff flow.
2. **Touch, then enforce understanding before merging** — the Big Change lane:
   an autonomous build in an isolated git worktree → block-by-block
   forced-comprehension review before merge.

Before proposing a feature, ask: *does this give the human more control,
comprehension, accountability, safety, or review quality?* If instead it buys
the AI more **unsupervised** reach (autonomy, hidden edits, drive-by
refactors, self-healing retry loops that re-prompt the model on failure), it is
the opposite of what this project is for. Such features are rejected no matter
how convenient.

## Repository layout

```
lua/nvime/
  init.lua          setup(), command + keymap registration, enable/disable
  config.lua        defaults + validation (every config key lives here)
  state.lua         shared mutable session state
  provider.lua      claude/codex selection + model handling
  agents.lua        spawning + streaming the provider CLIs
  edit.lua          the reviewed-edit lane (constrained patch worker)
  diff.lua, diff/*  the inline-diff engine: parse → block → review → apply
  plan.lua          the Plan lane (authoring, execution, plan.json/plan.md)
  bigchange/*       the Big Change lane (intake → build → comprehension review)
  verify.lua        pre-accept tree-sitter + lint/type gate
  critic.lua        opt-in devil's-advocate APPROVE/FLAG/REJECT pass
  risk.lua          blast-radius scoring for the diff banner
  policy_rules.lua  per-path policy (.nvime/policy.json)
  intent.lua        local intent linter (vague-prompt guard)
  shellguard.lua    blocks raw claude/codex launches in Neovim APIs
  attribution.lua   per-line authorship ledger (.nvime/attribution.json)
  audit.lua         append-only event log (.nvime/audit.jsonl)
  usage.lua         token + cost ledger (.nvime/usage.json)
  fslock.lua        advisory lock + atomic write for the ledgers
  schema.lua        ledger schema-version reconciliation
  mcp_server.lua    nvime's own read-only MCP tools for agents
plugin/nvime.lua    bootstrap entry
PROTOCOL.md         the agent-response contract (NVIME_DIFF / NVIME_PLAN / ...)
tests/headless_spec.lua   the end-to-end headless integration spec
scripts/test        runs the spec under headless Neovim
scripts/agent-exercises   prompt-structure benchmark (see doc/AGENT_EXERCISES.md)
```

## Running the tests

```sh
./scripts/test
```

This launches headless Neovim against a fake local `claude` executable and runs
the full integration spec. The runner now exits **non-zero** on any failed
assertion, so a green exit means the suite genuinely passed.

Environment notes:

- The broken-Python verify test is skipped automatically when no Python
  tree-sitter parser is installed (stock Neovim bundles only a handful). It
  asserts the parse-error path against Lua, whose parser ships everywhere.
- One test fans out real child Neovim processes to prove the ledger lock holds
  under concurrency; it skips cleanly if a child cannot be spawned.

Add tests in `tests/headless_spec.lua` as a new top-level IIFE
(`(function() ... end)();`). **Separate IIFEs with a semicolon** — `end)()`
immediately followed by `(function()` is a Lua "ambiguous syntax" error.

## Linting

CI runs `stylua --check` and `luacheck` over `lua/ plugin/ tests/`. Config lives
in `.stylua.toml` (2-space indent, double quotes, 120 columns) and `.luacheckrc`.

> **stylua version sensitivity:** stylua's line-wrapping/quote rules change
> between releases, so a tree formatted by one version can be flagged by
> another. Match the surrounding hand-style when editing, and pin the stylua
> version in CI if you touch formatting. Do **not** bundle a tree-wide reformat
> into a feature PR — that is a drive-by change; keep it a separate, labeled
> commit.

## Conventions

- **Cross-module requires** that could fail are `pcall`-guarded; core deps
  (`state`, `config`, `git`, `audit`) are required at the top.
- **Every consequential decision writes an audit event.** Add new events to
  `audit.write({ event = "...", ... })` and, if they are review-significant,
  teach `digest.lua` to bucket them (e.g. `block_conflict`, `verify_force`,
  `protocol_violation`, `anchor_ambiguous`, `hunk_count_mismatch`).
- **Config keys** are declared in `config.lua` `M.defaults` (with a comment)
  and validated by the same file. A key that can be `nil`/multi-typed goes in
  `optional_types`.
- **Ledger writes** go through `fslock` (`with_lock` + `atomic_write`) and
  carry a `version`; never silently downgrade a newer on-disk schema (see
  `schema.lua`).
- **The agent response contract is `PROTOCOL.md`.** Changing how nvime parses
  `NVIME_DIFF` / `NVIME_REPLACEMENT` / `NVIME_PLAN` means updating both the
  parser (`diff/parser.lua`) and `PROTOCOL.md`, and ideally a prompt-baseline.
- **Surface uncertainty, never paper over it.** If a parser/anchor/diff path
  guesses, make the guess a banner, a conflict, or an audit event — not a
  silent apply.

## Adding an MCP tool (read-only introspection for agents)

In `lua/nvime/mcp_server.lua`: add an entry to the `TOOLS` table (name +
description + `inputSchema`), write a `tool_<name>(args)` handler that returns
`ok_json(...)`/`err_result(...)` and guards paths with `safe_join`, and register
it in `TOOL_HANDLERS`. Tools must be **read-only** and must return constraints
or facts, never a "safe to proceed" green light — the human accept gate is the
only authority.

## Submitting changes

1. Branch off `main`.
2. Keep the change range-scoped and rationalized; match the surrounding style.
3. `./scripts/test` must pass; add tests for new behavior.
4. Run `stylua --check` and `luacheck` locally if you can.
5. Write a commit message that states the bug/feature, the change, and *why it
   keeps the AI on its leash*.
