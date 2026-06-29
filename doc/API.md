# nvime — Lua API Reference

Auto-generated from tree-sitter symbol extraction over `lua/nvime/*.lua` and
`plugin/nvime.lua`. Line ranges are `start–end` in the source file at the time
this document was produced. Anonymous closures and most internal helpers nested
inside `M.*` functions are omitted; see the source for those.

Two sections per module:

- **Public API** — `M.*` exports (the programmable surface).
- **Local helpers** — file-local named functions, useful when reading or
  patching the module.

Modules with no `M.*` exports (data tables, plugin loaders) are listed at the
end.

---

## `nvime` (lua/nvime/init.lua)

Top-level entry point. `setup()` wires user commands, keymaps, autocmds, and
state.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.open_last` | 62–97 | Reopen the most recently used panel. |
| `M.statusline` | 99–135 | Build the nvime statusline component string. |
| `M.cancel` | 205–223 | Cancel the active provider job. |
| `M.disable` | 225–240 | Disable nvime in the current session. |
| `M.enable` | 242–253 | Re-enable nvime after `M.disable`. |
| `M.setup` | 255–614 | Validate config, install commands/keymaps/autocmds. |
| `M.edit` | 616–618 | Public alias for `nvime.edit.start`. |
| `M.review` | 620–622 | Public alias for `nvime.review.start`. |

### Local helpers
`delete_keymaps` (11), `set_keymap` (18), `visual_edit` (32), `visual_ask`
(47), `install_keymaps` (137), `parse_provider` (184), `command_opts` (193).

---

## `nvime.agents` (lua/nvime/agents.lua)

Spawns and parses external provider CLIs (Claude / Codex). Owns workspace
preparation for plan-bound runs.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.run` | 804–961 | Launch a provider job, attach parsers, route output to the panel. |

### Local helpers
Provider tool-allowlists: `claude_read_tools`, `claude_disallowed_tools`,
`claude_web_disallowed_tools`, `claude_nonreview_disallowed`,
`claude_review_disallowed`, `claude_review_tools`, `claude_plan_tools`,
`claude_plan_disallowed`, `claude_selection_tools` (57–137).
Argv builders: `claude_args` (139), `codex_args` (245), `build_args` (297).
Workspace prep: `mkdir_p`, `normalize_dir`, `ensure_workspace_git_root`,
`copy_file`, `copy_tree`, `copy_plans_into_workspace`, `is_markdown`,
`same_file`, `collect_markdown`, `collect_plan_files`,
`prepare_plan_workspace`, `sync_plan_workspace`, `prepare_markdown_workspace`,
`cleanup_workspace`, `sync_markdown_workspace` (324–539).
Output: `tool_detail` (541), `tool_progress` (560), `parse_claude` (569),
`parse_codex` (626), `parser_for` (699), `is_provider_noise` (711),
`consume_chunks` (718).
Misc: `provider_config` (12), `repo_root` (21), review/selection capability
checks (26–55).

---

## `nvime.ask` (lua/nvime/ask.lua)

Selection-based "ask the model" flow. Builds a prompt from the current
selection and routes the response into the selection panel.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.start` | 252–321 | Begin an ask flow for the current selection. |
| `M._build_prompt` | 323 | Test/evaluation hook for the read-only selection prompt. |
| `M._wants_edit_followup` | 324 | Test hook for ask-to-edit follow-up routing. |

### Local helpers
`current_path` (10), `build_prompt` (21), `has_word` (78), `has_negation` (85),
`wants_edit_followup` (94), `response_has_patch` (119), `arm_followup` (130).

---

## `nvime.attribution` (lua/nvime/attribution.lua)

Per-line authorship ledger written by accepted diffs. Backs the blame
overlay and `nvime_search_attribution` MCP tool.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.path` | 164–166 | Path to `.nvime/attribution.json`. |
| `M.read` | 168–170 | Load the full ledger. |
| `M.record` | 172–204 | Append an entry for a file/line range. |
| `M.for_line` | 209–227 | Look up entries containing a given line. |
| `M.for_file` | 229–241 | All entries for a file. |
| `M.show_at_cursor` | 338–361 | Open the blame popup at cursor. |
| `M.toggle_overlay` | 415–426 | Toggle inline rationale overlay. |
| `M._build_anchor` | 428–430 | Test hook for anchor construction. |
| `M._locate_anchor` | 432–434 | Test hook for anchor lookup. |

### Local helpers
`attribution_path` (25), `max_entries` (37), `ensure_dir` (42), `read_ledger`
(47), `write_ledger` (64), `build_anchor` (104), `locate_anchor` (121),
`generate_id` (158), `format_entry` (243), `close_blame_popup` (258),
`open_blame_popup` (272), `build_blame_lines` (320), `clear_overlay` (366),
`paint_overlay` (371).

---

## `nvime.audit` (lua/nvime/audit.lua)

