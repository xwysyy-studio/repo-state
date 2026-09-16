#!/usr/bin/env bash
# Phase C verifier: Chinese-primary lexical retrieval.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE_SRC="$ROOT/scripts/transcriptctl.py"
ORIGINAL_HOME="${HOME:-}"
PASS=0
FAIL=0
FAILED=""
TEMP_DIRS=()

cleanup_temp_dirs() {
  local dir
  for dir in "${TEMP_DIRS[@]}"; do
    case "$dir" in
      /tmp/repostate-phase-c.*) rm -rf -- "$dir" ;;
    esac
  done
}
trap cleanup_temp_dirs EXIT

ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  FAILED="$FAILED"$'\n'"  - $1"
  echo "FAIL: $1"
}

new_transcript_env() {
  T="$(mktemp -d /tmp/repostate-phase-c.XXXXXX)"
  TEMP_DIRS+=("$T")
  R="$T/repo"
  if [ -n "$ORIGINAL_HOME" ]; then
    export HOME="$ORIGINAL_HOME"
  else
    export HOME="$T/home"
  fi
  export REPO_STATE_CLAUDE_DIR="$T/claude"
  export REPO_STATE_CODEX_DIR="$T/codex"
  export REPO_STATE_DB="$T/transcripts.sqlite"
  export REPO_STATE_AUDIT_LOG="$T/query-audit.jsonl"
  mkdir -p "$R" "$HOME" "$REPO_STATE_CLAUDE_DIR/projects/proj" "$REPO_STATE_CODEX_DIR/sessions"
  unset REPO_STATE_DISABLE_JIEBA
}

write_fixture() {
  write_fixture_file "$REPO_STATE_CLAUDE_DIR/projects/proj/case.jsonl" "$1"
}

write_fixture_file() {
  python3 - "$R" "$1" "$2" <<'PY'
import json, sys
repo, path = sys.argv[1], sys.argv[2]
rows = json.loads(sys.argv[3])
with open(path, "w", encoding="utf-8") as fh:
    for row in rows:
        row.setdefault("type", "user")
        row.setdefault("timestamp", "2026-07-09T00:00:00Z")
        row.setdefault("cwd", repo)
        fh.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
}

json_has_uuid() {
  local file="$1" uuid="$2"
  python3 - "$file" "$uuid" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = data
if isinstance(rows, dict):
    rows = rows.get("data", rows.get("results", []))
rows = rows or []
sys.exit(0 if any(row.get("uuid") == sys.argv[2] for row in rows) else 1)
PY
}

json_lacks_uuid() {
  local file="$1" uuid="$2"
  python3 - "$file" "$uuid" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = data
if isinstance(rows, dict):
    rows = rows.get("data", rows.get("results", []))
rows = rows or []
sys.exit(1 if any(row.get("uuid") == sys.argv[2] for row in rows) else 0)
PY
}

json_explain_has_index() {
  local file="$1" index="$2"
  python3 - "$file" "$index" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
idx = data.get("explain", {}).get("indexes_used", [])
sys.exit(0 if sys.argv[2] in idx else 1)
PY
}

json_explain_lacks_index() {
  local file="$1" index="$2"
  python3 - "$file" "$index" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
idx = data.get("explain", {}).get("indexes_used", [])
sys.exit(1 if sys.argv[2] in idx else 0)
PY
}

json_uuid_before() {
  local file="$1" first="$2" second="$3"
  python3 - "$file" "$first" "$second" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = data
if isinstance(rows, dict):
    rows = rows.get("data", rows.get("results", []))
rows = rows or []
uuids = [row.get("uuid") for row in rows]
try:
    a = uuids.index(sys.argv[2])
    b = uuids.index(sys.argv[3])
except ValueError:
    sys.exit(1)
sys.exit(0 if a < b else 1)
PY
}

