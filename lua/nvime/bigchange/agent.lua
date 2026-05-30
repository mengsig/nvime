-- nvime.bigchange.agent
--
-- Thin wrapper over nvime.agents for the Big Change lane. Provides a
-- text-collecting single-turn helper plus the prompt builders and structured
-- extractors (spec / JSON) the intake, build and grading flows share.
--
-- Session continuity: every turn runs with persist_session=true and resumes
-- the provider session stored on the Big Change session, so intake Q&A, the
-- build, and grading rounds all share ONE conversation — cheap on tokens and
-- the agent keeps full context of what it built and why.

local agents = require("nvime.agents")
local store = require("nvime.bigchange.store")

local M = {}

-- Provider session buckets are scoped by cwd. Claude/Codex store sessions per
-- project directory, so an intake session (run in the repo root) CANNOT be
-- resumed from the build worktree. We therefore keep two buckets:
--   scope "intake"   → session.provider_sessions  (runs in the repo root)
--   scope "worktree" → session.worktree_sessions   (runs in the build worktree)
local function session_bucket(session, scope)
  if scope == "worktree" then
    session.worktree_sessions = session.worktree_sessions or {}
    return session.worktree_sessions
  end
  session.provider_sessions = session.provider_sessions or {}
  return session.provider_sessions
end

-- Run one agent turn, then invoke opts.on_done(text, result) (already on the
-- main loop via agents.run's scheduled on_exit).
--   opts = { session, lane, cwd, prompt, resume=bool, scope="intake"|"worktree",
--            on_progress, on_done, on_handle, keep_all_text=bool }
--
-- By default `text` is the agent's FINAL text block — the text emitted after
-- its last tool use. When the agent (e.g. the read-only intake lane) narrates,
-- reads files, then restates a refined answer, this keeps only the refined one
-- instead of concatenating both into a doubled-looking message. The final
-- block is also exactly what the JSON/spec extractors want. Pass
-- keep_all_text=true to get the full concatenation instead.
function M.turn(opts)
  local session = opts.session
  local provider = session.provider or "claude"
  local bucket = session_bucket(session, opts.scope)
  local resume_id = opts.resume and bucket[provider] or nil
  -- Text accumulates into segments split on tool-use boundaries.
  local segments = { "" }
  return agents.run({
    provider = provider,
    lane = opts.lane,
    cwd = opts.cwd,
    prompt = opts.prompt,
    persist_session = true,
    resume_session_id = resume_id,
    on_text = function(text)
      segments[#segments] = segments[#segments] .. text
    end,
    on_progress = function(line)
      -- A tool ran: text before it is interim narration; start a new segment so
      -- only the post-last-tool block survives as the agent's final answer.
      if line and line:find("tool:", 1, true) and segments[#segments] ~= "" then
        segments[#segments + 1] = ""
      end
      if opts.on_progress then
        opts.on_progress(line)
      end
    end,
    on_session_id = function(id)
      if id and id ~= "" then
        bucket[provider] = id
        store.touch(session)
      end
    end,
    on_handle = opts.on_handle,
    on_exit = function(result)
      local text
      if opts.keep_all_text then
        text = table.concat(segments)
      else
        for i = #segments, 1, -1 do
          if vim.trim(segments[i]) ~= "" then
            text = segments[i]
            break
          end
        end
        text = text or table.concat(segments)
      end
      local ok, err = pcall(opts.on_done, text, result)
      if not ok then
        vim.notify("nvime bigchange: turn handler failed: " .. tostring(err), vim.log.levels.ERROR)
      end
    end,
  })
end

-- ---------------------------------------------------------------------------
-- extractors
-- ---------------------------------------------------------------------------
function M.extract_spec(text)
  if not text then
    return nil
  end
  local spec = text:match("<SPEC>(.-)</SPEC>")
  if spec then
    return vim.trim(spec)
  end
  return nil
end

-- Pull a JSON object/array out of an agent response. Accepts a <JSON>…</JSON>
-- envelope (what we ask for), a ```json fence, or a bare decodable body.
function M.extract_json(text)
  if not text then
    return nil
  end
  local body = text:match("<JSON>(.-)</JSON>") or text:match("```json%s*(.-)```") or text:match("```%s*(.-)```")
  if not body then
    -- Last resort: first {...} or [...] span.
    body = text:match("(%b{})") or text:match("(%b[])")
  end
  if not body then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, vim.trim(body))
  if ok then
    return decoded
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- prompt builders
-- ---------------------------------------------------------------------------
function M.intake_kickoff_prompt(session)
  return table.concat({
    "You are in INTAKE mode for a large feature that ANOTHER agent will then implement",
    "fully autonomously. Your job is to interrogate the user until EVERYTHING needed to",
    "implement this is crystal clear — leave nothing to the imagination.",
    "",
    "Rules:",
    "- Ask ONE focused topic at a time (a few tightly-related questions are fine). Wait",
    "  for the answer before moving on.",
    "- Read the repository freely to ask informed questions; never ask what you can",
    "  determine yourself from the code.",
    "- Cover scope, files/modules, data shapes, APIs, edge cases, error handling, and",
    "  acceptance criteria.",
    "- When — and ONLY when — you have no remaining questions, output the final",
    "  implementation spec wrapped EXACTLY in <SPEC> and </SPEC> tags. The spec is",
    "  markdown with sections: Goal, Scope (in/out), Files & modules, Data shapes / APIs,",
    "  Step-by-step plan, Acceptance criteria. Do NOT emit <SPEC> until you are confident.",
    "- Until the spec is ready, reply with ONLY your question(s) — no preamble.",
    "",
    "The user wants to build:",
    "<goal>",
    session.goal or "(no goal given)",
    "</goal>",
    "",
    "Ask your first clarifying question now (or emit the spec if it is already fully",
    "unambiguous and confirmed against the repo).",
  }, "\n")
end

function M.build_prompt(session)
  return table.concat({
    "You are now in BUILD mode. Implement the feature described by the approved spec",
    "below, fully and autonomously, in the current working directory (an isolated git",
    "worktree). You have full tool access.",
    "",
    "Requirements:",
    "- Implement everything in the spec. Match the surrounding code's style and idioms.",
    "- Run the project's tests/build if present and fix what you break.",
    "- Do NOT git commit and do NOT git push. Leave all changes in the working tree.",
    "- When done, output a SHORT (<=5 line) summary of what you changed. No spec dump.",
    "",
    "<spec>",
    session.spec or session.goal or "",
    "</spec>",
  }, "\n")
end

return M