Append-only `.nvime/audit.jsonl` writer. All side-effecting operations route
through here for traceability.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.path` | 105–107 | Path to the audit log. |
| `M.clear_cache` | 109–112 | Drop cached git metadata. |
| `M.write` | 114–171 | Append a redacted JSON event line. |
| `M.open` | 173–175 | Open the audit log in a buffer. |

### Local helpers
`now` (10), `cached_git_root` (14), `git_value` (28), `cached_git_meta` (41),
`audit_path` (59), `redact` (74), `disable_writes` (94).

---

## `nvime.buffer_guard` (lua/nvime/buffer_guard.lua)

Prevents external writes to nvime-owned buffers (chat, diff, plan UI) while
the model is streaming.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.sync` | 23–28 | Snapshot current buffer lines. |
| `M.suspend` | 30–39 | Temporarily allow writes (returns a restore fn). |
| `M.enforce` | 41–99 | Reject foreign writes; restore guarded content. |
| `M.attach` | 101–136 | Install autocmds on a buffer. |

### Local helpers
`copy_lines` (3), `lines_equal` (11).

---

## `nvime.chat` (lua/nvime/chat.lua)

Full chat panel: scrollback + input window, multi-session state,
spinner/busy indicator, history persistence, and provider job lifecycle.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.close` | 312–314 | Close the chat panel windows. |
| `M.open` | 978–1036 | Open or focus the chat panel. |
| `M.refresh` | 1038–1056 | Re-render header/winbar. |
| `M.agent_run_opts` | 1231–1249 | Build `agents.run` options for the active session. |
| `M.set_busy` | 1311–1330 | Toggle the busy state + spinner. |
| `M.set_progress` | 1332–1350 | Update the progress label under the spinner. |
| `M.attach_process` | 1374–1377 | Track the active provider job per session. |
| `M.clear_process` | 1379–1382 | Drop a tracked job (on completion). |
| `M.cancel_session` | 1395–1422 | Kill the job for a specific session. |
| `M.cancel_active` | 1424–1426 | Kill the job for the active session. |
| `M.cancel_all` | 1428–1436 | Kill jobs across all sessions. |
| `M.append` | 1438–1447 | Append text to scrollback. |
| `M.append_user` | 1449–1459 | Append a user message block. |
| `M.append_response_header` | 1461–1471 | Begin a model response block. |
| `M.submit` | 1473–1589 | Submit the input prompt to the provider. |
| `M.insert_prompt` | 1591–1596 | Insert a saved prompt template into input. |
| `M.choose_prompt` | 1598–1602 | Picker for prompt templates. |
| `M.prompt` | 1604–1630 | Programmatic prompt insertion entry point. |
| `M.submit_current` | 1632–1648 | Submit whatever is currently typed. |
| `M.active_session_id` | 1650–1652 | ID of the focused session. |
| `M.is_open` | 1654–1656 | Whether the panel windows exist. |
| `M.get_session` | 1658–1660 | Fetch a session by id. |
| `M.winbar_text` | 1662–1709 | Render the winbar string. |
| `M.sessions` | 1711–1723 | List sessions for the picker. |
| `M.session_count` | 1725–1727 | Number of sessions. |
| `M.new_session` | 1729–1740 | Create a fresh chat session. |
| `M.open_session` | 1742–1755 | Switch to a session by id. |
| `M.rename_session` | 1757–1770 | Rename a session. |
| `M.delete_sessions` | 1772–1824 | Bulk-delete sessions. |
| `M.save_sessions` | 1826–1828 | Force a debounced save. |
| `M.flush_sessions` | 1830–1833 | Synchronous flush to disk. |
| `M.reload_sessions` | 1835–1847 | Reload from disk. |
| `M.sessions_path` | 1849–1851 | Path to `chat-sessions.json`. |
| `M._build_conversation_prompt` | 1854 | Test/evaluation hook for the general chat prompt. |

### Local helpers
Persistence: `sessions_config`, `sessions_enabled`, `sessions_path`,
`notify_persist_error`, `persisted_lines`, `serializable_session`,
`public_session`, `save_sessions_now`, `schedule_save_sessions`,
`migrate_sessions`, `load_sessions` (27–234).
Buffer/window: `find_buffer_by_name`, `set_scratch_options`,
`ensure_named_buffer`, `session_buffer_name`, `sync_legacy_to_session`,
`sync_session_to_legacy`, `ensure_sessions`, `summarize_title`,
`touch_session`, `ensure_session_buffer`, `create_session`,
`ensure_active_session`, `sync_active_panel_to_session`, `panel_for_session`,
`delete_named_buffer`, `set_locked`, `with_writable`, `dimensions`, `title`
(316–584).
Scroll/input: `scroll_config`, `configure_scrollback_window`,
`extract_prompt_text`, `current_input_text`, `prompt_has_submit_text`,
`decorate_scrollback`, `decorate_input`, `scroll_to_bottom`,
`save_window_view`, `restore_window_view`, `view_is_at_bottom`,
`cursor_is_on_prompt`, `should_auto_scroll`, `refresh_header`, `reset_input`,
`refresh_input`, `open_or_configure_window`, `in_input_window`,
`focus_scrollback`, `attach_focus_lock`, `attach_input_guard`, `attach_panel`
(586–976).
Spinner/append: `stop_spinner_timer`, `refresh_input_indicator`,
`ensure_spinner_timer`, `append_scrollback`, `append_user_message`,
`append_response_header`, `trim_history`, `mark_provider_session`,
`append_transcript`, `build_conversation_prompt` (1060–1309).
Process: `clear_session_process`, `remember_session_process`, `kill_process`
(1352–1393).

---

## `nvime.chats` (lua/nvime/chats.lua)

Chat dashboard / picker UI — backdrop window with a list of sessions and
keymaps for open / new / delete / rename.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.open` | 1153–1205 | Open the dashboard. |