json_uuid_not_in_top_n() {
  local file="$1" uuid="$2" n="$3"
  python3 - "$file" "$uuid" "$n" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = data
if isinstance(rows, dict):
    rows = rows.get("data", rows.get("results", []))
rows = rows or []
top = [row.get("uuid") for row in rows[:int(sys.argv[3])]]
sys.exit(1 if sys.argv[2] in top else 0)
PY
}

assert_zh_empty() {
  python3 - "$REPO_STATE_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
n = conn.execute("SELECT COUNT(*) FROM messages_zh").fetchone()[0]
sys.exit(0 if n == 0 else 1)
PY
}

assert_marker_absent_from_new_indexes() {
  python3 - "$REPO_STATE_DB" "$1" <<'PY'
import sqlite3, sys
db, marker = sys.argv[1], sys.argv[2]
bigrams = [marker[i:i+2] for i in range(len(marker)-1)]
conn = sqlite3.connect(db)
for token in bigrams:
    if conn.execute(
        "SELECT COUNT(*) FROM messages_cjk WHERE payload MATCH ?", (f'"{token}"',)
    ).fetchone()[0]:
        sys.exit(1)
if conn.execute(
    "SELECT COUNT(*) FROM messages_zh WHERE seg MATCH ?", (f'"{marker}"',)
).fetchone()[0]:
    sys.exit(1)
sys.exit(0)
PY
}

assert_compact_sidecar_schema() {
  python3 - "$REPO_STATE_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])

def columns(table):
    return [row[1] for row in conn.execute(f"PRAGMA table_info({table})")]

for table in ("messages_trigram", "messages_cjk"):
    sql = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()[0]
    assert "content=''" in sql.replace(" ", "").lower(), (table, sql)
    assert columns(table) == ["payload"], (table, columns(table))
    stored = conn.execute(f"SELECT payload FROM {table} LIMIT 1").fetchone()
    assert stored == (None,), (table, stored)

for table, column in (("messages_fts", "payload"), ("messages_zh", "seg")):
    sql = conn.execute(
        "SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table,)
    ).fetchone()[0]
    compact = sql.replace(" ", "").lower()
    assert "content=''" in compact, (table, sql)
    assert "contentless_delete=1" in compact, (table, sql)
    assert columns(table) == [column], (table, columns(table))
    stored = conn.execute(f"SELECT {column} FROM {table} LIMIT 1").fetchone()
    assert stored == (None,), (table, stored)

indexes = {row[0] for row in conn.execute(
    "SELECT name FROM sqlite_master WHERE type='index'"
)}
assert "idx_messages_session" not in indexes, indexes
assert "idx_records_source_line" not in indexes, indexes
PY
}

case_cjk2_bigram() {
  new_transcript_env
  write_fixture '[
    {"uuid":"u-cjk2-target","message":{"role":"user","content":"请检查状态并记录结果。"}},
    {"uuid":"u-cjk2-decoy","message":{"role":"user","content":"这里只提到状态，不包含检查二字。"}}
  ]'
  if python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>"$T/index.err"; then ok; else bad "C1 setup index"; cat "$T/index.err"; return; fi
  python3 "$ENGINE_SRC" search 检查 --project-path "$R" --limit 5 --explain --no-index > "$T/cjk2.json" 2>"$T/cjk2.err"
  json_has_uuid "$T/cjk2.json" u-cjk2-target && ok || { bad "C1 2-char CJK query must return seeded target"; cat "$T/cjk2.err"; cat "$T/cjk2.json"; }
  json_explain_has_index "$T/cjk2.json" messages_cjk && ok || { bad "C1 explain must show messages_cjk"; cat "$T/cjk2.json"; }
  json_explain_lacks_index "$T/cjk2.json" messages_like_short && ok || { bad "C1 explain must not show messages_like_short"; cat "$T/cjk2.json"; }
}

