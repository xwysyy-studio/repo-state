# Transcript Query API

Read this reference for programmatic aggregation, precise source evidence, index diagnosis, or evaluation. Ordinary lookup starts with SKILL.md and a subcommand's `--help`.

## Output and identity

Query commands emit one JSON object with `schema_version: 2`, `data`, `invocation`, and `index_freshness`. Diagnostics appear in `diagnostics`; an unsuccessful command has a nonzero status and `error`. Handle a nonzero status or non-null error before consuming data. Output exceeding `--output-limit` produces an error without a partial payload and exits 4. Increase the explicit output budget or narrow the aggregation. `index` is a maintenance command with a textual build report; `--help` is textual.

Invocation is resolved from runtime identity. `is_invoking` marks search/session rows from the caller. Default search includes those rows; they are not independent evidence. Explicit inclusion/exclusion fails when identity is unresolved. Project filters use each message's cwd. `sessions` requires the session's messages to belong to the requested project. It returns main sessions by default, including user-created Codex forks; `--include-agents` also includes real agent and guardian threads.

Codex paginated `thread/revert` retains the thread ID and starts a new rollout file. Message IDs use that file's rollout ID and record number, while `session_id` remains the logical thread ID. The latest rollout's `history_base` chain selects the retained byte prefixes; replaced messages remain available through exact IDs or `--include-abandoned`. A read-only overlay loads a changed thread's rollouts together and shadows their base rows before filtering. Schema 15 requires one explicit `index` upgrade from older indexes. The format follows the upstream [rollout metadata](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/metadata.rs) and [recorder tests](https://github.com/openai/codex/blob/main/codex-rs/rollout/src/recorder_tests.rs).

Message identity is `(session_id, uuid)`. A duplicate bare UUID returns candidates rather than selecting a session. Bare Codex `<thread-uuid>:<record-number>` message references are accepted; reuse the full returned identities. Tool identity is `(session_id, tool_id)`, including multiple tools in one assistant message.

Claude session titles use the latest nonempty `custom-title` / `customTitle`, then the latest nonempty `ai-title` / `aiTitle`, then the existing history title. Title metadata is read across the complete indexed prefix even during append parsing; subagent names do not rename the parent session. Titles are display metadata and do not enter the message search indexes. On the first index pass after this parser upgrade, existing main sources containing `custom-title` receive a title-only backfill. It verifies the indexed source bytes and leaves message/tool evidence and project metadata unchanged; no full rebuild is required. This runs during normal local refreshes. `--no-index` reads use the already stored titles.

## Ordinary commands

| Command | Relevant arguments | Result |
|---|---|---|
| `search <complete question>` | `--speaker original-user`, `--after`, `--before`, `--limit`, `--explain` | Excerpts with message identities and lexical-match diagnostics. |
| `sessions` | `--include-agents`, `--include-abandoned`, `--limit` | Newest sessions and user-message counts. |
| `get-session <session-id>` | `--offset`, `--limit`, `--text-limit` | Conversation instances with independent message/text continuation positions. |
| `context <message-id>` | `--session`, `--before`, `--after`, `--text-limit` | Anchor plus preceding/following visible messages. Counts refer to messages, not dates. |
| `get-message <message-id>` | `--session`, `--offset`, `--limit` | Verified text page, exact source location and source hashes. |
| `get-messages <uuid>...` | `--session` | First verified text page of several messages in one call; later pages use `get-message`. |
| `locate <quote>` | `--session`, `--role`, `--message` | Up to five newest messages in one session containing the verbatim, case-sensitive quote (newest session in scope when `--session` is omitted); `--message` returns that message with its state labels. `search` finds a phrase across sessions. |
| `tool-history [pattern]` | `--tool`, `--after`, `--before`, `--limit` | Tool identity, input excerpt and source location; structured file touches rank ahead of textual mentions. |
| `failures [pattern]` | `--tool`, `--after`, `--before`, `--limit` | Verified failures, classification and an exact tool reference. Pattern searches the full result. |
| `get-tool <tool-id>` | required `--session`; `--part input|output`, `--offset`, `--limit` | Selected tool block, paged from the verified original source. |
| `session-report` | `--session`, `--repo-prefix`, `--decision-pattern` | Edited files, user-message and failure counts using the same failure definition as `failures`. |
| `proof` | `--message`, `--session`, optional `--quote` | Source verification and optional verbatim quote check. |

