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

-- Pull the structured intake PLAN out of an agent response. The agent wraps
-- its clarifying questions in <PLAN>…</PLAN> as a JSON object:
--   { "summary": "...", "questions": [ {
--       "id": "...", "prompt": "...",
--       "kind": "single"|"multi"|"text",
--       "options": [ {"label":"...","detail":"..."} ],
--       "recommended": [<int>...], "allow_custom": <bool> } ] }
-- Returns the decoded table (questions normalized to a list), or nil.
function M.extract_plan(text)
  if not text then
    return nil
  end
  local body = text:match("<PLAN>(.-)</PLAN>")
  if not body then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, vim.trim(body))
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  if type(decoded.questions) ~= "table" then
    decoded.questions = {}
  end
  return decoded
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
-- The shared protocol block that teaches the agent how to emit a structured
-- plan (selectable options) or the final spec. Used by both the kickoff and the
-- follow-up prompts so the format never drifts between turns.
local INTAKE_PROTOCOL = {
  "You drive a PLANNING UI (think Claude Code's plan mode): instead of free-form",
  "prose questions, you present the user with structured DECISIONS they resolve by",
  "picking options, so planning is fast and concrete.",
  "",
  "Each turn you MUST output exactly ONE of:",
  "",
  "1) A PLAN of clarifying decisions, wrapped EXACTLY in <PLAN> and </PLAN> as JSON:",
  '   {',
  '     "summary": "one or two sentences on what you now understand / are deciding",',
  '     "questions": [',
  '       {',
  '         "id": "kebab-id",',
  '         "prompt": "the decision, phrased plainly",',
  '         "kind": "single" | "multi" | "text",',
  '         "options": [ {"label": "short label", "detail": "one-line tradeoff"} ],',
  '         "recommended": [<0-based option index you suggest>],',
  '         "allow_custom": true',
  '       }',
  '     ]',
  "   }",
  '   - kind "single": pick exactly one option. kind "multi": pick k of N.',
  '   - kind "text": no options; a free-text answer (omit "options").',
  "   - Give 2-5 options with REAL tradeoffs; mark a sensible default in recommended.",
  "   - Ask only what you cannot decide yourself from the repo. 1-4 questions per turn.",
  "   - Put NOTHING outside the <PLAN></PLAN> tags.",
  "",
  "2) The final implementation SPEC, wrapped EXACTLY in <SPEC> and </SPEC> (markdown:",
  "   Goal, Scope (in/out), Files & modules, Data shapes / APIs, Step-by-step plan,",
  "   Acceptance criteria). Emit this ONLY when every decision is settled and the build",
  "   is unambiguous. Put nothing outside the tags.",
  "",
  "Read the repository freely to ask informed questions and to ground the spec.",
}

function M.intake_kickoff_prompt(session)
  local lines = {
    "You are in INTAKE mode for a large feature that ANOTHER agent will implement fully",
    "autonomously afterward. Interrogate the user until EVERYTHING needed to implement",
    "this is crystal clear — leave nothing to the imagination.",
    "",
  }
  vim.list_extend(lines, INTAKE_PROTOCOL)
  vim.list_extend(lines, {
    "",
    "The user wants to build:",
    "<goal>",
    session.goal or "(no goal given)",
    "</goal>",
    "",
    "Emit your first <PLAN> of decisions now (or the <SPEC> if it is already fully",
    "unambiguous and confirmed against the repo).",
  })
  return table.concat(lines, "\n")
end

-- Follow-up turn: the user has resolved the previous PLAN. `decisions` is the
-- preformatted, human-readable summary of their selections + notes.
function M.intake_followup_prompt(decisions)
  local lines = {
    "The user resolved your previous decisions:",
    "",
    decisions or "(no selections)",
    "",
    "Incorporate these. If anything is still ambiguous, emit another <PLAN>; otherwise",
    "emit the final <SPEC>. Follow the same protocol:",
    "",
  }
  vim.list_extend(lines, INTAKE_PROTOCOL)
  return table.concat(lines, "\n")
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