case_jieba_phrase_ranking() {
  new_transcript_env
  if python3 -c "import jieba" >/dev/null 2>&1; then ok; else bad "C2 jieba must be importable for present-case verifier"; return; fi
  # 每行独立会话：recall 面做会话族多样化（同等相关性下每族先出一条），
  # 同会话堆放会让多样化而非排序决定谁在场，被测命题是短语排序不是多样性
  write_fixture_file "$REPO_STATE_CLAUDE_DIR/projects/proj/case-t1.jsonl" \
    '[{"uuid":"u-phrase-target","message":{"role":"user","content":"请把决策台账作为唯一权威，今天复核。"}}]'
  write_fixture_file "$REPO_STATE_CLAUDE_DIR/projects/proj/case-t2.jsonl" \
    '[{"uuid":"u-phrase-target-2","message":{"role":"user","content":"决策台账需要同步引用原话和落点。"}}]'
  write_fixture_file "$REPO_STATE_CLAUDE_DIR/projects/proj/case-t3.jsonl" \
    '[{"uuid":"u-phrase-target-3","message":{"role":"user","content":"今天只检查决策台账这一项。"}}]'
  write_fixture_file "$REPO_STATE_CLAUDE_DIR/projects/proj/case-decoy.jsonl" \
    '[{"uuid":"u-phrase-decoy","message":{"role":"user","content":"这个决策需要记录。另一个台账只是普通表格。"}}]'
  if python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>"$T/index.err"; then ok; else bad "C2 setup index"; cat "$T/index.err"; return; fi
  python3 "$ENGINE_SRC" search 决策台账 --project-path "$R" --limit 5 --explain --no-index > "$T/phrase.json" 2>"$T/phrase.err"
  json_has_uuid "$T/phrase.json" u-phrase-target && json_has_uuid "$T/phrase.json" u-phrase-decoy \
    && ok || { bad "C2 jieba search must return exact phrase target and scattered decoy"; cat "$T/phrase.err"; cat "$T/phrase.json"; }
  json_explain_has_index "$T/phrase.json" messages_zh && ok || { bad "C2 explain must show messages_zh when jieba is present"; cat "$T/phrase.json"; }
  json_uuid_before "$T/phrase.json" u-phrase-target u-phrase-decoy && ok || { bad "C2 exact phrase must outrank scattered terms"; cat "$T/phrase.json"; }
  json_uuid_not_in_top_n "$T/phrase.json" u-phrase-decoy 3 && ok || { bad "C2 scattered terms decoy must not enter top-3"; cat "$T/phrase.json"; }
}

case_stale_source_does_not_starve_fresh() {
  new_transcript_env
  local stale="$REPO_STATE_CLAUDE_DIR/projects/proj/stale.jsonl"
  local fresh="$REPO_STATE_CLAUDE_DIR/projects/proj/fresh.jsonl"
  python3 - "$R" "$stale" "$fresh" <<'PY'
import json, sys
repo, stale, fresh = sys.argv[1:4]
with open(stale, "w", encoding="utf-8") as fh:
    for i in range(150):
        row = {
            "type": "user",
            "uuid": f"u-stale-{i:03d}",
            "timestamp": f"2026-07-09T00:10:{i:03d}Z",
            "cwd": repo,
            "message": {"role": "user", "content": f"饥饿测试 共同命中 stale {i:03d}"},
        }
        fh.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
with open(fresh, "w", encoding="utf-8") as fh:
    row = {
        "type": "user",
        "uuid": "u-fresh-after-stale",
        "timestamp": "2026-07-09T00:00:00Z",
        "cwd": repo,
        "message": {"role": "user", "content": "饥饿测试 共同命中 fresh target"},
    }
    fh.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
  if python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>"$T/index.err"; then ok; else bad "C5 setup stale/fresh index"; cat "$T/index.err"; return; fi
  python3 - "$stale" <<'PY'
import sys
p = sys.argv[1]
s = open(p, encoding="utf-8").read()
open(p, "w", encoding="utf-8").write(s.replace("饥饿测试", "改写噪声"))
PY
  python3 "$ENGINE_SRC" search 饥饿测试 --project-path "$R" --limit 10 --explain --no-index > "$T/stale-cap.json" 2>"$T/stale-cap.err"
  json_has_uuid "$T/stale-cap.json" u-fresh-after-stale && ok || { bad "C5 recall must keep scanning past stale-source rows until fresh hit"; cat "$T/stale-cap.err"; cat "$T/stale-cap.json"; }
}