### Local helpers
Window plumbing: `find_buffer_by_name`, `ensure_buffer`, `set_locked`,
`dimensions`, `window_config`, `configure_window`, `close_backdrop`,
`open_backdrop`, `close`, `open_help` (25–313).
Render helpers: `format_range`, `native_text`, `requested_mode`,
`is_chat_mode`, `is_dashboard`, `count_running`, `count_all_running`,
`render_width`, `add_mark`, `centered_prefix`, `add_centered_blocks`,
`add_centered_text`, `dashboard_tab`, `add_branded_header`,
`add_dashboard_tabs`, `add_count_mark`, `session_mode`, `session_title`,
`provider_label`, `session_primary_line`, `session_detail_line`,
`include_dashboard_session`, `add_dashboard_rows`,
`filtered_dashboard_sessions`, `add_dashboard_help`, `render` (315–925).
Selection ops: `selected_item`, `selected_session_refs`, `open_selected`,
`open_number`, `open_new`, `delete_selected`, `rename_selected`, `attach_maps`
(927–1151).

---

## `nvime.config` (lua/nvime/config.lua)

User-config validation and merge into the default config.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.validate` | 430–437 | Validate a user config against the schema. |
| `M.resolve` | 451–454 | Merge user config onto defaults. |

### Local helpers
`is_list` (244), `type_label` (279), `matches_type` (286),
`validate_with_vim` (304), `warn` (328), `validate_leaf` (332),
`validate_provider` (339), `validate_prompt_entry` (355), `validate_prompts`
(370), `validate_icons` (387), `validate_table` (397), `merge` (439).

---

## `nvime.critic` (lua/nvime/critic.lua)

Second-pass review pass that judges a generated diff before it is shown to
the user.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.review` | 164–253 | Run the critic pass on a session diff. |

### Local helpers
`build_critic_prompt` (42), `parse_verdict` (75), `diff_text_from_session`
(127), `context_from_session` (144).

---

## `nvime.diff` (lua/nvime/diff.lua)

