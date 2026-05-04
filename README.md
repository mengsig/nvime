# nvime

`nvime` means "no vibe coding in my editor".

It is a Neovim Lua plugin that routes Claude Code and Codex CLI through explicit engineering lanes:

- review/docs lane: broad repo inspection, shell/test output, Markdown docs writes only
- edit lane: one selected range or Tree-sitter detected function, one current file, written intent required
- generation lane: selected blank ranges can become new code/text, and selected non-code ranges such as `.gitignore` can be completed
- diff review: agent output becomes a current-file inline diff; accepted lines or blocks are applied by `nvime`
- guardrail lane: direct `claude`/`codex` launches from common Neovim process APIs are blocked and audited

This is an editor discipline tool, not a security sandbox. It prevents accidental YOLO use inside normal Neovim paths. It cannot stop an external terminal, a renamed binary, or a hostile plugin.

## Install

Use any Neovim package manager that can load this repository. With lazy.nvim:

```lua
{
  "mengsig/nvime",
  opts = {},
}
```

For local development from this checkout, use:

```lua
{
  dir = "/home/mengsig/Projects/nvime",
  name = "nvime",
  opts = {},
}
```

The plugin also auto-registers with defaults when it is on `runtimepath`, so
`opts = {}` is enough for lazy.nvim.

## Configuration

Defaults are intentionally usable without configuration:

```lua
require("nvime").setup({
  provider = "claude", -- "claude" or "codex"
  ui = {
    layout = "float", -- "float" or "split"
    side = "right",
  },
  keys = {
    enabled = true,
    prefix = "<leader>n",
  },
  audit = {
    enabled = true,
    path = nil, -- defaults to .nvime/audit.jsonl in a git repo
    log_prompts = false,
  },
  review = {
    allow_shell = true,
    allow_markdown_writes = true,
  },
  diff = {
    max_visual_block_lines = 12,
  },
  chat = {
    max_history_messages = 24,
  },
})
```

To disable shipped keymaps:

```lua
require("nvime").setup({
  keys = { enabled = false },
})
```

## Commands

- `:NvimeChat` opens the floating chat/docs panel.
- `:NvimeChats [ask|edit]` opens the picker for highlighted-code Ask/Edit discussions.
- `:NvimeReview [claude|codex] [prompt]` runs a review/docs session.
- `:NvimeAsk [claude|codex] <question>` asks the read-only side agent about the visual range or current function.
- `:'<,'>NvimeEdit [claude|codex] <intent>` asks for a reviewed edit for the visual range.
- `:NvimeEdit [claude|codex] <intent>` uses the Tree-sitter function at the cursor.
- `:NvimeProvider [claude|codex]` shows or changes the default provider.
- `:NvimeAccept` accepts the current inline diff block.
- `:NvimeReject` rejects the current inline diff block.
- `:NvimeAudit` opens `.nvime/audit.jsonl`.

## Chat Panel

`:NvimeChat` opens one floating terminal buffer and focuses the prompt at the
bottom. Status lives in the float title/footer rather than being written into
the transcript, so the buffer stays clean: messages, responses, and the active
`[provider]$` prompt. nvime guards the buffer so only the live prompt line can
be changed while typing.
Press `i` or `o` from anywhere in the chat to jump back to the prompt. Press
`<CR>` on the prompt to submit a review/docs chat message.

The chat lane keeps an in-memory transcript and sends that transcript with each
message, so follow-up questions keep context during the Neovim session. This is
one shared `nvime` conversation; switching from Claude to Codex sends the same
transcript to the newly selected provider.

While an agent is running, nvime streams visible progress events such as start
notifications, tool calls, command activity, and provider-supplied reasoning
summaries into the chat/selection buffer. These progress lines are not treated
as the final answer and are not fed into edit diff parsing.

By default the chat/review lane may run shell commands and may create or update
Markdown files (`*.md`, `*.markdown`). It runs providers in a temporary workspace
copy and syncs only Markdown changes back to the real repo. Source/config edits
still have to go through `NvimeEdit` and its reviewed diff flow.

Switch providers with:

```vim
:NvimeProvider codex
:NvimeProvider claude
```

Or use `<leader>np`.

Inside the chat window:

- `i`, `o`: jump to the prompt
- prompt `<CR>`: submit the current message
- `p`, `<Tab>`: cycle Claude/Codex for the next chat prompt
- `P`: choose Claude or Codex for the next chat prompt
- `q`: close the floating window

## Default Keymaps

`nvime` ships one conservative `<leader>n` namespace:

- `<leader>nc`: open chat panel
- `<leader>nr`: run review/docs
- `<leader>nq`: open the highlighted-code discussions picker
- visual `<leader>nq`: ask about selected code
- `<leader>ne`: open the highlighted-code discussions picker
- visual `<leader>ne`: edit selected range
- `<leader>na`: open audit log
- `<leader>nd`: discuss the active inline diff state
- `<leader>np`: choose Claude or Codex

