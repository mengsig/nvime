# nvime

`nvime` means "No Vibe Coding In My Editor": no AI sprawl, no mystery edits, no bullshit.

It is a Neovim Lua plugin for getting real work done with Claude Code and Codex CLI through explicit engineering lanes:

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
  dir = "/path/to/nvime",
  name = "nvime",
  opts = {},
}
```

With lazy.nvim, `opts = {}` is enough because lazy calls `setup({})` for you.
If the plugin is loaded directly from `runtimepath`, `plugin/nvime.lua`
registers the defaults. Call `require("nvime").setup({ ... })` only when you
want to override them.

## Configuration

Defaults are intentionally usable without configuration. These are the current
defaults:

```lua
require("nvime").setup({
  provider = "claude", -- "claude" or "codex"
  providers = {
    claude = {
      cmd = "claude",
    },
    codex = {
      cmd = "codex",
    },
  },
  ui = {
    layout = "float", -- "float" or "split"
    width = 82,
    side = "right",
    height = 24,
    float_width = 0.82,
    float_height = 0.72,
    dashboard_width = 0.86,
    dashboard_height = 0.9,
    border = "rounded",
    backdrop = 60, -- false disables the dimmed dashboard backdrop
    completion = "notify", -- "notify" or "open" when a hidden agent finishes
    ascii_icons = false, -- set true for terminals without glyph support
    icons = {}, -- optional per-icon overrides
    spinner_frames = nil, -- optional custom frame list for running agents
  },
  audit = {
    enabled = true,
    path = nil, -- defaults to .nvime/audit.jsonl in a git repo
    log_prompts = false,
  },
  guard = {
    enabled = true,
    strict = true,
    notify = true,
    kill_blocked_terminals = true,
    block_cmdline = true,
    wrap_vim_system = true,
    wrap_jobstart = true,
    wrap_termopen = true,
    wrap_system_functions = true,
    wrap_uv_spawn = true,
  },
  review = {
    allow_shell = true,
    allow_web = true,
    allow_markdown_writes = true,
  },
  selection = {
    allow_shell = true,
    allow_web = true,
  },
  edit = {
    context_lines = 0,
  },
  diff = {
    max_visual_block_lines = 12,
  },
  chat = {
    max_history_messages = 24,
  },
  sessions = {
    enabled = true,
    path = nil, -- defaults to .nvime/selection-sessions.json in a git repo
    chat_path = nil, -- defaults to .nvime/chat-sessions.json in a git repo
    max = 100,
  },
  keys = {
    enabled = true,
    prefix = "<leader>n",
    normal = {
      dashboard = "<Space>",
      chat = "c",
      review = "r",
      edit = "e",
      ask = "q",
      audit = "a",
      discuss = "d",
      diff = "v",
      last = "n",
      provider = "p",
    },
    visual = {
      edit = "e",
      ask = "q",
    },
  },
  prompts = {
    general = {
      { label = "Review repository", prompt = "Please review this repository..." },
      { label = "Update docs", prompt = "Please inspect the repository and ensure the Markdown documentation is accurate..." },
      { label = "Explain architecture", prompt = "Please explain the repository architecture..." },
      { label = "Run tests", prompt = "Please run the relevant tests/checks..." },
    },
    selection = {
      { label = "Review selection", prompt = "Please review this selection..." },
      { label = "Explain selection", prompt = "Please explain what this selected code does..." },
      { label = "Suggest minimal diff", prompt = "Please suggest the smallest approvable diff..." },
      { label = "Proceed with fix", prompt = "Please proceed with the concrete fix..." },
    },
  },
})
```

Chat, selection, and discussion picker windows currently use floating scratch
buffers. `ui.layout` and `ui.side` are reserved defaults and do not select a
split layout in v0.1.0.

To disable shipped keymaps:

```lua
require("nvime").setup({
  keys = { enabled = false },
})
```

## Commands

- `:Nvime` opens the Mason-style nvime command center with recent chats,
  selection discussions, running state, tabs, and action rows.
- `:NvimeChat` opens the picker for general chat/review conversations.
- `:NvimeChats [chat|ask|edit]` opens the picker for general chat or highlighted-code Ask/Edit discussions.
- `:NvimeReview [claude|codex] [prompt]` runs a review/docs session and includes
  the current worktree diff by default.
- `:NvimeLast` reopens the last used general chat or Ask/Edit discussion.
- `:NvimeAsk [claude|codex] <question>` asks the read-only side agent about the visual range or current function.
- `:'<,'>NvimeEdit [claude|codex] <intent>` asks for a reviewed edit for the visual range.
- `:NvimeEdit [claude|codex] <intent>` uses the Tree-sitter function at the cursor.
- `:NvimeProvider [claude|codex]` shows or changes the default provider.
- `:NvimeAccept` accepts the current inline diff block.
- `:NvimeReject` rejects the current inline diff block.
- `:NvimeDiff` opens the active diff in a two-pane review workspace.
- `:NvimeAudit` opens `.nvime/audit.jsonl`.

## Chat Panel

`:Nvime` opens the command center: a Mason-style floating console with session
counts, running status, block-highlighted tabs, action rows, recent general
chats, recent Ask/Edit discussions, provider/native-resume badges, a dimmed
backdrop, and in-buffer help on `?` / `g?`. On the dashboard, `(1)`-`(5)`
switch the All, Chat, Ask, Edit, and Running tabs; in scoped pickers, `1`-`9`
still open visible session rows.
For statuslines, `require("nvime").statusline()` returns a compact summary such
as `nvime 2` or `nvime 1/3 running`.

`:NvimeChat` opens the general conversation picker. Press `n` to start a fresh
chat/review conversation, or open an older conversation from the list. Each
conversation opens as one floating scratch buffer with the prompt at the
bottom, focused in normal mode. Status lives in the float title/footer rather
than being written into the transcript, so the buffer stays clean: messages,
responses, and the active `[provider]$` prompt. nvime guards the buffer so only
the live prompt line can be changed while typing.
Press `i` or `o` from anywhere in the chat to jump back to the prompt. Press
`<CR>` on the prompt to submit a review/docs chat message.

The chat/review lane keeps a transcript and native provider session id per
general conversation. Same-provider follow-ups resume the native Claude/Codex
conversation; switching providers sends that conversation's nvime transcript so
the newly selected provider has the shared context. Review/docs runs reuse a
stable temporary workspace for the provider session, so project-local native
resumes resolve in the same workspace.

While an agent is running, nvime flushes progress events such as start
notifications, tool calls, command activity, and provider-supplied reasoning
summaries into the float footer/status area instead of appending them to the
transcript. Final answers and provider errors still appear in the buffer.

By default the chat/review lane may run shell commands, use web fetch/search,
and create or update Markdown files (`*.md`, `*.markdown`). Shell access also
allows command-line network tools such as `curl` when available on the machine.
It runs providers in a temporary workspace copy and syncs only Markdown changes
back to the real repo. Source/config edits still have to go through
`NvimeEdit` and its reviewed diff flow.

Switch providers with:

```vim
:NvimeProvider codex
:NvimeProvider claude
```

Or use `<leader>np`.

Inside the chat window:

- `i`, `I`, `a`, `A`, `o`, `O`: jump to the prompt
- `?`: choose a configured prompt template
- prompt `<CR>`: submit the current message
- `p`, `<Tab>`: cycle Claude/Codex for the next chat prompt
- `P`: choose Claude or Codex for the next chat prompt
- `<Esc>`: return focus to the scrollback
- `q`: close the floating window

## Default Keymaps

`nvime` ships one conservative `<leader>n` namespace:

- `<leader>n<Space>`: open the dashboard command center
- `<leader>nc`: open the general chat conversation picker
- `<leader>nr`: run review/docs
- `<leader>nq`: open the highlighted-code discussions picker
- visual `<leader>nq`: ask about selected code
- `<leader>ne`: open the highlighted-code discussions picker
- visual `<leader>ne`: edit selected range
- `<leader>na`: open audit log
- `<leader>nd`: discuss the active inline diff state
- `<leader>nv`: open the active diff review workspace
- `<leader>nn`: reopen the last used nvime conversation
- `<leader>np`: choose Claude or Codex

Use `NvimeAsk` for questions such as "does this look right?" or "what does
this do?". Use `NvimeEdit` only when you want a concrete patch. If the edit
worker decides the selected code is already right, or if it returns code
identical to the original selection, `nvime` does not open a no-op diff.
Question-shaped and review-shaped `NvimeEdit` requests are routed to the
read-only ask lane, so prompts like "nitpick this README" can report findings
before a later "please fix" turns them into a patch.
For generation, select the blank line or placeholder range where the new
content should go, then run visual `<leader>ne` and describe the function,
ignore entries, config snippet, comment, or other current-file text you want.
`NvimeAsk` and `NvimeEdit` keep workflow discussions per selected file/range,
while general chat keeps separate conversations in `nvime://chat/<id>` buffers.
Visual `<leader>nq`/`<leader>ne` asks whether to start fresh or continue an
older discussion. Exact range matches are listed first, then same-file
discussions, then recent repo discussions, so a newly highlighted range can
reuse context from a persisted conversation. Continuing a discussion uses the
provider's native session resume when nvime has captured a Claude/Codex session
id; starting new creates a separate nvime discussion and a separate provider
session. The latest ask result for the same file/range is included as context
for the next edit request on that selection. Normal `<leader>nq` and
`<leader>ne` open an intermediate picker with a new-session row plus existing
discussions.
General chat conversations are persisted by default in `.nvime/chat-sessions.json`;
selection discussions are persisted by default in `.nvime/selection-sessions.json`.
Both live inside the current git root, so the pickers can show older sessions
after restarting Neovim. In a picker, press `1`-`9` to open a numbered row,
`<CR>` to open the cursor row, `dd` to delete the current row, or visual-select
rows with `V` and press `d` to delete several.
If an agent finishes while its float is closed, `ui.completion = "notify"`
raises a notification instead of reopening the window. Set `ui.completion =
"open"` to restore pop-open behavior. `:NvimeLast` or `<leader>nn` reopens the
last used chat or selection discussion.
The selection workflow uses the same one-window scratch-buffer layout as chat. If you
run Ask/Edit without an inline prompt, nvime asks for the question or intent on
the guarded prompt line instead of opening a separate popup. After an Ask
answer, the same prompt stays armed for that selection: follow-up questions keep
using Ask, while "please proceed", "fix this", "suggest the diff", "apply that
change", and similar repair requests launch Edit on the same range without
reselecting it. If an Ask response already contains an approvable
`NVIME_DIFF`/`NVIME_REPLACEMENT` or current-file unified diff, nvime opens it as
an inline review instead of leaving it as inert chat text.
Inside an open selection discussion, `p`/`<Tab>`/`P` switch the provider for
that active discussion's next prompt, while earlier Claude/Codex messages remain
in the shared scrollback for context.

