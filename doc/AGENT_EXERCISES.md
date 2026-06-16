# nvime Agent Exercises

This file documents the graded prompt exercises used to compare nvime's
constrained edit prompt against direct Claude/Codex CLI coding runs.

Run the harness without spending tokens:

```sh
scripts/agent-exercises --list
scripts/agent-exercises --provider codex --mode nvime --exercise all
scripts/agent-exercises --provider codex --mode general --exercise all
scripts/agent-exercises --provider codex --mode plan --exercise all
scripts/agent-exercises --provider codex --mode plan-execute --exercise all
```

Live runs are opt-in:

```sh
scripts/agent-exercises --provider codex --mode nvime --exercise all --live
NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet \
  NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=0.35 \
  scripts/agent-exercises --provider claude --mode nvime --exercise all --live --fix-attempts 1
scripts/agent-exercises --provider codex --mode general --exercise all --live
scripts/agent-exercises --provider codex --mode plan --exercise all --live
scripts/agent-exercises --provider codex --mode plan-execute --exercise all --live --fix-attempts 1
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
| `extremely_difficult_csv_parser` | extremely_difficult | Implement strict RFC 4180 CSV row parser. | Quoted-field embedded newlines, doubled-quote escape, CRLF, empty-field preservation, rejection of unterminated/bare/stray quotes. |

## Workflow Exercise Matrix

| mode | id | difficulty | task | checks |
|---|---|---|---|---|
| general | `general_diagnose_duration_parser` | hard | Diagnose a failing parser without editing. | Read-only source scope, mentions exact file/function/root-cause categories. |
| general | `general_diagnose_shared_state_race` | extremely_difficult | Diagnose a hidden mutable-default-argument bug masquerading as test flakiness. | Read-only source scope, mentions `events.py`, `_coalesce`, the mutable-default-argument anti-pattern. |
| plan | `plan_rate_limited_service` | extremely_difficult | Draft a multi-file rate-limiter implementation plan. | Plan files only, schema v1, ordered small steps, anchors, tests/acceptance. |
| plan | `plan_resilient_outbox` | extremely_difficult | Plan a multi-file resilient outbox with idempotency keys + dead-letter queue. | Plan files only, schema v1, ordered small steps, anchored ranges, tests/acceptance, step-coherence rule visible. |
| plan-execute | `plan_rate_limited_service` | extremely_difficult | Author the plan, execute each step through nvime edit prompts, then validate. | Plan validity, step patches, visible tests, hidden tests, changed-file scope. |
| plan-execute | `plan_resilient_outbox` | extremely_difficult | Author + execute the resilient-outbox plan end-to-end across `outbox.py`, `storage.py`, and tests. | Plan validity, step coherence (test asserts the contract impl pinned), visible + hidden tests, scoped files. |

Edit exercises create a temporary Python repository, confirm its tests fail,
generate the actual nvime edit prompt through headless Neovim, verify the
prompt contains precomputed project context, call the selected provider, apply
`NVIME_DIFF`/`NVIME_REPLACEMENT`, and run:

```sh
python -m unittest -q
```

The run succeeds only when visible tests pass, configured hidden tests pass,
the provider changed exactly the exercise target file, and the nvime prompt
self-checks passed. Non-live runs are useful in CI because they still verify
baseline failures plus prompt context (`Precomputed nvime project context`,
detected unittest runner, related test excerpts, and the strict
machine-readable response contract).

Workflow exercises validate the broader agentic loop: general chat must diagnose
without source writes, plan authoring must write only `.nvime/plans/` files with
marker-first output, schema v1, anchored ranges, meaningful tests, and
reviewable step granularity, and plan-execute must run the authored steps
through the actual nvime edit prompt before visible and hidden validation.

## Latest Local Results

Validated on this checkout with local CLIs:

| provider | mode | command shape | result |
|---|---|---|---|
| Codex | nvime | `scripts/agent-exercises --provider codex --mode nvime --exercise all --live` | 6/6 passed across easy/medium/hard/extreme edit tasks. |
| Claude Sonnet | nvime | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=0.35 scripts/agent-exercises --provider claude --mode nvime --exercise all --live --fix-attempts 1` | 6/6 passed across easy/medium/hard/extreme edit tasks. |
| Codex | nvime hidden stress | `scripts/agent-exercises --provider codex --mode nvime --exercise extremely_difficult_json_patch --live --fix-attempts 1` and `... extremely_difficult_topological_batches ...` | 2/2 passed first try with visible and hidden tests. |
| Claude Sonnet | nvime hidden stress | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=0.80 scripts/agent-exercises --provider claude --mode nvime --exercise extremely_difficult_json_patch --live --fix-attempts 1` and `... extremely_difficult_topological_batches ...` | 2/2 passed; JSON Patch needed one repair after a hidden root-replacement miss, scheduler passed first try. |
| Codex | default | `scripts/agent-exercises --provider codex --mode default --exercise all --live` | 6/6 passed. |
| Claude Sonnet | default | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=0.35 scripts/agent-exercises --provider claude --mode default --exercise all --live` | 6/6 passed. |
| Codex | general | `scripts/agent-exercises --provider codex --mode general --exercise all --live` | 1/1 passed: correct diagnosis, no source writes. |
| Claude Sonnet | general | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=0.20 scripts/agent-exercises --provider claude --mode general --exercise all --live` | 1/1 passed: correct diagnosis, no source writes. |
| Codex | plan | `scripts/agent-exercises --provider codex --mode plan --exercise all --live` | 1/1 passed after adding marker-first/no-progress discipline. |
| Claude Sonnet | plan | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=0.35 scripts/agent-exercises --provider claude --mode plan --exercise all --live` | 1/1 passed after strengthening minimum runtime-plan granularity. |
| Codex | plan-execute | `scripts/agent-exercises --provider codex --mode plan-execute --exercise all --live --fix-attempts 1` | 1/1 passed: 4-step plan, step patches, visible tests, hidden tests, scoped files. |
| Claude Sonnet | plan-execute | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=0.80 scripts/agent-exercises --provider claude --mode plan-execute --exercise all --live --fix-attempts 1` | 1/1 passed: 3-step plan, step patches, visible tests, hidden tests, scoped files. |
| Codex | edit (CSV) | `scripts/agent-exercises --provider codex --mode nvime --exercise extremely_difficult_csv_parser --live --fix-attempts 1` | Passed first try: visible 10/10, hidden 6/6 (RFC 4180 incl. CRLF inside quoted fields, doubled-quote escape, doubled trailing newline → blank row). |
| Claude Sonnet | edit (CSV) | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet ... --provider claude --mode nvime --exercise extremely_difficult_csv_parser --live --fix-attempts 1` | Passed first try: visible 10/10, hidden 6/6. |
| Claude Opus | edit (CSV) | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=opus ... --provider claude --mode nvime --exercise extremely_difficult_csv_parser --live --fix-attempts 1` | Passed first try: visible 10/10, hidden 6/6. |
| Codex | general (shared state) | `scripts/agent-exercises --provider codex --mode general --exercise general_diagnose_shared_state_race --live` | Passed first try: pinpointed `events.py::_coalesce`, named the mutable-default-argument anti-pattern, traced why the second test sees `[]`. |
| Claude Sonnet | general (shared state) | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet ... --provider claude --mode general --exercise general_diagnose_shared_state_race --live` | Passed first try: same diagnosis with cross-test pollution explanation. |
| Codex | plan (outbox) | `scripts/agent-exercises --provider codex --mode plan --exercise plan_resilient_outbox --live` | Passed first try: 6 steps, schema v1, anchors, dead-letter + idempotency contract pinned per step. |
| Claude Sonnet | plan (outbox) | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet ... --provider claude --mode plan --exercise plan_resilient_outbox --live` | Passed first try: 5 steps, all checks. |
| Codex | plan-execute (outbox) | `scripts/agent-exercises --provider codex --mode plan-execute --exercise plan_resilient_outbox --live --fix-attempts 1` | Passed after step-coherence + dependency-context tuning: 6 steps, visible 3/3, hidden 5/5, no fix-attempts needed. |
| Claude Sonnet | plan-execute (outbox) | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=sonnet NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=1.50 ... --provider claude --mode plan-execute --exercise plan_resilient_outbox --live --fix-attempts 1` | Passed first try: 6 steps, visible 10/10, hidden 5/5. |
| Claude Opus | plan-execute (outbox) | `NVIME_AGENT_EXERCISE_CLAUDE_MODEL=opus NVIME_AGENT_EXERCISE_CLAUDE_BUDGET=4.00 ... --provider claude --mode plan-execute --exercise plan_resilient_outbox --live --fix-attempts 1` | Passed first try: 7 steps, visible 9/9, hidden 5/5. |