The core diff-review surface: parses provider hunks, builds the side-by-side
review buffer, and exposes accept/reject operations.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.start_session` | 1475–1591 | Begin a review session from raw provider output. |
| `M.open_view` | 1620–1673 | Open the review window. |
| `M.focus_editable` | 1675–1686 | Move focus to the editable side. |
| `M.refresh_view` | 1688–1694 | Re-render the review buffer. |
| `M.close_view` | 1696–1717 | Close the review windows. |
| `M.undo_last_accept` | 1929–1971 | Revert the most recently accepted block. |
| `M.accept_blocks` | 1973–2005 | Accept a list of hunk blocks. |
| `M.reject_blocks` | 2007–2022 | Reject a list of hunk blocks. |
| `M.accept_hunks` | 2024–2044 | Accept hunks (parent grouping). |
| `M.reject_hunks` | 2046–2060 | Reject hunks. |
| `M.accept_current` | 2062–2068 | Accept the block under cursor. |
| `M.accept_selection` | 2070–2077 | Accept blocks in visual selection. |
| `M.reject_current` | 2079–2085 | Reject the block under cursor. |
| `M.reject_selection` | 2087–2094 | Reject visual selection. |
| `M.accept_current_group` | 2096–2107 | Accept the surrounding group. |
| `M.reject_current_group` | 2109–2120 | Reject the surrounding group. |
| `M.accept_all` | 2122–2143 | Accept everything. |
| `M.reject_all` | 2145–2151 | Reject everything. |
| `M.next_change` | 2173–2187 | Move to next block. |
| `M.next_group` | 2189–2203 | Move to next group. |
| `M.prev_change` | 2205–2220 | Move to previous block. |
| `M.prev_group` | 2222–2237 | Move to previous group. |
| `M.remaining_text` | 2259–2294 | Serialize unresolved hunks back into provider format. |
| `M.refresh_session` | 2298–2302 | Reparse the session text. |

### Local helpers
Parsing: `diff_config`, `max_visual_block_lines`, `split_lines`,
`count_pattern`, `bracket_balance`, `bracket_drift`, `has_bracket_drift`,
`bracket_drift_summary`, `response_likely_truncated`, `fence_marker`,
`closing_fence_marker`, `fenced_body`, `strip_fence`, `has_fence`, `trim`,
`normalize_mode_boundaries`, `response_mode`, `fenced_diff_body`,
`same_lines`, `line_slice`, `copy_lines`, `is_unresolved`, `extract_unified`,
`has_ranged_hunk`, `locate_sequence`, `unranged_diff_lines`,
`build_unranged_hunk`, `parse_hunks`, `dedupe_hunks`, `clean_diff_path`,
`validate_current_file`, `hunk_old_new_lines`, `hunk_has_change`,
`sequence_at`, `reanchor_hunks`, `hunks_have_changes`, `group_summary`,
`parse_hunk_blocks` (9–656).
Block model: `build_blocks`, `update_hunk_status`, `target_line_count`,
`block_start_line`, `block_range`, `current_file_window`, `focus_target`,
`install_buffer_maps`, `block_visual_size`, `block_lines`,
`block_has_blank_line`, `first_nonblank_line`, `indent_width`,
`starts_section`, `pending_visual_groups`, `count_block_statuses`,
`set_lines_unlocked`, `apply_blocks_to_lines` (658–978).
Render: `original_lines`, `proposed_lines`, `review_name`,
`configure_review_buffer`, `ensure_review_buffer`, `set_review_winbar`,
`configure_review_window`, `valid_review`, `set_review_widths`,
`target_review_text_width`, `clip_review_text`, `refresh_review_view`,
`install_review_maps`, `render_visual_group`, `render_session`,
`build_single_hunk`, `extract_rationale` (980–1473).
Selection ops: `install_target_close_map`, `uninstall_target_close_map`,
`selected_lines`, `pending_blocks`, `blocks_in_range`, `current_block`,
`current_group`, `mark_conflict`, `live_block_matches`, `apply_block`,
`reject_block`, `remove_last_applied_delta`, `jump_to_block`,
`jump_to_group`, `block_state_lines` (1593–2257).

---

## `nvime.digest` (lua/nvime/digest.lua)

Periodic activity summary panel — reads the audit log and renders a recap.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.read_events` | 36–66 | Parse audit lines into events. |
| `M.summarize` | 80–138 | Aggregate events into a summary table. |
| `M.force_review` | 140–148 | Pull "force review" prompts from audit. |
| `M.show_summary` | 535–549 | Open the digest panel. |
| `M.show_force_review` | 551–563 | Open the force-review panel. |

### Local helpers
`parse_iso_ts` (18), `ensure_counts` (68), `relative_time` (73), `pad_right`
(150), `sorted_pairs` (159), `render_digest` (170), `render_force_review`
(324), `dimensions` (370), `open_backdrop` (387), `close_backdrop` (434),
`close_panel` (442), `open_panel` (451).

---

## `nvime.edit` (lua/nvime/edit.lua)

Selection-based edit flow: prompts the model for a patch, hands the result
to `nvime.diff`.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.start` | 732–832 | Begin an edit flow over a selection. |
| `M.continue_remaining` | 834–950 | Resume an edit when prior diff was partially applied. |
| `M._build_prompt` | 952 | Test/evaluation hook for the edit prompt builder. |
| `M._build_perf_prompt` | 953 | Test/evaluation hook for the perf prompt builder. |
| `M._looks_like_question` | 954 | Test hook for edit-vs-ask routing. |

### Local helpers
`code_fence_for` (10), `current_path` (20), `selection_body_and_fence` (31),
`edit_config` (41), `context_enabled` (45), `root_dir` (49), `rel_join` (59),
`normalize_rel` (66), `root_relative` (82), `readable_rel` (104),
`add_unique` (112), `related_test_files` (121), `detected_test_runner` (165),
`append_file_excerpt` (220), `append_symbol_context` (241),
`append_recent_diff_context` (282), `build_project_context` (326),
`build_perf_prompt` (357), `build_prompt` (418), `looks_like_question` (508),
`submit_edit` (535), `arm_edit_followup` (550).

---

## `nvime.git` (lua/nvime/git.lua)

Thin git helpers with cached repo-root lookup.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.systemlist` | 5–11 | Run a command, return lines (no shell). |
| `M.clear_root_cache` | 24–26 | Invalidate the repo-root cache. |
| `M.root` | 28–46 | Repo root for a path (cached). |
| `M.repo_root` | 50–53 | Repo root for the current cwd. |
| `M.repo_relative_path` | 55–73 | Path relative to its repo root. |

### Local helpers
`clear_root_cache` (15) — file-local alias.

---

## `nvime.health` (lua/nvime/health.lua)