case_missing_sidecars_fail_closed() {
  # schema 版本门已保证 schema 12 库四张 FTS 表齐全；运行时缺表只可能是
  # 库被破坏，必须大声拒绝并指向 rebuild，不得静默缩减中文召回
  new_transcript_env
  write_fixture '[
    {"uuid":"u-broken-gen","message":{"role":"user","content":"残缺代际 中文检索 内容。"}}
  ]'
  if python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>"$T/index.err"; then ok; else bad "C6 setup index"; cat "$T/index.err"; return; fi
  python3 - "$REPO_STATE_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
for table in ("messages_cjk", "messages_zh"):
    conn.execute(f"DROP TABLE IF EXISTS {table}")
conn.commit()
PY
  if python3 "$ENGINE_SRC" search 中文检索 --project-path "$R" --limit 5 > "$T/broken-gen.json" 2>"$T/broken-gen.err"; then
    bad "C6 a schema-12 database missing FTS tables must refuse queries"
    cat "$T/broken-gen.json"
  else ok; fi
  grep -qi "rebuild" "$T/broken-gen.err" "$T/broken-gen.json" \
    && ok || { bad "C6 the refusal must point at a full rebuild"; sed -n '1,6p' "$T/broken-gen.err"; }
  python3 "$ENGINE_SRC" index >/dev/null 2>"$T/c6-recover.err" \
    && ok || { bad "C6 explicit index must rebuild the truncated generation"; sed -n '1,6p' "$T/c6-recover.err"; }
  python3 "$ENGINE_SRC" search 中文检索 --project-path "$R" --limit 5 --no-index > "$T/c6-after.json" 2>/dev/null
  json_has_uuid "$T/c6-after.json" u-broken-gen && ok || { bad "C6 queries must recover after rebuild"; cat "$T/c6-after.json"; }
}