Inside an open selection discussion:

- `i`, `I`, `a`, `A`, `o`, `O`: jump to the prompt
- `?`: choose a configured prompt template
- prompt `<CR>`: submit the current message
- `p`, `<Tab>`: cycle Claude/Codex for the next selection prompt
- `P`: choose Claude or Codex for the next selection prompt
- `<Esc>`: return focus to the scrollback
- `q`: close the floating window

## Inline Diff Review

Generated patches are rendered directly in the target file. Edit prompts prefer
minimal `NVIME_DIFF` hunks for existing text, especially Markdown and large
selections, instead of reproducing the whole selected file. nvime keeps the
review units line-level internally, but presents contiguous units as readable
change blocks: proposed green lines above, current red lines below, and one
compact control header per block. Large contiguous replacements are split into
review-sized blocks by default (`diff.max_visual_block_lines = 12`) so an
80-line rewrite is not one giant accept/reject target. The source buffer stays
editable during review.

Inline diff mappings in the target file:

- `:NvimeDiff` / `<leader>nv`: open the review workspace with proposed and
  editable panes in native diff mode
- `]n` / `[n`: next or previous unresolved line
- `]b` / `[b`: next or previous visual change block
- `ga`: accept the current visual change block
- visual `ga`: accept every unresolved changed line touched by the visual range
- `gA`: accept all unresolved blocks
- `gb`: reject the current visual change block
- visual `gb`: reject every unresolved changed line touched by the visual range
- `gB`: reject all unresolved blocks
- `gc`: discuss the active diff state with the edit agent