Earlier live runs exposed five weaknesses that are now guarded by prompts and
the harness: incomplete parser/normalizer validation, brittle diffs whose
context did not match selected text, chat/progress narration in final answers,
under-granular two-step runtime plans, and plan-execute step incoherence where
a separate test step asserted a contract the implementation step did not
promise. The edit prompt now injects bounded repo/test/symbol context, requires
requirement-by-requirement verification, and allows `NVIME_REPLACEMENT` for
small multi-line selected ranges when a hunk would be brittle. The chat prompt
forbids progress narration, the plan author prompt requires marker-first output
plus at least three reviewable steps for runtime behavior changes plus a step-
coherence rule that pins API contracts in BOTH the implementation and test
steps' intents (with worked examples for backoff/jitter formulae), and the plan
executor lane now injects every dependency step's intent + notes into the
patch-worker context so a test step can never silently drift from the
implementation step it asserts against. The harness now also has hidden tests
for the hardest edit and plan-execution cases, and the plan-execution path can
feed validation or patch failures back into a bounded repair attempt with
`--fix-attempts`.

## Prompt baselines (no-spend contract)

The prompts nvime sends are the contract with the model, so they are snapshot-
tested. `scripts/agent-exercises --check-prompts` rebuilds every nvime/general/
plan prompt with the current code (no provider call) and fails if it differs
from the committed snapshots under `tests/fixtures/prompt-baselines/`. After an
intentional prompt change, run `scripts/agent-exercises --update-baselines`,
review the diff, and commit it. CI runs `--check-prompts` in the
`prompt-contract` job so a prompt edit can never land unreviewed.

## Permission Notes

Claude can use the nvime MCP server through `--mcp-config` with the normal
tool allowlist.

Codex `exec` can discover the same MCP server, but non-interactive MCP calls
are cancelled unless `--dangerously-bypass-approvals-and-sandbox` is enabled.
nvime therefore keeps `mcp.codex_bypass_for_mcp = false` by default. Enabling it
is a deliberate trust tradeoff: it gives Codex MCP tools but removes Codex's
OS-level sandbox, leaving nvime's shellguard as a discipline layer rather than
a true sandbox.