case_non_object_records_skip_not_kill() {
  # 顶层合法 JSON 但非对象的行：主源逐条 skip、辅助判定路径跳过，
  # 不得让整源变 parser-error 或让 scope 判定崩溃
  new_transcript_env
  MAIN="$REPO_STATE_CLAUDE_DIR/projects/proj/S-nonobj.jsonl"
  printf '%s\n' '[]' > "$MAIN"
  printf '%s\n' "{\"type\":\"user\",\"uuid\":\"u-nonobj-1\",\"timestamp\":\"2026-07-21T00:00:00Z\",\"cwd\":\"$R\",\"message\":{\"role\":\"user\",\"content\":\"nonobj alive marker\"}}" >> "$MAIN"
  python3 "$ENGINE_SRC" index >/dev/null 2>"$T/nonobj.err" \
    && ok || { bad "C12 index must survive a top-level non-object record"; sed -n '1,6p' "$T/nonobj.err"; }
  python3 - "$REPO_STATE_DB" <<'PY' && ok || bad "C12 the sibling message must be indexed and the source stay active"
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert conn.execute("SELECT COUNT(*) FROM messages WHERE uuid='u-nonobj-1'").fetchone()[0] == 1
assert conn.execute("SELECT status FROM index_state WHERE jsonl_path LIKE '%S-nonobj%'").fetchone()[0] == "active"
assert conn.execute("SELECT COUNT(*) FROM skipped_records WHERE source_path LIKE '%S-nonobj%'").fetchone()[0] == 1
PY
  python3 - "$ENGINE_SRC" "$MAIN" <<'PY' && ok || bad "C12 raw project-scope scan must tolerate non-object records"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("engine", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.raw_source_in_project_scope(sys.argv[2], "/tmp/some-project")
PY
}

case_dotted_token_precision() {
  new_transcript_env
  # 同 C2：每行独立会话，避免会话族多样化替排序回答"谁在场"
  write_fixture_file "$REPO_STATE_CLAUDE_DIR/projects/proj/case-d1.jsonl" \
    '[{"uuid":"u-dotted-exact-1","message":{"role":"user","content":"0.11 3.5 精度 调优 已经完成第一轮。"}}]'
  write_fixture_file "$REPO_STATE_CLAUDE_DIR/projects/proj/case-d2.jsonl" \
    '[{"uuid":"u-dotted-exact-2","message":{"role":"user","content":"复测 0.11 3.5 精度 调优 的排序。"}}]'
  write_fixture_file "$REPO_STATE_CLAUDE_DIR/projects/proj/case-d3.jsonl" \
    '[{"uuid":"u-dotted-exact-3","message":{"role":"user","content":"保持 0.11 3.5 精度 调优 的 exact 命中。"}}]'
  write_fixture_file "$REPO_STATE_CLAUDE_DIR/projects/proj/case-d4.jsonl" \
    '[{"uuid":"u-dotted-decoy","message":{"role":"user","content":"0.11 记录，3.5 指标，精度 需要复核，调优 稍后处理。"}}]'
  if python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>"$T/index.err"; then ok; else bad "C7 setup dotted precision index"; cat "$T/index.err"; return; fi
  python3 "$ENGINE_SRC" search "0.11 3.5 精度 调优" --project-path "$R" --limit 5 --explain --no-index > "$T/dotted.json" 2>"$T/dotted.err"
  json_has_uuid "$T/dotted.json" u-dotted-exact-1 && json_has_uuid "$T/dotted.json" u-dotted-decoy \
    && ok || { bad "C7 dotted-token query must return exact and scattered rows"; cat "$T/dotted.err"; cat "$T/dotted.json"; }
  json_uuid_before "$T/dotted.json" u-dotted-exact-1 u-dotted-decoy && ok || { bad "C7 exact dotted-token phrase must outrank scattered decoy"; cat "$T/dotted.json"; }
  json_uuid_not_in_top_n "$T/dotted.json" u-dotted-decoy 3 && ok || { bad "C7 scattered dotted-token decoy must not enter top-3"; cat "$T/dotted.json"; }
}

case_jieba_disabled() {
  new_transcript_env
  export REPO_STATE_DISABLE_JIEBA=1
  write_fixture '[
    {"uuid":"u-disabled-target","message":{"role":"user","content":"状态检查需要继续保留。"}}
  ]'
  if python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>"$T/index.err"; then ok; else bad "C3 disabled setup index"; cat "$T/index.err"; return; fi
  python3 "$ENGINE_SRC" search 状态 --project-path "$R" --limit 5 --explain --no-index > "$T/disabled.json" 2>"$T/disabled.err"
  json_has_uuid "$T/disabled.json" u-disabled-target && ok || { bad "C3 disabled jieba search must still return results"; cat "$T/disabled.err"; cat "$T/disabled.json"; }
  assert_zh_empty && ok || { bad "C3 disabled jieba must leave messages_zh empty"; sqlite3 "$REPO_STATE_DB" 'SELECT COUNT(*) FROM messages_zh' 2>/dev/null; }
  json_explain_lacks_index "$T/disabled.json" messages_zh && ok || { bad "C3 disabled explain must not show messages_zh"; cat "$T/disabled.json"; }
  unset REPO_STATE_DISABLE_JIEBA
}