Inside the review workspace, the left pane shows the full proposed result and
the right pane is the live source buffer with inline diff overlays. The right
pane stays normally editable; the proposed pane maps `e` to jump back to the
editable file and `r` to refresh. `q` closes the workspace from either pane and
returns to the tab you came from.

Compatibility aliases are also installed: `gr` rejects the current line change,
visual `gr` rejects selected line changes, `gR` rejects all, and `gX` rejects the current visual change block.

`gc` sends the accepted lines, rejected lines, current line, and unresolved
lines to the edit agent. The agent can explain, suggest a change, or return an
updated `NVIME_DIFF`/`NVIME_REPLACEMENT`, which opens as a fresh inline review.

## Default Provider Calls

General chat/review and Selection Ask/Edit sessions resume the native provider
conversation instead of resending the whole transcript when nvime has captured a
provider session id. Selection lanes may use read/search tools and shell
commands for inspection/tests when `selection.allow_shell = true`, and web
fetch/search tools when `selection.allow_web = true`. Direct provider writes are
disallowed:

```sh
claude -p "<prompt>" --output-format stream-json --verbose \
  --include-partial-messages --strict-mcp-config \
  --resume "$CLAUDE_SESSION_ID" --permission-mode dontAsk \
  --tools Read,Glob,Grep,LS,WebFetch,WebSearch,Bash \
  --allowedTools Read,Glob,Grep,LS,WebFetch,WebSearch,Bash \
  --disallowedTools Edit,Write,MultiEdit,NotebookEdit
```