Use `NvimeAsk` for questions such as "does this look right?" or "what does
this do?". Use `NvimeEdit` only when you want a concrete patch. If the edit
worker decides the selected code is already right, or if it returns code
identical to the original selection, `nvime` does not open a no-op diff.
Question-shaped `NvimeEdit` requests are routed to the read-only ask lane.
For generation, select the blank line or placeholder range where the new
content should go, then run visual `<leader>ne` and describe the function,
ignore entries, config snippet, comment, or other current-file text you want.
`NvimeAsk` and `NvimeEdit` keep workflow discussions per selected file/range,
while general chat stays in `nvime://chat`. When the same range already has a
discussion, visual `<leader>nq`/`<leader>ne` asks whether to continue it or
start a fresh session. Continuing a discussion uses the provider's native
session resume when nvime has captured a Claude/Codex session id; starting new
creates a separate nvime discussion and a separate provider session. The latest
ask result for the same file/range is included as context for the next edit
request on that selection. Normal `<leader>nq` and `<leader>ne` open an
intermediate picker with a new-session row plus existing discussions.
The selection workflow uses the same one-window terminal layout as chat. If you
run Ask/Edit without an inline prompt, nvime asks for the question or intent on
the guarded prompt line instead of opening a separate popup. After an Ask
answer, the same prompt stays armed for that selection: follow-up questions keep
using Ask, while "please proceed", "fix this", "apply that change", and similar
repair requests launch Edit on the same range without reselecting it.
Inside an open selection discussion, `p`/`<Tab>`/`P` switch the provider for
that active discussion's next prompt, while earlier Claude/Codex messages remain
in the shared scrollback for context.

## Inline Diff Review

Generated patches are rendered directly in the target file. nvime keeps the
review units line-level internally, but presents contiguous units as readable
change blocks: proposed green lines above, current red lines below, and one
compact control header per block. Large contiguous replacements are split into
review-sized blocks by default (`diff.max_visual_block_lines = 12`) so an
80-line rewrite is not one giant accept/reject target. The source buffer stays
editable during review.

Inline diff mappings in the target file:

- `]n` / `[n`: next or previous unresolved line
- `]b` / `[b`: next or previous visual change block
- `ga`: accept the current visual change block
- visual `ga`: accept every unresolved changed line touched by the visual range
- `gA`: accept all unresolved blocks
- `gb`: reject the current visual change block
- visual `gb`: reject every unresolved changed line touched by the visual range
- `gB`: reject all unresolved blocks
- `gc`: discuss the active diff state with the edit agent

`gc` sends the accepted lines, rejected lines, current line, and unresolved
lines to the edit agent. The agent can explain, suggest a change, or return an
updated `NVIME_DIFF`/`NVIME_REPLACEMENT`, which opens as a fresh inline review.

## Default Provider Calls

Selection Ask/Edit sessions are persisted so follow-ups can resume the native
provider conversation instead of resending the whole transcript. Claude starts a
persistent selection turn without `--no-session-persistence`, captures the
streamed `session_id`, and later resumes with:

```sh
claude -p "<prompt>" --output-format stream-json --verbose \
  --include-partial-messages --strict-mcp-config \
  --resume "$CLAUDE_SESSION_ID" --permission-mode dontAsk --tools ""
```

Claude review/docs mode runs in a temporary workspace copy. It allows
read/search tools, shell when `review.allow_shell = true`, and Markdown writes
when `review.allow_markdown_writes = true`; after exit, nvime syncs only
Markdown files back.

Codex selection follow-ups use:

```sh
codex exec resume --json --ignore-user-config --ignore-rules \
  --skip-git-repo-check "$CODEX_SESSION_ID" - < prompt.txt
```

Codex review/docs mode uses an ephemeral temporary workspace:

```sh
codex exec --json --ephemeral --ignore-user-config --ignore-rules \
  --skip-git-repo-check --color never -s workspace-write \
  -C "$TEMP_WORKSPACE" < prompt.txt
```

`nvime` never uses Claude/Codex bypass flags by default.

## Guardrails

`nvime` wraps common Neovim launch paths:

- `vim.system`
- `vim.fn.jobstart`
- `vim.fn.termopen`
- `vim.fn.system`
- `vim.fn.systemlist`
- `vim.uv.spawn`
- `TermOpen` detection and kill for blocked terminals

Direct Claude/Codex use inside these paths is denied unless it is launched by `nvime` itself. Every allow/deny is logged to `.nvime/audit.jsonl` by default.

## Test

```sh
./scripts/test
```

The test uses a fake local `claude` executable and runs headless Neovim end to end.