case_thinking_canary() {
  new_transcript_env
  local marker="隐私丁卯标记"
  local decision="D-2026-08-13-77"
  write_fixture '[
    {"type":"assistant","uuid":"u-thinking-origin","timestamp":"2026-07-09T00:00:01Z","message":{"role":"assistant","content":[
      {"type":"thinking","thinking":"隐私丁卯标记只存在于隐藏思考。D-2026-08-13-77 是原始裁定。"},
      {"type":"text","text":"可见回答相同。"}
    ]}},
    {"type":"assistant","uuid":"u-thinking-reference","timestamp":"2026-07-09T00:00:02Z","message":{"role":"assistant","content":[
      {"type":"thinking","thinking":"随后引用 D-2026-08-13-77 并复核另一条证据。"},
      {"type":"text","text":"可见回答相同。"}
    ]}}
  ]'
  if python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>"$T/index.err"; then ok; else bad "C4 setup index"; cat "$T/index.err"; return; fi
  python3 "$ENGINE_SRC" search "$marker" --project-path "$R" --limit 5 --explain --no-index > "$T/thinking.json" 2>"$T/thinking.err"
  json_lacks_uuid "$T/thinking.json" u-thinking-origin && ! grep -q "$marker" "$T/thinking.json" \
    && ok || { bad "C4 default search must not return thinking-only marker"; cat "$T/thinking.err"; cat "$T/thinking.json"; }
  assert_marker_absent_from_new_indexes "$marker" && ok || { bad "C4 thinking-only marker must not enter messages_cjk/messages_zh"; }
  python3 - "$T/thinking-admin-query.json" "$R" "$decision" <<'PY'
import json, sys
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    json.dump({
        "op": "search", "text": sys.argv[3], "project_path": sys.argv[2],
        "limit": 5,
    }, fh)
PY
  python3 "$ENGINE_SRC" query-admin --include-thinking "$T/thinking-admin-query.json" \
    --no-index >"$T/thinking-admin.json" 2>"$T/thinking-admin.err"
  python3 - "$T/thinking-admin.json" "$decision" <<'PY' \
    && ok || { bad "C4 explicit thinking search must preserve hard-ID semantics and distinct evidence"; cat "$T/thinking-admin.err"; cat "$T/thinking-admin.json"; }
import json, sys
rows = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
assert {row["uuid"] for row in rows} == {"u-thinking-origin", "u-thinking-reference"}, rows
assert all(row["bonus_class"] == 4 and row["match_tier"] == 2 for row in rows), rows
assert all(sys.argv[2] in row["snippet"] for row in rows), rows
PY
}