Claude starts a persistent selection turn without `--no-session-persistence`,
captures the streamed `session_id`, and later resumes with `--resume`.

Claude review/docs mode runs in a temporary workspace copy. It allows
read/search tools, web fetch/search when `review.allow_web = true`, shell
including `curl` when `review.allow_shell = true`, and Markdown writes when
`review.allow_markdown_writes = true`; after exit, nvime syncs only Markdown
files back.

Codex starts persistent selection turns without `--ephemeral` and with a
read-only sandbox:

```sh
codex exec --json --ignore-user-config --ignore-rules \
  --skip-git-repo-check --color never -s read-only \
  -C "$REPO_ROOT" < prompt.txt
```

Codex selection follow-ups resume that native session:

```sh
codex exec resume --json --ignore-user-config --ignore-rules \
  --skip-git-repo-check "$CODEX_SESSION_ID" - < prompt.txt
```

Codex review/docs mode uses an ephemeral temporary workspace. With Markdown
writes enabled, it uses a workspace-write sandbox:

```sh
codex exec --json --ephemeral --ignore-user-config --ignore-rules \
  --skip-git-repo-check --color never -s workspace-write \
  -C "$TEMP_WORKSPACE" < prompt.txt
```

`nvime` never uses Claude/Codex bypass flags by default.
When `review.allow_markdown_writes = false`, Codex review/docs mode uses
`-s read-only` instead.


## Guardrails

`nvime` wraps common Neovim launch paths:

- `vim.system`
- `vim.fn.jobstart`
- `vim.fn.termopen`
- `vim.fn.system`
- `vim.fn.systemlist`
- `vim.uv.spawn`
- `TermOpen` detection and kill for blocked terminals

- command-line detection via `CmdlineLeave` when `guard.block_cmdline = true`
Direct Claude/Codex use inside these paths is denied unless it is launched by `nvime` itself. Every allow/deny is logged to `.nvime/audit.jsonl` by default.

## Test

```sh
./scripts/test
```

The test uses a fake local `claude` executable and runs headless Neovim end to end.