`:checkhealth nvime` provider.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.check` | 91–173 | Run health checks. |

### Local helpers
`report` (10), `audit_dir` (17), `check_writable_dir` (22), `ts_language_for`
(27), `parser_available` (38), `parse_utc_ts` (51), `recent_blocked_events`
(69).

---

## `nvime.mcp` (lua/nvime/mcp.lua)

Generates `.mcp.json` for provider CLIs that support MCP, including the
self-registered nvime server entry.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.build_config` | 92–105 | Build the merged MCP config table. |
| `M.config_path` | 124–149 | Resolve the active config file path. |
| `M.servers` | 151–153 | List servers in the merged config. |
| `M.project_config_path` | 155–157 | Path to the project-local override. |

### Local helpers
`cfg` (23), `repo_root` (27), `project_config_path` (31),
`read_project_servers` (39), `self_server_entry` (58), `write_config` (107).

---

## `nvime.mcp_server` (lua/nvime/mcp_server.lua)

In-process JSON-RPC server exposing the nvime MCP tools (plans, audits,
attribution, git, sessions, tree-sitter, tests, usage).

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.handle_line` | 858–870 | Dispatch one JSON-RPC message. |
| `M.run` | 891–897 | Stdin/stdout server loop. |

### Local helpers
Plumbing: `repo_root` (189), `nvime_path` (204), `safe_join` (211), `ok_text`
(234), `ok_json` (238), `err_result` (249), `read_lines` (253), `read_json`
(271).
Tools: `tool_search_attribution` (286), `tool_list_plans` (305),
`tool_get_plan` (339), `audit_tail` (365), `tool_recent_audits` (384),
`tool_usage_summary` (400), `tool_tree_sitter_symbols` (408), `git_run`
(456), `tool_git_log` (469), `tool_git_blame` (507), `detected_runner` (563),
`configured_runner` (571), `tail_stream` (591), `bounded_collector` (610),
`tool_test_run` (630), `read_session_files` (662), `tool_session_search`
(673), `tool_session_recent` (713), `tool_recent_diffs` (741).
Transport: `jsonrpc_response` (780), `jsonrpc_error` (784), `send` (788),
`handle` (801), `read_loop` (872).

---

## `nvime.plan` (lua/nvime/plan.lua)

The three-phase plan flow (phase 0 research + agree → phase 1 scaffold TODOs →
phase 2 implement) + plan store + plan UI (picker, plan view, compose, run
panel) + `:NvimePlan` command dispatch. Phases 1–2 reuse the Big Change
worktree/review/merge engine via a linked session (`plan.bigchange_session_id`).

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.plans` | 355 | List all plans. |
| `M.refresh` | 363 | Reload plans from disk. |
| `M.get` | 369 | Fetch a plan by id. |
| `M.delete` | 1205 | Delete a plan (discards its linked Big Change session). |
| `M.reset_session` | 1402 | Clear the captured author session (phase-0 refine). |
| `M.agree` | ~1775 | Agree to a plan → start phase 1 (scaffold). |
| `M.open` | 1932 | Open a plan at its current phase (view or review). |
| `M.create` | 2225 | Create / refine a plan (phase-0 author); `on_stream`/`on_complete` hooks let the update chat drive it. |
| `M.refine` | 2468 | Refine an existing plan via the model. |
| `M.replan` | 2472 | Re-plan from a fresh brief (full rewrite). |
| `M.update_chat` / `M.update` | 2674 | Conversational "update plan" chat (phase 0). |
| `M.discuss` | 2736 | Back-compat alias → opens the update chat. |
| `M.picker` | 3026 | Open the plan picker. |
| `M.compose` | 3286 | Open the plan compose buffer. |
| `M.prompt_new` | 3357 | Prompt for a new plan brief. |
| `M.command` | 3365 | `:NvimePlan ...` dispatcher. |
| `M.complete_subcommands` | 3452 | Tab-completion for `:NvimePlan`. |
| `M.close_all` | 3479 | Close all plan UI windows. |
| `M.focus` | 3488 | Focus the plan view. |
| `M.reopen_run` | 3516 | Reopen the run-log panel. |
| `M.detect_test_file` / `M.detect_test_runner` | — | Project test-detection helpers (shared with test-loop). |

Phase-flow test hooks: `M._plan_phase`, `M._plan_spec_markdown`,
`M._scaffold_prompt`, `M._implement_prompt`, `M._linked_session`,
`M._enter_scaffold`, `M._enter_implement`, `M._finalize_plan`.
| `M.statusline_components` | 3815–3829 | Plan parts of the statusline. |
| `M.format_id` | 3831–3833 | Format a plan id from a number. |
| `M.next_plan_number` | 3835–3837 | Next available plan number. |
| `M.slugify` | 3839–3841 | Slugify a plan title. |
| `M.plans_dir` | 3843–3845 | Path to `.nvime/plans/`. |
| `M._build_author_prompt` | 3857 | Test/evaluation hook for the plan-author prompt. |