case_compact_sidecar_lifecycle() {
  new_transcript_env
  local source="$REPO_STATE_CLAUDE_DIR/projects/proj/storage.jsonl"
  write_fixture_file "$source" \
    '[{"uuid":"u-storage","message":{"role":"user","content":"storagealpha 原始检查 保留完整检索内容。"}}]'
  if python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>"$T/index.err"; then ok; else bad "C8 setup compact sidecars"; cat "$T/index.err"; return; fi
  assert_compact_sidecar_schema && ok || bad "C8 sidecars must use the compact single-source-of-truth schema"
  python3 "$ENGINE_SRC" search storagealpha --project-path "$R" --explain --no-index >"$T/storage-old.json" 2>/dev/null
  json_has_uuid "$T/storage-old.json" u-storage && ok || bad "C8 trigram sidecar must retrieve the original row"
  json_explain_has_index "$T/storage-old.json" messages_trigram && ok || bad "C8 storagealpha must exercise messages_trigram"
  python3 "$ENGINE_SRC" search 原始检查 --project-path "$R" --explain --no-index >"$T/storage-cjk-old.json" 2>/dev/null
  json_has_uuid "$T/storage-cjk-old.json" u-storage && ok || bad "C8 CJK sidecar must retrieve the original row"
  json_explain_has_index "$T/storage-cjk-old.json" messages_cjk && ok || bad "C8 原始检查 must exercise messages_cjk"

  python3 - "$R" "$source" <<'PY'
import json, sys
repo, path = sys.argv[1:]
row = {
    "type": "user", "uuid": "u-storage",
    "timestamp": "2026-07-09T00:00:01Z", "cwd": repo,
    "message": {"role": "user", "content": "storageomega 更新复核 保留完整检索内容。"},
}
with open(path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
  python3 "$ENGINE_SRC" index >/dev/null 2>"$T/update.err" \
    && ok || { bad "C8 rewritten source must reindex"; cat "$T/update.err"; }
  python3 "$ENGINE_SRC" search storagealpha --project-path "$R" --no-index >"$T/storage-old-gone.json" 2>/dev/null
  json_lacks_uuid "$T/storage-old-gone.json" u-storage && ok || bad "C8 contentless delete must remove old trigram tokens"
  python3 "$ENGINE_SRC" search 原始检查 --project-path "$R" --no-index >"$T/storage-cjk-old-gone.json" 2>/dev/null
  json_lacks_uuid "$T/storage-cjk-old-gone.json" u-storage && ok || bad "C8 contentless delete must remove old CJK tokens"
  python3 "$ENGINE_SRC" search storageomega --project-path "$R" --no-index >"$T/storage-new.json" 2>/dev/null
  json_has_uuid "$T/storage-new.json" u-storage && ok || bad "C8 rewritten trigram tokens must be searchable"
  python3 "$ENGINE_SRC" search 更新复核 --project-path "$R" --no-index >"$T/storage-cjk-new.json" 2>/dev/null
  json_has_uuid "$T/storage-cjk-new.json" u-storage && ok || bad "C8 rewritten CJK tokens must be searchable"

  rm "$source"
  python3 "$ENGINE_SRC" index >/dev/null 2>"$T/delete.err" \
    && ok || { bad "C8 deleted source must purge"; cat "$T/delete.err"; }
  python3 "$ENGINE_SRC" search storageomega --project-path "$R" --no-index >"$T/storage-purged.json" 2>/dev/null
  json_lacks_uuid "$T/storage-purged.json" u-storage && ok || bad "C8 source purge must remove contentless tokens"
  python3 - "$REPO_STATE_DB" <<'PY' \
    && ok || bad "C8 every FTS sidecar must pass its integrity check"
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
for table in ("messages_fts", "messages_trigram", "messages_cjk", "messages_zh"):
    conn.execute(f"INSERT INTO {table}({table}) VALUES('integrity-check')")
PY
}

case_zh_delete_survives_segmenter_drift() {
  new_transcript_env
  python3 - "$ENGINE_SRC" <<'PY' \
    && ok || bad "C9 deleting a row after segmenter drift must not leave ghost zh tokens"
import runpy, sqlite3, sys
engine = runpy.run_path(sys.argv[1], run_name="phase_c_segmenter_drift")
conn = sqlite3.connect(":memory:")
segmenter = {"payload": "oldsegmenttoken"}
conn.create_function("repo_state_trigram_payload", 1, engine["trigram_index_payload"])
conn.create_function("repo_state_cjk_bigram_payload", 1, engine["cjk_bigram_payload"])
conn.executescript(engine["SCHEMA"])
conn.create_function("repo_state_jieba_enabled", 0, lambda: 1)
conn.create_function("repo_state_jieba_payload", 1, lambda _text: segmenter["payload"])
conn.execute(
    "INSERT INTO messages(uuid,session_id,text) VALUES('drift-row','drift-session','visible')"
)
assert conn.execute(
    "SELECT COUNT(*) FROM messages_zh WHERE seg MATCH 'oldsegmenttoken'"
).fetchone()[0] == 1
segmenter["payload"] = "newsegmenttoken"
conn.execute("DELETE FROM messages WHERE uuid='drift-row' AND session_id='drift-session'")
assert conn.execute(
    "SELECT COUNT(*) FROM messages_zh WHERE seg MATCH 'oldsegmenttoken'"
).fetchone()[0] == 0
PY
}

case_long_message_middle_is_searchable() {
  new_transcript_env
  python3 - "$REPO_STATE_CLAUDE_DIR/projects/proj/long.jsonl" "$R" <<'PY'
import json, sys
path, cwd = sys.argv[1:]
text = "A" * 9000 + " auditmiddlemarker " + "Z" * 9000
row = {
    "type": "user", "uuid": "u-long-middle", "parentUuid": None,
    "timestamp": "2026-07-09T00:00:00Z", "cwd": cwd,
    "message": {"role": "user", "content": text},
}
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
  if python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>"$T/index.err"; then
    ok
  else
    bad "C10 setup long-message index"
    cat "$T/index.err"
    return
  fi
  python3 "$ENGINE_SRC" search auditmiddlemarker --project-path "$R" \
    --limit 5 --explain --no-index >"$T/long-middle.json" 2>"$T/long-middle.err"
  json_has_uuid "$T/long-middle.json" u-long-middle \
    && grep -q "auditmiddlemarker" "$T/long-middle.json" \
    && ok || { bad "C10 search must find and show a long-message middle match"; cat "$T/long-middle.err"; cat "$T/long-middle.json"; }
  python3 "$ENGINE_SRC" locate auditmiddlemarker --session long --all-projects \
    --no-index >"$T/long-locate.json" 2>"$T/long-locate.err"
  json_has_uuid "$T/long-locate.json" u-long-middle \
    && grep -q "auditmiddlemarker" "$T/long-locate.json" \
    && ok || { bad "C10 locate must find a verbatim quote in the long-message middle"; cat "$T/long-locate.err"; cat "$T/long-locate.json"; }
  python3 "$ENGINE_SRC" proof --message u-long-middle --quote auditmiddlemarker \
    --no-index >"$T/long-proof.json" 2>"$T/long-proof.err"
  python3 - "$T/long-proof.json" <<'PY' \
    && ok || { bad "C10 proof must certify the middle quote against raw evidence"; cat "$T/long-proof.err"; }
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
assert payload["quote_verbatim"] is True, payload
PY
  python3 "$ENGINE_SRC" get-message u-long-middle --no-index \
    >"$T/long-message.json" 2>"$T/long-message.err"
  python3 - "$T/long-message.json" <<'PY' \
    && ok || { bad "C10 get-message output must remain bounded"; cat "$T/long-message.err"; }
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
assert payload["text_truncated"] is True, payload
assert payload["text_total"] > len(payload["text"]), payload
assert payload["text_offset"] == 0, payload
assert payload["next_offset"] == len(payload["text"]), payload
PY
  python3 "$ENGINE_SRC" get-message u-long-middle --offset 10000 --limit 10000 \
    --no-index >"$T/long-message-tail.json" 2>"$T/long-message-tail.err"
  python3 - "$T/long-message.json" "$T/long-message-tail.json" <<'PY' \
    && ok || { bad "C10 get-message pages must cover the full visible message"; cat "$T/long-message-tail.err"; }
import json, sys
first = json.load(open(sys.argv[1], encoding="utf-8"))["data"]
tail = json.load(open(sys.argv[2], encoding="utf-8"))["data"]
assert tail["text_offset"] == first["next_offset"], (first, tail)
assert tail["next_offset"] is None, tail
assert len(first["text"] + tail["text"]) == first["text_total"], (first, tail)
PY
}

case_cjk2_bigram
case_jieba_phrase_ranking
case_stale_source_does_not_starve_fresh
case_missing_sidecars_fail_closed
case_non_object_records_skip_not_kill
case_dotted_token_precision
case_jieba_disabled
case_thinking_canary
case_compact_sidecar_lifecycle
case_zh_delete_survives_segmenter_drift
case_long_message_middle_is_searchable

echo "----"
echo "phase-c-pass=$PASS phase-c-fail=$FAIL"
if [ "$FAIL" -ne 0 ]; then
  printf 'Failed:%s\n' "$FAILED"
  exit 1
fi
exit 0