`search`, `tool-history`, and `failures` share mutually exclusive `--session`, `--current-session`, and `--exclude-current-session`. Project discovery commands accept `--project-path` or `--all-projects`. Exact message/tool reads name their identity. `--no-index` skips refresh and makes freshness incomplete; it is not a performance substitute for a fresh answer.

Text pages include `text_offset`, `text_total`, `next_offset`, and `text_truncated`. Continue a session-message suffix with `get-message`, and a tool suffix with the same `get-tool --part`. Context excludes injected and abandoned neighbors by default; opt in explicitly when investigating them. The exact anchor always carries its state labels. `more_before`/`more_after` indicate additional neighbors; use the first/last returned message as the next anchor to continue.

`get-tool` validates the selected input/output independently. Its optional `name` comes from a separately verified associated call. Missing output returns an error; an unavailable or changed source returns suppressed text with its evidence status. The exact read retains the original timestamp, physical source line, raw-record hash, and recorder `is_error` flag independently of the inferred failure classification. Tool discovery ranges use the indexed associated message time.

Failure recognition uses tool error flags, nonzero recorded exit codes, structured execution envelopes, and leading Python tracebacks. A prose example quoting an error is insufficient. Exit code zero is not a failure by itself. Detection and pattern matching are decided on the full verified result. The indexed copy of a result is complete unless it carries the truncation marker, so a complete copy that matches neither the pattern nor any failure shape is skipped without reading its original record; truncated copies are always verified. No failure list proves the absence of application failures that the recorder did not expose.

## Safe JSON queries

Use `query /dev/stdin` with a JSON document on stdin, or pass a JSON file. Every operation declares `project_path`, or `all_projects: true` with `ack_all_projects: true`. A `scope` object may contain those scope fields instead; duplicate declarations are rejected. Unknown fields, invalid types, modes, or limits are rejected before refresh/audit side effects.

The following are separate requests:

```json
{"op":"search","text":"Why did we choose this behavior?","speaker":"original-user","project_path":"/path/to/project"}
{"op":"context","uuid":"message-id","session_id":"session-id","preceding":2,"following":2,"project_path":"/path/to/project"}
{"op":"get-message","uuid":"message-id","session_id":"session-id","offset":10000,"limit":10000,"project_path":"/path/to/project"}
{"op":"tool-history","pattern":"path/to/file","exclude_session_id":"session-id","project_path":"/path/to/project"}
{"op":"failures","pattern":"JSONDecodeError","after":"2026-09-01","project_path":"/path/to/project"}
{"op":"get-tool","tool_id":"tool-id","session_id":"session-id","part":"output","project_path":"/path/to/project"}
```

`sessions` also supports `source`, `include_agents`, and `limit`. Search supports `session_id` or `exclude_session_id`, `after`, `before`, `include_meta`, `include_abandoned`, `mode`, and `explain`. Tool history/failures accept `pattern`, `tool`, those session filters, dates and limit. Context uses `preceding`/`following`, `text_limit`, and the inclusion flags. Tool reads accept `part`, `offset`, and `limit`. Safe message/context/tool reads enforce project scope before emitting evidence.

## Trusted local aggregation

Use `query-python --trusted /dev/stdin` for a precise aggregation unavailable through ordinary commands or the safe DSL. Python code receives the helpers and `CWD`. Set `result` to the return value. Prints enter diagnostics without corrupting JSON.

```python
search(text, project_path=CWD, speaker="original-user", limit=10)
get_message(uuid, session_id=sid, text_offset=0, text_limit=10000)
context(uuid, session_id=sid, before=2, after=2, text_limit=2000)
thread(sid, limit=2000, text_limit=2000)
tool_history(pattern="path", project_path=CWD, after="2026-09-01", limit=20)
failures(project_path=CWD, session_id=sid, pattern="error text", limit=20)
get_tool(tool_id, sid, part="output", text_offset=0, text_limit=10000)
```