### Local helpers (selected)
Storage: `plan_config`, `plans_dir`, `plan_dir_for`, `plan_json_path`,
`plan_md_path`, `index_path`, `now_ts`, `ensure_dir`, `read_json`,
`write_json`, `clamp_int`, `step_status`, `status_icon`, `status_hl`,
`find_step`, `range_label`, `counts_for_plan`, `plan_progress_label`,
`plan_overall_status`, `load_index`, `save_index`, `migrate_plan`,
`load_plan`, `discover_plans`, `persist_plan`, `next_plan_number`, `slugify`,
`format_id` (16–378).
UI: `buffer_name_for`, `find_buffer`, `dimensions`, `backdrop_key`,
`close_backdrop`, `close_all_backdrops_except`, `close_all_plan_ui`,
`open_backdrop`, `status_index_hl`, `progress_bar`, `pad_right`,
`render_plan_lines`, `configure_window`, `open_plan_window`,
`step_at_cursor`, `set_locked`, `render_plan`, `close_plan_view`,
`append_step_changelog`, `set_step_status` (384–1146).
Targeting/test: `extract_intent_symbols`, `search_by_symbols`,
`reanchor_range`, `open_step_target`, `plan_context_block`, `detect_test_file`,
`detect_test_runner`, `build_test_intent` (1169–1585).
Compose/run panel: `build_author_prompt`, `format_run_log`,
`open_run_window`, `close_run_window`, `install_run_panel_keymaps`,
`run_panel_append`, `parse_marker_payload` (2586–2739).
Picker/compose UI: `picker_buffer`, `picker_row_at_cursor`,
`plan_id_at_cursor`, `compose_buffer`, `compose_extract`, `compose_decorate`,
`compose_window_config`, `close_compose_window`, `install_compose_keymaps`
(2984–3535).

---

## `nvime.policy` (lua/nvime/policy.lua)

Shell-command interception. Wraps `vim.fn.system`, `jobstart`, `termopen`,
`vim.system`, and `uv.spawn` to block disallowed binaries from agent runs.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.detect` | 78–117 | Detect blocked binaries in an argv/cmd. |
| `M.should_block` | 119–138 | Whether the current call should be blocked. |
| `M.record_block` | 150–160 | Audit a blocked call. |
| `M.with_trusted` | 162–170 | Run a callback with policy bypassed. |
| `M.install` | 333–357 | Install all wrappers. |
| `M.restore` | 359–384 | Restore originals. |

### Local helpers
`flatten` (24), `shell_words` (38), `basename` (49), `is_left_boundary` (54),
`is_right_boundary` (58), `contains_bin` (62), `notify_block` (140),
`blocked_system_obj` (172), `install_system_wrapper` (198),
`install_jobstart_wrapper` (213), `install_termopen_wrapper` (228),
`install_system_function_wrappers` (243), `install_uv_wrapper` (269),
`install_terminal_detector` (289).

---

## `nvime.progress` (lua/nvime/progress.lua)

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.compact` | 3–30 | Compact verbose tool-progress text into a one-liner. |

---

## `nvime.prompts` (lua/nvime/prompts.lua)

Saved prompt templates.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.choose` | 34–50 | Picker that returns the chosen prompt body. |

### Local helpers
`configured` (5), `prompt_text` (14), `prompt_label` (24).

---

## `nvime.provider` (lua/nvime/provider.lua)

Active provider selection (per chat session and per selection session).

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.current` | 80–89 | Currently active provider for a context. |
| `M.set` | 91–127 | Set the active provider. |
| `M.cycle` | 129–138 | Cycle to the next provider. |
| `M.choose` | 140–155 | Picker. |

### Local helpers
`normalize_opts` (7), `active_selection_session` (14),
`current_selection_provider` (28), `active_chat_session` (36),
`current_chat_provider` (50), `set_active_selection_provider` (58),
`set_active_chat_provider` (71).

---

## `nvime.recap` (lua/nvime/recap.lua)

"Recap this branch" flow — diffs against base, prompts the model for a
summary.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.start` | 150–240 | Start a recap run. |
| `M.command` | 247–266 | `:Nvime recap` dispatcher. |

### Local helpers
`uv` (20), `repo_root` (24), `compute_diff` (28), `compute_label` (56),
`short_hash` (68), `build_recap_prompt` (76), `ensure_recap_id` (146).

---

## `nvime.render` (lua/nvime/render.lua)

Highlight + extmark rendering for chat scrollback, input, and the spinner.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.scrollback` | 197–391 | Apply highlights to scrollback lines. |
| `M.input` | 393–450 | Apply highlights to the input window. |
| `M.spinner_text` | 452–466 | Compose the busy-indicator text. |

### Local helpers
`provider_group` (5), `find_span` (28), `inline_spans` (52).

---

## `nvime.review` (lua/nvime/review.lua)

