# nvime Agent Exercises

This file documents the graded prompt exercises used to compare nvime's
constrained edit prompt against direct Claude/Codex CLI coding runs.

Run the harness without spending tokens:

```sh
scripts/agent-exercises --list
scripts/agent-exercises --provider codex --mode nvime --exercise all
scripts/agent-exercises --provider codex --mode general --exercise all
scripts/agent-exercises --provider codex --mode plan --exercise all
```

Live runs are opt-in:

```sh
scripts/agent-exercises --provider codex --mode nvime --exercise all --live
NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet \
  NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=0.35 \
  scripts/agent-exercises --provider claude --mode nvime --exercise all --live --fix-attempts 1
scripts/agent-exercises --provider codex --mode general --exercise all --live
scripts/agent-exercises --provider codex --mode plan --exercise all --live
```

## Edit Exercise Matrix

| id | difficulty | task | checks |
|---|---|---|---|
| `easy_slugify` | easy | Implement normalized slug generation. | Lowercase, punctuation removal, separator collapse, trim. |
| `medium_duration_parser` | medium | Fix compact and spaced duration parsing. | Full input validation, invalid input raises `ValueError`. |
| `hard_half_open_windows` | hard | Preserve half-open interval semantics. | Merge overlaps, keep adjacency separate, skip empty intervals, reject reversed intervals. |
| `extremely_difficult_safe_join` | extremely_difficult | Close symlink path escape in a repo path helper. | Reject absolute, parent traversal, and symlink escapes while preserving valid paths. |
| `extremely_difficult_json_patch` | extremely_difficult | Implement an RFC 6902 subset over JSON Pointer paths. | Escaped keys, list append/indexing, atomic failure, invalid operation rejection. |
| `extremely_difficult_topological_batches` | extremely_difficult | Implement stable dependency batches. | Stable topological batches, duplicate/missing dependency/cycle rejection, no input mutation. |

## Workflow Exercise Matrix

| mode | id | difficulty | task | checks |
|---|---|---|---|---|
| general | `general_diagnose_duration_parser` | hard | Diagnose a failing parser without editing. | Read-only source scope, mentions exact file/function/root-cause categories. |
| plan | `plan_rate_limited_service` | extremely_difficult | Draft a multi-file rate-limiter implementation plan. | Plan files only, schema v1, ordered small steps, anchors, tests/acceptance. |

Edit exercises create a temporary Python repository, confirm its tests fail,
generate the actual nvime edit prompt through headless Neovim, verify the
prompt contains precomputed project context, call the selected provider, apply
`NVIME_DIFF`/`NVIME_REPLACEMENT`, and run:

```sh
python -m unittest -q
```

The run succeeds only when tests pass, the provider changed exactly the
exercise target file, and the nvime prompt self-checks passed. Non-live runs
are useful in CI because they still verify baseline failures plus prompt
context (`Precomputed nvime project context`, detected unittest runner, related
test excerpts, and the strict machine-readable response contract).

Workflow exercises validate the broader agentic loop: general chat must diagnose
without source writes, and plan authoring must write only `.nvime/plans/` files
with marker-first output, schema v1, anchored ranges, meaningful tests, and
reviewable step granularity.

## Latest Local Results

Validated on this checkout with local CLIs:

| provider | mode | command shape | result |
|---|---|---|---|
| Codex | nvime | `scripts/agent-exercises --provider codex --mode nvime --exercise all --live` | 6/6 passed across easy/medium/hard/extreme edit tasks. |
| Claude Sonnet | nvime | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=0.35 scripts/agent-exercises --provider claude --mode nvime --exercise all --live --fix-attempts 1` | 6/6 passed across easy/medium/hard/extreme edit tasks. |
| Codex | default | `scripts/agent-exercises --provider codex --mode default --exercise all --live` | 6/6 passed. |
| Claude Sonnet | default | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=0.35 scripts/agent-exercises --provider claude --mode default --exercise all --live` | 6/6 passed. |
| Codex | general | `scripts/agent-exercises --provider codex --mode general --exercise all --live` | 1/1 passed: correct diagnosis, no source writes. |
| Claude Sonnet | general | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=0.20 scripts/agent-exercises --provider claude --mode general --exercise all --live` | 1/1 passed: correct diagnosis, no source writes. |
| Codex | plan | `scripts/agent-exercises --provider codex --mode plan --exercise all --live` | 1/1 passed after adding marker-first/no-progress discipline. |
| Claude Sonnet | plan | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=0.35 scripts/agent-exercises --provider claude --mode plan --exercise all --live` | 1/1 passed after strengthening minimum runtime-plan granularity. |

Earlier live runs exposed four weaknesses that are now guarded by prompts and
the harness: incomplete parser/normalizer validation, brittle diffs whose
context did not match selected text, chat/progress narration in final answers,
and under-granular two-step runtime plans. The edit prompt now injects bounded
repo/test/symbol context, requires requirement-by-requirement verification, and
allows `NVIME_REPLACEMENT` for small multi-line selected ranges when a hunk
would be brittle. The chat prompt forbids progress narration, and the plan
prompt requires marker-first output plus at least three reviewable steps for
runtime behavior changes.

## Permission Notes

Claude can use the nvime MCP server through `--mcp-config` with the normal
tool allowlist.

Codex `exec` can discover the same MCP server, but non-interactive MCP calls
are cancelled unless `--dangerously-bypass-approvals-and-sandbox` is enabled.
nvime therefore keeps `mcp.codex_bypass_for_mcp = false` by default. Enabling it
is a deliberate trust tradeoff: it gives Codex MCP tools but removes Codex's
OS-level sandbox, leaving nvime's shellguard as a discipline layer rather than
a true sandbox.