Other helpers cover file history, summaries, subagents and workflow trees. Inspect a helper signature with `inspect.signature()` in a trusted query when needed. Helpers return data directly; the enclosing command adds freshness and invocation. Search with `explain=True` returns `results` and `explain`, while ordinary search returns rows. Do not assume `data` has one shape across unrelated operations.

Overlay queries merge typed helpers over both layers. Arbitrary `sql()` cannot represent this merge and fails while overlay is active. Sensitive SQL/raw/thinking access is audit logged before execution; audit failure rejects the read. Private JSON reads use `query-admin --include-thinking`. Hidden thinking is excluded from ordinary search and reading.

## Source and index contracts

The index is `~/.repo-state/transcripts.sqlite`; sources are `~/.claude/projects` and `~/.codex/sessions`. Queries perform bounded incremental refresh. Unchanged sources use device, inode, size, mtime_ns and ctime_ns checks; changed sources are content-verified. After the changed sources are written, the pass renormalizes Codex effective timestamps and checks the relational invariants only for the sessions and sources it touched (plus their Codex descendants); the FTS row counts are checked globally. An interrupted pass or a policy purge outside a pass makes the next pass check everything once, and `index --rebuild` validates the whole compacted artifact. Reads verify original records. A malformed newline-terminated record can be parser-skipped; an incomplete invalid EOF tail remains uncovered until completed. Normal same-size/same-mtime rewrites are detected through the remaining stat identity.

When the published database is locked, read-only, or a source changes during refresh, queries may use a temporary on-disk overlay plus the immutable base. Changed main-session sources are prioritized without excluding active agents. An unwritable index directory still allows supported read-only queries. Deleted active sources and parser errors remain visible as incomplete coverage. `sessions` rejects uncovered sources that threaten its newest-session answer and exposes only `partial_data` with the error.

Inspect `complete`, `uncovered_changed_sources`, `uncovered_main_sources`, `parser_errors`, and `deleted_sources` as applicable. Source hashes certify bytes and projections, not the truth or authority of statements. Abandoned-input marking is structural inference from the conversation branch. `original-user` requires human-entry provenance; forwarded prompts, headless execution requests and compaction summaries remain searchable outside that channel.

`session-report` counts each file touched by multi-file `apply_patch`. Search uses source-verified candidates, message-identity merging and relevance-bounded session-family diversity. Exact identifiers outrank references. Conversation reading preserves distinct instances even when their words match.

Dependency: `orjson`; missing it fails at import. Isolated-test overrides: `REPO_STATE_CLAUDE_DIR`, `REPO_STATE_CODEX_DIR`, `REPO_STATE_DB`, `REPO_STATE_AUDIT_LOG`.

## Verification

`tests/test_query_workflow.py` runs the actual CLI against isolated Claude/Codex records: JSON transport, errors, message continuation, repeated confirmations, context, tool input/output recovery, failure classification, scope and overlay ordering. `tests/phase_c.sh` through `phase_i.sh` cover retrieval, source lifecycle, identities and private reading. Mechanical tests do not prove final-answer quality.

`tests/test_codex_rollouts.py` covers paginated reverts, preserved source bytes, exact reads, incremental updates and read-only overlays. On macOS, the lifecycle tests use native `lsof`, Python file metadata and memory values normalized to KiB; their assertions retain the same byte, inode, timestamp and memory bounds.

For retrieval comparisons, use SQLite online backup to create one consistent temporary snapshot. Both engines use that snapshot, identical cases/cutoffs, and `--no-index`. Date filters alone do not freeze BM25 corpus statistics. Record engine commits or source hashes, evaluation-set SHA-256, segmenter/version, snapshot SHA-256/schema/message count, and cutoff. Cite source `(session_id, uuid)` rather than copying transcripts. Remove the snapshot afterward. Publish ranking changes on demonstrated gains without material regression; implementation tests alone do not establish retrieval quality.