`:Nvime review` — model-driven review of the working tree against base.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.start` | 16–86 | Start a review run. |

### Local helpers
`git_diff` (7).

---

## `nvime.selection` (lua/nvime/selection.lua)

The selection-mode counterpart to `nvime.chat` — a panel scoped to a
specific selection (file + range), with sessions keyed on the range.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.close` | 764–766 | Close the selection panel. |
| `M.open` | 894–964 | Open or focus it. |
| `M.refresh` | 966–981 | Re-render. |
| `M.set_busy` | 1025–1041 | Spinner state. |
| `M.set_progress` | 1043–1064 | Progress label. |
| `M.attach_process` | 1099–1102 | Track active job. |
| `M.clear_process` | 1104–1107 | Clear tracked job. |
| `M.cancel_session` | 1109–1137 | Cancel a session's job. |
| `M.cancel_active` | 1139–1141 | Cancel active. |
| `M.cancel_all` | 1143–1151 | Cancel all. |
| `M.append` | 1153–1208 | Append response chunk. |
| `M.append_user` | 1210–1212 | Append user block. |
| `M.append_response_header` | 1214–1216 | Begin response block. |
| `M.prompt` | 1218–1266 | Programmatic prompt insert. |
| `M.insert_prompt` | 1268–1273 | Saved-prompt insert. |
| `M.choose_prompt` | 1275–1286 | Saved-prompt picker. |
| `M.focus_input` | 1288–1316 | Focus the input window. |
| `M.submit_current` | 1318–1346 | Submit current input. |
| `M.same_range` | 1348–1355 | Compare two selection ranges. |
| `M.snapshot` | 1361–1369 | Capture the current selection. |
| `M.get_session` | 1371–1381 | Fetch a session. |
| `M.matching_sessions` | 1383–1401 | Sessions whose range matches a given one. |
| `M.active_session_id` | 1403–1405 | Active id. |
| `M.is_open` | 1407–1409 | Whether the panel exists. |
| `M.notify_finished` | 1411–1413 | Emit the finished notification. |
| `M.winbar_text` | 1415–1462 | Winbar string. |
| `M.sessions` | 1464–1476 | List sessions. |
| `M.session_count` | 1478–1480 | Count. |
| `M.save_sessions` | 1482–1484 | Debounced save. |
| `M.flush_sessions` | 1486–1489 | Sync flush. |
| `M.reload_sessions` | 1491–1499 | Reload from disk. |
| `M.sessions_path` | 1501–1503 | Path to `selection-sessions.json`. |
| `M.rename_session` | 1505–1518 | Rename. |
| `M.delete_sessions` | 1520–1560 | Bulk delete. |
| `M.open_session` | 1562–1576 | Switch to a session. |
| `M.choose_session` | 1595–1650 | Picker. |
| `M.mark_provider_session` | 1652–1663 | Record provider session id. |
| `M.agent_run_opts` | 1665–1675 | Build `agents.run` opts. |
| `M.mark_last_ask` | 1677–1684 | Remember the last ask. |
| `M.last_ask_for` | 1686–1699 | Recall last ask for a selection. |

### Local helpers
Same shape as `nvime.chat` — sessions persistence, panel/input plumbing,
spinner, process tracking. See lines 24–892 for the equivalent helpers.

---

## `nvime.shellguard` (lua/nvime/shellguard.lua)

Generates wrapper shell scripts that block disallowed binaries when an agent
spawns a subshell.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.ensure` | 227–234 | Ensure wrapper scripts exist on disk. |
| `M.build_env` | 236–246 | Augment env with PATH overrides for an agent run. |
| `M.claude_disallow_patterns` | 271–276 | Patterns passed to Claude's allowlist. |

### Local helpers
`script_dir` (175), `write_script` (185), `quoted_git_blocklist` (195),
`ensure_scripts` (203), `compute_real_path` (220), `build_disallow_patterns`
(248).

---

## `nvime.spinner` (lua/nvime/spinner.lua)

Floating busy indicator across all sessions.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.update` | 135–191 | Recompute and redraw the spinner. |
| `M.close` | 193–196 | Hide the spinner. |

### Local helpers
`stop_timer` (15), `busy_sessions` (25), `close_float` (40), `position` (54),
`ensure_float` (60), `format_row` (102), `ensure_timer` (114).

---

## `nvime.test_loop` (lua/nvime/test_loop.lua)

