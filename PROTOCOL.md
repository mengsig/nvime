# nvime Agent Response Protocol

This file is the stable contract between nvime's edit/perf lanes and an agent
provider. The parser lives in `lua/nvime/diff.lua`; the prompt rules live in
`lua/nvime/edit.lua`.

Agents must return exactly one machine-readable response block. Normal edit mode
forbids analysis, caveats, summaries, or prose outside the block. Perf mode may
put one `BENCH: orig=<t1>s cand=<t2>s speedup=<x>x n=<size>` line before the
block and no other prose.

## Response Forms

### `NVIME_NO_CHANGE`

Use this when there is no concrete selected-range patch to apply.

```text
NVIME_NO_CHANGE
<brief explanation>
```

Normal edit mode explicitly treats this as the right answer when the selected
code already meets its documented behavior or when the intent is only
review-shaped. Perf mode must use it when the candidate is unproven, slower,
incorrect, or within measurement noise.

### `NVIME_REPLACEMENT`

Use this only for blank or near-blank selected ranges, tiny whole-range rewrites,
or perf replacements where a whole selected-range replacement is clearer than a
hunk.

````text
NVIME_REPLACEMENT
```
<full replacement for the selected range only>
```
````

The replacement is inserted verbatim. nvime does not add indentation.

### `NVIME_DIFF`

Use this for any change to existing nonblank text. It is required for Markdown,
large selections, and selections containing code fences.

````text
NVIME_DIFF
```diff
--- a/path
+++ b/path
@@ -line,count +line,count @@
<minimal changed hunk lines only>
```
````

The file headers must point at the current file. Hunk headers should be ranged
headers of the form `@@ -line,count +line,count @@`; nvime tolerates small count
errors but rejects cross-file patches.

## Parser Fallbacks

`response_mode` scans for the first supported `NVIME_*` marker. If prose appears
before a valid marker, nvime ignores the prose and parses the marker block.

If an `NVIME_DIFF` body lacks file headers or ranged hunk headers, nvime tries
`build_unranged_hunk`: it strips incomplete file headers, reads `@@` plus
diff-style lines, anchors the old lines inside the selected range, and rebuilds
current-file headers. If the old lines cannot be anchored, no patch opens.

If no `NVIME_*` marker is present, nvime may extract a current-file unified diff
from fenced or raw output. Plain review answers become `no_change` and do not
turn into replacements.

## Intent Reroute

`looks_like_question` routes question-shaped or review-shaped edit intents to the
read-only Ask lane before any edit prompt is sent. Examples include prompts with
`?`, "look right", "verify", "inspect", "audit", "review", "nitpick", or
"iterate throughout", unless they also contain an explicit patch verb such as
"fix", "add", "remove", "replace", "implement", or "update".

## NVIME_PLAN

Use this only in the plan author lane. The agent investigates the codebase
read-only, writes a structured plan file under `.nvime/plans/<plan-id>/`, and
emits exactly one marker block confirming what was written:

````text
NVIME_PLAN
```json
{ "id": "0001-add-provider-registry", "summary": "...", "step_count": 6, "files_estimated": ["lua/nvime/policy.lua"] }
```
````

The marker payload is a confirmation, not the plan body. The plan itself lives
on disk at `.nvime/plans/<plan-id>/plan.json` plus an optional human-readable
`.nvime/plans/<plan-id>/plan.md`. nvime synchronizes those files out of the
agent's temp workspace and refuses to sync anything outside `.nvime/plans/`.

`plan.json` schema (version 1):

```json
{
  "version": 1,
  "id": "0001-add-provider-registry",
  "title": "Add provider registry",
  "why": "Reduces hardcoded \"claude\"/\"codex\" branches across 7 callsites.",
  "created_at": 1735000000,
  "files_estimated": ["lua/nvime/providers/claude.lua", "lua/nvime/policy.lua"],
  "acceptance": [
    { "id": 1, "text": "scripts/test passes", "status": "pending" }
  ],
  "steps": [
    {
      "id": 1,
      "intent": "Extract claude adapter to lua/nvime/providers/claude.lua",
      "file": "lua/nvime/providers/claude.lua",
      "range": "new",
      "depends_on": [],
      "tests": ["./scripts/test"],
      "status": "pending",
      "notes": "Move build_args, parser, and tool list helpers."
    }
  ]
}
```

Steps must:

- target exactly ONE file per step (the same file the executor lane will open);
- use `"range": "new"` for new files or `"range": { "line1": N, "line2": M }`
  for edits to existing files;
- be sized so the future edit-lane diff review is reasonable (~5-100 lines);
- declare `depends_on` so the runner can refuse out-of-order execution;
- declare `tests` as shell commands the user can run to verify the step.

Step `status` is one of `pending`, `in_progress`, `done`, `blocked`,
`abandoned`.

The executor lane (`:NvimePlan run <id> [step]`) does not invent a new
prompt: it opens the step's file, visual-selects the step's range, and calls
the existing edit lane with the step's intent (prefixed with a small
constant-size plan-context block). Diff review remains the existing inline
flow with content-match guards.

## Top-Level Prompt Rules

Normal edit mode says:

- "You are a constrained patch worker, not a reviewer."
- "Return exactly one machine-readable response block."
- "You may only propose changes for the selected range in the current file."
- "Do not edit files directly."
- "Prefer NVIME_DIFF for any change to existing nonblank text."
- "NVIME_DIFF must include --- a/path, +++ b/path, and ranged @@ headers."

Perf edit mode says:

- "You are a constrained patch worker focused on computational cost and scalability."
- "If you cannot prove a real win with numbers, return NVIME_NO_CHANGE."
- "Use Bash to create a scratch directory under /tmp."
- "NEVER write inside the user's repository."
- "Only if candidate is correct AND faster ... produce NVIME_DIFF."
- "You MAY emit one short BENCH line before the NVIME_* marker."

Plan author mode says:

- "You are an architect drafting a structured implementation plan."
- "You MUST NOT modify any source code."
- "You MAY create or edit files only inside `.nvime/plans/<plan-id>/`."
- "Decompose into ORDERED steps. Each step targets exactly ONE file and ONE range."
- "Acceptance items must be CHECKABLE — prefer commands and observable behavior."
- "Emit one final NVIME_PLAN marker confirming the plan id, summary, step count, and files."