Optional test-runner hook fired after accepted diffs.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.maybe_run` | 234–324 | Run tests if conditions are met. |
| `M.setup` | 328–337 | Install autocmd hooks. |
| `M.reset_counters` | 339–342 | Reset per-step counters. |

### Local helpers
`cfg` (21), `enabled` (25), `plan_test_runner` (32), `resolve_runner` (44),
`repo_root` (52), `counter_key` (56), `reset_counter` (62), `bump_counter`
(66), `tail_lines` (72), `notify` (88), `build_followup_prompt` (94),
`followup_range` (125), `launch_followup` (158), `run_runner` (192),
`format_decision` (218).

---

## `nvime.treesitter` (lua/nvime/treesitter.lua)

Tree-sitter helpers used by `nvime.plan` for symbol-anchored steps and by
the MCP server for symbol listings.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.resolve_bufnr` | 59–73 | Buffer for a path (loading if needed). |
| `M.current_function` | 98–133 | Function symbol containing the cursor. |
| `M.range_from_command` | 135–147 | Visual range from `:` command args. |
| `M.lines` | 149–160 | Lines for a buffer/range. |
| `M.walk_symbols` | 286–327 | Iterate definition-like symbols in a file. |

### Local helpers
`is_valid_buf` (5), `repo_root` (9), `normalize_path` (14), `buffer_for_path`
(35), `function_type` (75), `node_text` (216), `unwrap_to_identifier` (229),
`find_name` (253).

---

## `nvime.ui` (lua/nvime/ui.lua)

Shared UI primitives: colorscheme-derived highlight definitions, the key-hint
formatters, icons, and panels.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.ensure_highlights` | 436–449 | Define nvime highlight groups (palette resolved from the active colorscheme). |
| `M.palette` | 454–457 | Return a copy of the resolved (colorscheme-derived) palette. |
| `M.icon` | 473–486 | Resolve an icon by name with fallbacks. |
| `M.truncate` | 488–513 | Truncate to a display width. |
| `M.relative_time` | 515–533 | Human-friendly relative time. |
| `M.keyhint_line` | 552–576 | Build a key-hint string + byte-range `{col_start, col_end, hl}` marks. |
| `M.keyhint_segments` | 580–598 | Build key-hint `virt_lines` segments for the same hint. |
| `M.configure_panel_window` | 638–656 | Apply nvime panel window options to a window. |
| `M.panel` | 750–762 | Open a panel (float / split / buffer). |

### Local helpers
Colour/palette helpers: `int_to_hex` (148), `hex_to_rgb` (155), `blend` (168),
`resolved` (181), `pick_fg` (192), `pick_bg` (202), `resolve_palette` (216).
`define_highlights` (273), `keyhint_sep` (545), `set_scratch_options` (600),
`find_buffer_by_name` (609), `ensure_named_buffer` (618), `configure_window`
(658), `float_config` (662), `open_float` (695), `open_split` (709),
`open_buffer` (732).

---

## `nvime.usage` (lua/nvime/usage.lua)

Token + cost ledger.

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.parse_claude` | 259–291 | Extract usage from a Claude event. |
| `M.parse_codex` | 294–311 | Extract usage from a Codex event. |
| `M.record` | 317–351 | Record a usage entry. |
| `M.read` | 353–355 | Load the ledger. |
| `M.path` | 357–359 | Path to the ledger file. |
| `M.reset` | 361–366 | Wipe totals. |
| `M.flush` | 368–370 | Sync flush to disk. |
| `M.statusline_label` | 387–392 | Statusline cost summary. |
| `M.summary_text` | 394–459 | Render the full summary view. |
| `M.open_panel` | 474–527 | Open the usage panel. |
| `M.close_panel` | 529–531 | Close it. |

### Local helpers
`usage_config` (49), `usage_path` (53), `ensure_dir` (65), `merged_rates`
(76), `rate_for` (97), `blank_bucket` (112), `blank_ledger` (124),
`read_ledger_from_disk` (135), `ensure_ledger` (163), `load_ledger` (173),
`trim_days` (177), `save_ledger` (195), `flush_now` (219), `schedule_save`
(226), `bucket_add` (234), `compute_cost` (244), `today` (313), `fmt_usd`
(372), `fmt_tokens` (376), `close_panel` (463).

---

## `nvime.version` (lua/nvime/version.lua)

### Public API
| Symbol | Lines | Notes |
|---|---|---|
| `M.label` | 5–7 | Human-readable version string. |

---

## Modules without `M.*` exports

- **`lua/nvime/state.lua`** — Plain table holding shared mutable runtime
  state (`config`, `setup_done`, `panels`, `running`, `chat`, `selection`,
  `plan`, etc.). No functions.
- **`plugin/nvime.lua`** — Neovim plugin loader. Guards on `vim.g.loaded_nvime`
  and `nvim-0.10`, then calls `require("nvime").setup()`. No functions.

---

## Notes on this document

- Generated via the `nvime_tree_sitter_symbols` MCP tool over each Lua source
  file, then filtered to definition-level symbols (functions). Anonymous
  closures nested inside `M.*` functions were excluded as implementation
  detail.
- Line ranges are accurate at the time of generation but may drift as files
  change. Re-run the same MCP tool to refresh.
- "Public API" is shorthand for the `M.*` table exports — Lua has no
  enforced visibility, so anything in the module table is reachable from
  callers, but local functions are intentionally not API.
