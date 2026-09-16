#!/usr/bin/env bash
# Phase D index-lifecycle guard verifier.
# Contract under test: query commands only do incremental refresh; a pending
# FULL (re)build (schema upgrade / first build / interrupted full build) makes
# them refuse loudly with an instruction, without tearing down the existing DB.
# Only the explicit `index` command may run a full (re)build.
# Usage: bash tests/phase_d.sh   # exit 0 iff ALL PASS
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
      /tmp/repostate-phase-d.*) rm -rf -- "$dir" ;;
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
  T="$(mktemp -d /tmp/repostate-phase-d.XXXXXX)"
  TEMP_DIRS+=("$T")
  R="$T/repo"
  # 与 phase_c/e 同款：数据隔离靠 REPO_STATE_* 覆盖；保留真实 HOME，
  # 否则 user-site 依赖（orjson/jieba）在测试进程里不可 import
  if [ -n "$ORIGINAL_HOME" ]; then
    export HOME="$ORIGINAL_HOME"
  else
    export HOME="$T/home"
  fi
  export REPO_STATE_CLAUDE_DIR="$T/claude"
  export REPO_STATE_CODEX_DIR="$T/codex"
  export REPO_STATE_DB="$T/transcripts.sqlite"
  export REPO_STATE_AUDIT_LOG="$T/query-audit.jsonl"
  mkdir -p "$R" "$T/home" "$REPO_STATE_CLAUDE_DIR/projects/proj" "$REPO_STATE_CODEX_DIR/sessions"
}

write_fixture() {
  python3 - "$R" "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard.jsonl" <<'PY'
import json, sys
repo, path = sys.argv[1], sys.argv[2]
rows = [
    {"type": "user", "uuid": "u-guard-1", "timestamp": "2026-07-09T00:00:00Z",
     "cwd": repo, "message": {"role": "user", "content": "guardmarker alpha question"}},
    {"type": "assistant", "uuid": "u-guard-2", "timestamp": "2026-07-09T00:00:01Z",
     "cwd": repo, "message": {"role": "assistant", "content": "guardmarker bravo answer"}},
]
with open(path, "w", encoding="utf-8") as fh:
    for row in rows:
        fh.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
}

sessions_count() {
  python3 - "$REPO_STATE_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(conn.execute("SELECT COUNT(*) FROM sessions").fetchone()[0])
PY
}

user_version() {
  python3 - "$REPO_STATE_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(conn.execute("PRAGMA user_version").fetchone()[0])
PY
}

set_user_version() {
  python3 - "$REPO_STATE_DB" "$1" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute(f"PRAGMA user_version={int(sys.argv[2])}")
conn.commit()
PY
}

drop_last_build() {
  python3 - "$REPO_STATE_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("DELETE FROM index_state WHERE jsonl_path='__last_build__'")
conn.commit()
PY
}

db_size() {
  python3 "$ROOT/tests/platform_checks.py" size "$REPO_STATE_DB"
}

db_inode() {
  python3 "$ROOT/tests/platform_checks.py" inode "$REPO_STATE_DB"
}

wait_finalized_candidate() {
  python3 - "$1" "$REPO_STATE_DB" "$ROOT/tests" <<'PY'
import glob, os, sys, time
sys.path.insert(0, sys.argv[3])
from platform_checks import open_paths
pid, db_path = int(sys.argv[1]), sys.argv[2]
deadline = time.monotonic() + 10
while time.monotonic() < deadline:
    try:
        os.kill(pid, 0)
        opened = open_paths(pid)
    except (ProcessLookupError, FileNotFoundError, OSError):
        raise SystemExit(1)
    for path in glob.glob(db_path + ".rebuild-*"):
        if path.endswith(("-wal", "-shm")):
            continue
        try:
            size = os.stat(path).st_size
        except FileNotFoundError:
            continue
        if (size > 0 and os.path.realpath(path) not in opened
                and os.path.realpath(path + "-wal") not in opened
                and os.path.realpath(path + "-shm") not in opened
                and not os.path.exists(path + "-wal")
                and not os.path.exists(path + "-shm")):
            raise SystemExit(0)
    time.sleep(0.02)
raise SystemExit(2)
PY
}

bloat_and_release_pages() {
  python3 - "$REPO_STATE_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("CREATE TABLE rebuild_bloat(payload BLOB)")
conn.execute("INSERT INTO rebuild_bloat VALUES(zeroblob(8 * 1024 * 1024))")
conn.commit()
conn.execute("DROP TABLE rebuild_bloat")
conn.commit()
PY
}

# ---------- D1 schema mismatch: query refuses, DB untouched ----------
new_transcript_env
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D1 setup index"
BEFORE_SESSIONS="$(sessions_count)"
set_user_version 11
if python3 "$ENGINE_SRC" search guardmarker --project-path "$R" \
     > "$T/d1.json" 2> "$T/d1.err"; then
  bad "D1 search on schema-mismatch DB must refuse (rc!=0)"
else ok; fi
grep -qi "schema 11!=" "$T/d1.json" && grep -qi "transcriptctl.py index" "$T/d1.json" \
  && ok || { bad "D1 refusal must name the actual reason (schema) and the fix (the index command)"; cat "$T/d1.err"; }
[ "$(user_version)" = "11" ] \
  && ok || bad "D1 refusal must not touch the DB (user_version changed)"
[ "$(sessions_count)" = "$BEFORE_SESSIONS" ] \
  && ok || bad "D1 refusal must not tear down tables (sessions lost)"

# ---------- D2 --no-index escape hatch still queries as-is ----------
if python3 "$ENGINE_SRC" search guardmarker --project-path "$R" --no-index \
     > "$T/d2.json" 2> "$T/d2.err"; then ok
else bad "D2 --no-index must bypass the guard"; cat "$T/d2.err"; fi

# ---------- D3 status on schema mismatch also refuses ----------
if python3 "$ENGINE_SRC" status > "$T/d3.json" 2> "$T/d3.err"; then
  bad "D3 status on schema-mismatch DB must refuse (rc!=0)"
else ok; fi

# ---------- D3b the refusal's advertised escape hatch must exist: status --no-index ----------
if python3 "$ENGINE_SRC" status --no-index > "$T/d3b.json" 2> "$T/d3b.err"; then ok
else bad "D3b status --no-index must bypass the guard"; cat "$T/d3b.err"; fi

# ---------- D4 explicit index performs the rebuild, search recovers ----------
CLEAN_REBUILD_SIZE="$(db_size)"
bloat_and_release_pages
BEFORE_REBUILD_SIZE="$(db_size)"
BEFORE_REBUILD_INODE="$(db_inode)"
if python3 "$ENGINE_SRC" index --rebuild > "$T/d4.out" 2>&1; then ok
else bad "D4 explicit index must be allowed to rebuild"; cat "$T/d4.out"; fi
[ ! -e "$REPO_STATE_DB-wal" ] && [ ! -e "$REPO_STATE_DB-shm" ] \
  && ok || bad "D4 published rebuild must not inherit WAL/SHM sidecars"
[ "$(user_version)" != "11" ] && ok || bad "D4 rebuild must bump schema"
[ "$(db_inode)" != "$BEFORE_REBUILD_INODE" ] \
  && ok || bad "D4 schema rebuild must publish a sibling database atomically"
[ "$((BEFORE_REBUILD_SIZE - $(db_size)))" -ge $((4 * 1024 * 1024)) ] \
  && ok || bad "D4 schema rebuild must physically release obsolete pages"
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" > "$T/d4.json" 2> "$T/d4.err" \
  && grep -q "u-guard-2" "$T/d4.json" \
  && ok || { bad "D4 search must work after explicit rebuild"; cat "$T/d4.err"; }

# ---------- D5 interrupted full build (__last_build__ missing): refuse ----------
drop_last_build
if python3 "$ENGINE_SRC" search guardmarker --project-path "$R" \
     > "$T/d5.json" 2> "$T/d5.err"; then
  bad "D5 search with no completed build must refuse (rc!=0)"
else ok; fi
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D5 re-index"

# ---------- D6 fresh env, DB never built: refuse with instruction ----------
new_transcript_env
write_fixture
if python3 "$ENGINE_SRC" search guardmarker --project-path "$R" \
     > "$T/d6.json" 2> "$T/d6.err"; then
  bad "D6 search before first build must refuse (rc!=0)"
else ok; fi
grep -qi "transcriptctl.py index\|index first\|not built yet" "$T/d6.json" \
  && ok || { bad "D6 refusal must name the fix"; cat "$T/d6.err"; }
[ ! -e "$REPO_STATE_DB" ] \
  && ok || bad "D6 refusal must not create the DB"
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D6 first build"
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" > "$T/d6b.json" 2>/dev/null \
  && grep -q "u-guard-2" "$T/d6b.json" \
  && ok || bad "D6 search must work after first build"

# ---------- D6c unwritable parent dir must not weaken the refusal into a silent build ----------
new_transcript_env
write_fixture
chmod 555 "$T"
if python3 "$ENGINE_SRC" search guardmarker --project-path "$R" \
     > /dev/null 2> "/tmp/d6c.err"; then
  bad "D6c search with unwritable index dir must still refuse (rc!=0)"
else ok; fi
chmod 755 "$T"
[ ! -e "$REPO_STATE_DB" ] \
  && ok || bad "D6c no DB may be created under an unwritable-dir refusal"
rm -f /tmp/d6c.err

# ---------- D8 segmenter flip: query stays on immutable old generation ----------
new_transcript_env
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D8 setup index"
python3 - "$REPO_STATE_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("UPDATE index_state SET prefix_sha='jieba-fake' WHERE jsonl_path='__segmenter__'")
conn.commit()
PY
python3 - "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard.jsonl" "$R" <<'PY'
import json, sys
row = {
    "type": "user", "uuid": "u-drift-new", "parentUuid": "u-guard-2",
    "timestamp": "2026-07-09T00:00:02Z", "cwd": sys.argv[2],
    "message": {"role": "user", "content": "driftnewmarker should wait for explicit index"},
}
with open(sys.argv[1], "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
python3 - "$REPO_STATE_DB" "$T/d8-before.json" <<'PY'
import hashlib, json, os, sqlite3, sys
db, out = sys.argv[1:]
conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
state = {
    "inode": os.stat(db).st_ino,
    "sha256": hashlib.sha256(open(db, "rb").read()).hexdigest(),
    "messages": conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0],
    "last_build": conn.execute(
        "SELECT mtime FROM index_state WHERE jsonl_path='__last_build__'"
    ).fetchone()[0],
    "source_lines": conn.execute(
        "SELECT lines_processed FROM index_state WHERE jsonl_path LIKE '%/S-guard.jsonl'"
    ).fetchone()[0],
    "marker": conn.execute(
        "SELECT prefix_sha FROM index_state WHERE jsonl_path='__segmenter__'"
    ).fetchone()[0],
}
json.dump(state, open(out, "w", encoding="utf-8"), sort_keys=True)
PY
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" > "$T/d8.json" 2> "$T/d8.err" \
  && grep -q "u-guard-2" "$T/d8.json" \
  && ok || { bad "D8 segmenter flip must degrade (query still answers), not refuse"; cat "$T/d8.err"; }
grep -qi "segmenter changed" "$T/d8.json" \
  && ok || { bad "D8 segmenter diagnostics must be observable in the JSON response"; cat "$T/d8.err"; }
python3 - "$T/d8.json" <<'PY' && ok || bad "D8 drift query must report every changed source as uncovered"
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
fresh = payload["index_freshness"]
assert fresh["mode"] == "base-only", fresh
assert fresh["changed_sources"] == 1, fresh
assert fresh["covered_changed_sources"] == 0, fresh
assert fresh["uncovered_changed_sources"] == 1, fresh
assert fresh["uncovered_main_sources"] == 1, fresh
assert fresh["complete"] is False, fresh
assert all("result_source" not in row for row in payload["data"]), payload
PY
python3 "$ENGINE_SRC" search driftnewmarker --project-path "$R" \
  >"$T/d8-new.json" 2>"$T/d8b.err"
python3 - "$T/d8-new.json" <<'PY' && ok || bad "D8 drift query must not expose current-segmenter overlay rows"
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["data"] == [], payload
PY
python3 - "$REPO_STATE_DB" "$T/d8-before.json" <<'PY' \
  && ok || bad "D8 drift query must not mutate the published generation"
import hashlib, json, os, sqlite3, sys
db, before_path = sys.argv[1:]
before = json.load(open(before_path, encoding="utf-8"))
conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
after = {
    "inode": os.stat(db).st_ino,
    "sha256": hashlib.sha256(open(db, "rb").read()).hexdigest(),
    "messages": conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0],
    "last_build": conn.execute(
        "SELECT mtime FROM index_state WHERE jsonl_path='__last_build__'"
    ).fetchone()[0],
    "source_lines": conn.execute(
        "SELECT lines_processed FROM index_state WHERE jsonl_path LIKE '%/S-guard.jsonl'"
    ).fetchone()[0],
    "marker": conn.execute(
        "SELECT prefix_sha FROM index_state WHERE jsonl_path='__segmenter__'"
    ).fetchone()[0],
}
assert after == before, (before, after)
PY
BEFORE_SEGMENTER_INODE="$(db_inode)"
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D8 resync index"
[ "$(db_inode)" != "$BEFORE_SEGMENTER_INODE" ] \
  && ok || bad "D8 segmenter resync must publish a sibling database atomically"
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" > "$T/d8c.json" 2> "$T/d8c.err"
grep -qi "segmenter changed" "$T/d8c.json" \
  && { bad "D8 explicit index must resync the marker (WARN must clear)"; cat "$T/d8c.err"; } || ok
python3 "$ENGINE_SRC" search driftnewmarker --project-path "$R" --no-index \
  >"$T/d8-new-after.json" 2>/dev/null
grep -q "u-drift-new" "$T/d8-new-after.json" \
  && ok || { bad "D8 explicit index must publish the previously uncovered message"; cat "$T/d8-new-after.json"; }

# ---------- D7 concurrent write lock: incremental refresh skipped, not fatal ----------
python3 - "$REPO_STATE_DB" <<'PY' &
import sqlite3, sys, time
conn = sqlite3.connect(sys.argv[1], timeout=1)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("BEGIN IMMEDIATE")
time.sleep(60)
conn.rollback()
PY
LOCK_PID=$!
sleep 1
if python3 "$ENGINE_SRC" search guardmarker --project-path "$R" \
     > "$T/d7.json" 2> "$T/d7.err"; then ok
else bad "D7 search under concurrent write lock must not die"; cat "$T/d7.err"; fi
grep -qi "skipped\|locked" "$T/d7.json" \
  && ok || { bad "D7 skipped refresh must be observable in the JSON response"; cat "$T/d7.err"; }
kill "$LOCK_PID" 2>/dev/null
wait "$LOCK_PID" 2>/dev/null

# ---------- D9 no-change quiet pass must not rewrite the inventory ----------
new_transcript_env
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D9 setup index"
python3 - "$REPO_STATE_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.execute("UPDATE source_inventory SET indexed_at='SENTINEL'")
conn.commit()
PY
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" >/dev/null 2>&1
DIRTY=$(python3 - "$REPO_STATE_DB" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
print(conn.execute("SELECT COUNT(*) FROM source_inventory WHERE indexed_at != 'SENTINEL'").fetchone()[0])
PY
)
[ "$DIRTY" = "0" ] \
  && ok || bad "D9 quiet pass with no source changes rewrote $DIRTY inventory rows"

# ---------- D10 full stat identity detects same-mtime rewrites without re-reading unchanged sources ----------
FIX="$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard.jsonl"
python3 - "$FIX" <<'PY'
import os, sys
p = sys.argv[1]
st = os.stat(p)
data = open(p, encoding="utf-8").read()
forged = data.replace("guardmarker bravo answer", "guardmarker forge answer")
assert len(forged.encode()) == st.st_size, "forge must preserve byte size"
open(p, "w", encoding="utf-8").write(forged)
os.utime(p, ns=(st.st_atime_ns, st.st_mtime_ns))
PY
python3 "$ENGINE_SRC" search forge --project-path "$R" > "$T/d10.json" 2>"$T/d10.err"
python3 - "$T/d10.json" <<'PY' \
  && ok || { bad "D10 query refresh must ingest a same-size same-mtime rewrite"; cat "$T/d10.err"; }
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert [row["uuid"] for row in payload["data"]] == ["u-guard-2"], payload
freshness = payload["index_freshness"]
assert freshness["complete"] is True, freshness
assert freshness["changed_sources"] == 1, freshness
PY
python3 - "$REPO_STATE_DB" "$FIX" <<'PY' \
  && ok || bad "D10 persisted stat identity and indexed text must match the rewritten source"
import os, sqlite3, sys
db, path = sys.argv[1:]
conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
assert conn.execute(
    "SELECT COUNT(*) FROM messages WHERE text LIKE '%guardmarker bravo%'"
).fetchone()[0] == 0
assert conn.execute(
    "SELECT COUNT(*) FROM messages WHERE text LIKE '%guardmarker forge%'"
).fetchone()[0] == 1
row = conn.execute(
    "SELECT device,inode,mtime_ns,ctime_ns,size FROM index_state WHERE jsonl_path=?",
    (path,),
).fetchone()
st = os.stat(path)
assert row == (st.st_dev, st.st_ino, st.st_mtime_ns, st.st_ctime_ns, st.st_size), row
PY
# A same-stat, content-identical rewrite refreshes only the cheap identity marker;
# it is not a logical source change and must not rewrite inventory metadata.
python3 - "$REPO_STATE_DB" "$FIX" <<'PY'
import os, sqlite3, sys
db, path = sys.argv[1:]
conn = sqlite3.connect(db)
conn.execute("UPDATE source_inventory SET indexed_at='D10-SENTINEL' WHERE source_path=?",
             (path,))
conn.commit()
st = os.stat(path)
data = open(path, encoding="utf-8").read()
open(path, "w", encoding="utf-8").write(data)
os.utime(path, ns=(st.st_atime_ns, st.st_mtime_ns))
PY
python3 "$ENGINE_SRC" search forge --project-path "$R" > "$T/d10b.json" 2>"$T/d10b.err"
python3 - "$T/d10b.json" "$REPO_STATE_DB" "$FIX" <<'PY' \
  && ok || { bad "D10 content-identical same-stat rewrites must remain a no-change query pass"; cat "$T/d10b.err"; }
import json, os, sqlite3, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert [row["uuid"] for row in payload["data"]] == ["u-guard-2"], payload
assert payload["index_freshness"]["changed_sources"] == 0, payload["index_freshness"]
conn = sqlite3.connect(f"file:{sys.argv[2]}?mode=ro", uri=True)
assert conn.execute(
    "SELECT indexed_at FROM source_inventory WHERE source_path=?", (sys.argv[3],)
).fetchone()[0] == "D10-SENTINEL"
PY

# ---------- D11 appended lines still land on the quiet pass ----------
python3 - "$R" "$FIX" <<'PY'
import json, sys
repo, p = sys.argv[1], sys.argv[2]
row = {"type": "assistant", "uuid": "u-guard-9", "timestamp": "2026-07-09T00:00:09Z",
       "cwd": repo, "message": {"role": "assistant", "content": "guardmarker appended tail"}}
open(p, "a", encoding="utf-8").write(json.dumps(row, ensure_ascii=False) + "\n")
PY
python3 "$ENGINE_SRC" search appended --project-path "$R" > "$T/d11.json" 2>/dev/null \
  && grep -q "u-guard-9" "$T/d11.json" \
  && ok || bad "D11 quiet pass must still ingest appended lines"

# ---------- D12 same-stat forge: drill-down paths must suppress stale text ----------
new_transcript_env
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D12 setup index"
FIX="$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard.jsonl"
python3 - "$FIX" <<'PY'
import os, sys
p = sys.argv[1]
st = os.stat(p)
data = open(p, encoding="utf-8").read()
forged = data.replace("guardmarker bravo answer", "guardmarker forge answer")
assert len(forged.encode()) == st.st_size, "forge must preserve byte size"
open(p, "w", encoding="utf-8").write(forged)
os.utime(p, (st.st_atime, st.st_mtime))
PY
python3 "$ENGINE_SRC" get-message u-guard-2 --no-index > "$T/d12.json" 2>/dev/null
grep -q '"evidence_status": "stale"' "$T/d12.json" \
  && ok || { bad "D12 get-message on forged row must report stale"; cat "$T/d12.json"; }
grep -q "bravo answer" "$T/d12.json" \
  && bad "D12 get-message must not emit stale text" || ok
# 行级语义：未被改动的 u-guard-1 行哈希仍验真，照常返回；被改的 u-guard-2 必须抑制
python3 "$ENGINE_SRC" get-messages u-guard-1 u-guard-2 --no-index > "$T/d12b.json" 2>/dev/null
grep -q "bravo answer" "$T/d12b.json" \
  && bad "D12 get-messages must not emit stale text" || ok
grep -q "alpha question" "$T/d12b.json" \
  && ok || bad "D12 get-messages must still return the untouched verified row"
cat > "$T/d12q.json" <<JSON
{"op":"get-message","uuid":"u-guard-2","project_path":"$R"}
JSON
python3 "$ENGINE_SRC" query "$T/d12q.json" --no-index > "$T/d12c.json" 2>/dev/null
grep -q "bravo answer" "$T/d12c.json" \
  && bad "D12 safe DSL get-message must not emit stale text" || ok
if python3 "$ENGINE_SRC" locate "guardmarker bravo answer" --message u-guard-2 --no-index \
     > "$T/d12d.json" 2>/dev/null; then
  bad "D12 locate must not anchor a quote against stale DB text (rc!=0 expected)"
else
  grep -q "bravo answer" "$T/d12d.json" \
    && bad "D12 locate must not emit stale snippet" || ok
fi

# ---------- D14 trusted python thread() must suppress stale rows ----------
cat > "$T/d14.py" <<'PY'
result = thread("S-guard")
PY
python3 "$ENGINE_SRC" query-python --trusted "$T/d14.py" --no-index > "$T/d14.json" 2>/dev/null
grep -q "bravo answer" "$T/d14.json" \
  && bad "D14 trusted thread() must not emit stale text" || ok
grep -q '"evidence_suppressed": true' "$T/d14.json" \
  && ok || { bad "D14 suppressed thread rows must carry evidence_suppressed"; cat "$T/d14.json"; }

# ---------- D13 same-stat cwd forge: sessions routing + session-report fail closed ----------
new_transcript_env
RB="$T/rep2"
mkdir -p "$RB"
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D13 setup index"
FIX="$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard.jsonl"
python3 - "$FIX" "$R" "$RB" <<'PY' || echo "D13-FORGE-FAILED"
import os, sys
p, ra, rb = sys.argv[1], sys.argv[2], sys.argv[3]
assert len(ra) == len(rb), "repo paths must be same length for same-stat forge"
st = os.stat(p)
data = open(p, encoding="utf-8").read()
forged = data.replace(ra, rb)
assert forged != data and len(forged.encode()) == st.st_size
open(p, "w", encoding="utf-8").write(forged)
os.utime(p, (st.st_atime, st.st_mtime))
PY
python3 "$ENGINE_SRC" sessions --project-path "$R" --no-index > "$T/d13.json" 2>/dev/null
grep -q "S-guard" "$T/d13.json" \
  && bad "D13 sessions must not route a stale (forged-cwd) session" || ok
if python3 "$ENGINE_SRC" session-report --session S-guard --decision-pattern "question" --no-index \
     > "$T/d13b.json" 2>/dev/null; then
  bad "D13 session-report on a stale session must refuse (rc!=0)"
else
  grep -q "not fresh" "$T/d13b.json" \
    && ok || { bad "D13 session-report refusal must name the status"; cat "$T/d13b.json"; }
fi
grep -q "alpha question" "$T/d13b.json" \
  && bad "D13 session-report must not emit stale decision candidates" || ok

# ---------- D15 finalize failure leaves the old database byte-for-byte intact ----------
new_transcript_env
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D15 setup index"
set_user_version 5
BEFORE_FAILED_HASH="$(python3 "$ROOT/tests/platform_checks.py" sha256 "$REPO_STATE_DB")"
BEFORE_FAILED_INODE="$(db_inode)"
BEFORE_FAILED_SESSIONS="$(sessions_count)"
# 公开输入已无法造出 invariant 失败（孤儿 agent 行如今按 skip 处理），
# 注入 validate_index_invariants 失败来验证 finalize 失败路径保旧库
if python3 - "$ENGINE_SRC" >"$T/d15.out" 2>"$T/d15.err" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("engine", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
def broken(db):
    raise RuntimeError("index invariant failure: injected candidate defect")
mod.validate_index_invariants = broken
mod.rebuild_and_publish(quiet=True)
PY
then
  bad "D15 rebuild with a final invariant failure must fail"
else ok; fi
grep -q "index invariant failure" "$T/d15.err" \
  && ok || { bad "D15 failure must identify the violated final invariant"; cat "$T/d15.err"; }
[ "$(python3 "$ROOT/tests/platform_checks.py" sha256 "$REPO_STATE_DB")" = "$BEFORE_FAILED_HASH" ] \
  && ok || bad "D15 failed rebuild must not modify the old database file"
[ "$(db_inode)" = "$BEFORE_FAILED_INODE" ] \
  && ok || bad "D15 failed rebuild must not replace the old database inode"
[ "$(sessions_count)" = "$BEFORE_FAILED_SESSIONS" ] \
  && ok || bad "D15 failed rebuild must preserve all old sessions"
[ "$(user_version)" = "5" ] \
  && ok || bad "D15 failed rebuild must preserve the old schema marker"
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" --no-index \
  >"$T/d15-search.json" 2>"$T/d15-search.err" \
  && grep -q "u-guard-2" "$T/d15-search.json" \
  && ok || { bad "D15 old database must remain queryable after failed rebuild"; cat "$T/d15-search.err"; }
[ -z "$(find "$T" -maxdepth 1 -name 'transcripts.sqlite.rebuild-*' -print -quit)" ] \
  && ok || bad "D15 failed rebuild must remove its sibling candidate"

# ---------- D16 append after a source read publishes, then incremental index fills the tail ----------
new_transcript_env
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D16 setup index"
python3 - "$R" "$REPO_STATE_CLAUDE_DIR/projects/proj/a-drift.jsonl" \
  "$REPO_STATE_CLAUDE_DIR/projects/proj/m-drift.jsonl" <<'PY'
import json, sys
repo, first, later = sys.argv[1:]
head = {
    "type": "assistant", "uuid": "u-drift-a",
    "timestamp": "2026-07-09T01:00:00Z", "cwd": repo,
    "message": {"role": "assistant", "content": "drift source alpha"},
}
with open(first, "w", encoding="utf-8") as fh:
    fh.write(json.dumps(head, separators=(",", ":")) + "\n")
tail = {
    "type": "assistant", "uuid": "u-drift-m",
    "timestamp": "2026-07-09T01:00:01Z", "cwd": repo,
    "message": {"role": "assistant", "content": "drift synchronization source"},
}
with open(later, "wb") as fh:
    fh.write((json.dumps(tail, separators=(",", ":")) + "\n").encode())
    fh.write(b"\n" * 2_000_000)
PY
BEFORE_DRIFT_INODE="$(db_inode)"
python3 - "$ENGINE_SRC" \
  "$REPO_STATE_CLAUDE_DIR/projects/proj/a-drift.jsonl" \
  "$REPO_STATE_CLAUDE_DIR/projects/proj/m-drift.jsonl" \
  "$T/d16.out" "$T/d16.err" "$R" "$ROOT/tests" <<'PY'
import json, os, signal, subprocess, sys, time
engine, first, later, stdout_path, stderr_path, repo, tests = sys.argv[1:]
sys.path.insert(0, tests)
from platform_checks import open_paths
with open(stdout_path, "w", encoding="utf-8") as stdout, \
     open(stderr_path, "w", encoding="utf-8") as stderr:
    proc = subprocess.Popen(
        [sys.executable, engine, "index", "--rebuild"], stdout=stdout, stderr=stderr)
    deadline = time.monotonic() + 10
    synchronized = False
    while proc.poll() is None and time.monotonic() < deadline:
        try:
            targets = open_paths(proc.pid)
        except (FileNotFoundError, OSError):
            continue
        if os.path.realpath(later) in targets:
            os.kill(proc.pid, signal.SIGSTOP)
            synchronized = True
            break
    if not synchronized:
        if proc.poll() is None:
            proc.terminate()
            proc.wait(timeout=5)
        raise SystemExit(97)
    row = {
        "type": "assistant", "uuid": "u-drift-a-2",
        "timestamp": "2026-07-09T01:00:02Z", "cwd": repo,
        "message": {"role": "assistant", "content": "drift source appended"},
    }
    with open(first, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(row, separators=(",", ":")) + "\n")
    os.kill(proc.pid, signal.SIGCONT)
    raise SystemExit(proc.wait(timeout=30))
PY
D16_RC=$?
if [ "$D16_RC" = "97" ]; then
  bad "D16 fixture could not synchronize with source ingestion"
elif [ "$D16_RC" = "0" ]; then
  ok
else
  bad "D16 append-only source drift must not abort rebuild"
  cat "$T/d16.err"
fi
[ "$(db_inode)" != "$BEFORE_DRIFT_INODE" ] \
  && ok || bad "D16 successful rebuild must atomically replace the database inode"
python3 - "$REPO_STATE_DB" "$REPO_STATE_CLAUDE_DIR/projects/proj/a-drift.jsonl" <<'PY' \
  && ok || bad "D16 candidate must contain exactly the source prefix read during rebuild"
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert conn.execute("SELECT COUNT(*) FROM messages WHERE uuid='u-drift-a'").fetchone()[0] == 1
assert conn.execute("SELECT COUNT(*) FROM messages WHERE uuid='u-drift-a-2'").fetchone()[0] == 0
state = conn.execute(
    "SELECT lines_processed,status FROM index_state WHERE jsonl_path=?", (sys.argv[2],)
).fetchone()
assert state == (1, "active"), state
PY
[ -z "$(find "$T" -maxdepth 1 -name 'transcripts.sqlite.rebuild-*' -print -quit)" ] \
  && ok || bad "D16 published rebuild must leave no sibling candidate"
python3 "$ENGINE_SRC" index >/dev/null 2>"$T/d16-incremental.err" \
  && ok || { bad "D16 incremental index must fill the appended tail"; cat "$T/d16-incremental.err"; }
python3 - "$REPO_STATE_DB" "$REPO_STATE_CLAUDE_DIR/projects/proj/a-drift.jsonl" <<'PY' \
  && ok || bad "D16 incremental index must register and expose the appended row"
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert conn.execute("SELECT COUNT(*) FROM messages WHERE uuid='u-drift-a-2'").fetchone()[0] == 1
state = conn.execute(
    "SELECT lines_processed,status FROM index_state WHERE jsonl_path=?", (sys.argv[2],)
).fetchone()
assert state == (2, "active"), state
PY
python3 "$ENGINE_SRC" search "drift source appended" --project-path "$R" --no-index \
  >"$T/d16-search.json" 2>"$T/d16-search.err" \
  && grep -q "u-drift-a-2" "$T/d16-search.json" \
  && ok || { bad "D16 appended row must be fresh after incremental fill"; cat "$T/d16-search.err"; }

# ---------- D17 a live transcriptctl reader blocks atomic publication ----------
new_transcript_env
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D17 setup index"
BEFORE_READER_INODE="$(db_inode)"
cat > "$T/d17-reader.py" <<'PY'
import os, time
result = sql("SELECT COUNT(*) AS count FROM sessions")
os.mkdir(os.environ["D17_READY"])
while not os.path.isdir(os.environ["D17_RELEASE"]):
    time.sleep(0.02)
PY
D17_READY="$T/d17-ready" D17_RELEASE="$T/d17-release" \
  python3 "$ENGINE_SRC" query-python --trusted "$T/d17-reader.py" --no-index \
  >"$T/d17-reader.out" 2>"$T/d17-reader.err" &
D17_READER_PID=$!
python3 - "$D17_READER_PID" "$T/d17-ready" <<'PY'
import os, sys, time
pid, ready = int(sys.argv[1]), sys.argv[2]
deadline = time.monotonic() + 10
while not os.path.isdir(ready):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        raise SystemExit(1)
    if time.monotonic() >= deadline:
        raise SystemExit(2)
    time.sleep(0.02)
PY
D17_SYNC_RC=$?
if [ "$D17_SYNC_RC" != "0" ]; then
  bad "D17 reader did not reach its live query window"
  cat "$T/d17-reader.err"
  mkdir -p "$T/d17-release"
fi
python3 "$ENGINE_SRC" index --rebuild >"$T/d17-rebuild.out" 2>"$T/d17-rebuild.err" &
D17_REBUILD_PID=$!
wait_finalized_candidate "$D17_REBUILD_PID"
D17_BUILD_RC=$?
if [ "$D17_BUILD_RC" = "0" ]; then
  ok
else
  bad "D17 rebuild did not finish its candidate while the reader was live"
  cat "$T/d17-rebuild.err"
fi
if kill -0 "$D17_REBUILD_PID" 2>/dev/null; then
  ok
else
  bad "D17 rebuild must wait for the live reader before publication"
fi
[ "$(db_inode)" = "$BEFORE_READER_INODE" ] \
  && ok || bad "D17 live reader must keep the published database inode stable"
mkdir -p "$T/d17-release"
wait "$D17_READER_PID" \
  && ok || { bad "D17 reader must finish normally"; cat "$T/d17-reader.err"; }
wait "$D17_REBUILD_PID" \
  && ok || { bad "D17 rebuild must publish after the reader exits"; cat "$T/d17-rebuild.err"; }
[ "$(db_inode)" != "$BEFORE_READER_INODE" ] \
  && ok || bad "D17 rebuild must replace the database after the reader exits"
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" --no-index \
  >"$T/d17-search.json" 2>"$T/d17-search.err" \
  && grep -q "u-guard-2" "$T/d17-search.json" \
  && ok || { bad "D17 published database must remain queryable"; cat "$T/d17-search.err"; }

# ---------- D18 publication cannot enter the ensure_index -> open_ro handoff ----------
new_transcript_env
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D18 setup index"
BEFORE_HANDOFF_INODE="$(db_inode)"
cat > "$T/d18-reader.py" <<'PY'
import importlib.util, os, sys, time
spec = importlib.util.spec_from_file_location("transcriptctl_under_test", sys.argv[1])
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
engine.ensure_index(no_index=True)
os.mkdir(os.environ["D18_READY"])
while not os.path.isdir(os.environ["D18_RELEASE"]):
    time.sleep(0.02)
conn = engine.open_ro()
assert conn.execute("SELECT COUNT(*) AS count FROM sessions").fetchone()["count"] == 1
conn.close()
PY
D18_READY="$T/d18-ready" D18_RELEASE="$T/d18-release" \
  python3 "$T/d18-reader.py" "$ENGINE_SRC" \
  >"$T/d18-reader.out" 2>"$T/d18-reader.err" &
D18_READER_PID=$!
python3 - "$D18_READER_PID" "$T/d18-ready" <<'PY'
import os, sys, time
pid, ready = int(sys.argv[1]), sys.argv[2]
deadline = time.monotonic() + 10
while not os.path.isdir(ready):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        raise SystemExit(1)
    if time.monotonic() >= deadline:
        raise SystemExit(2)
    time.sleep(0.02)
PY
D18_SYNC_RC=$?
if [ "$D18_SYNC_RC" != "0" ]; then
  bad "D18 reader did not reach the query handoff window"
  cat "$T/d18-reader.err"
  mkdir -p "$T/d18-release"
fi
python3 "$ENGINE_SRC" index --rebuild >"$T/d18-rebuild.out" 2>"$T/d18-rebuild.err" &
D18_REBUILD_PID=$!
wait_finalized_candidate "$D18_REBUILD_PID"
D18_BUILD_RC=$?
if [ "$D18_BUILD_RC" != "0" ]; then
  bad "D18 rebuild did not finish its candidate inside the handoff window"
  cat "$T/d18-rebuild.err"
elif ! kill -0 "$D18_REBUILD_PID" 2>/dev/null; then
  bad "D18 rebuild exited before the handoff reader released"
  cat "$T/d18-rebuild.err"
elif [ "$(db_inode)" != "$BEFORE_HANDOFF_INODE" ]; then
  bad "D18 rebuild published inside the query handoff window"
else
  ok
fi
mkdir -p "$T/d18-release"
wait "$D18_READER_PID" \
  && ok || { bad "D18 handoff reader must finish normally"; cat "$T/d18-reader.err"; }
wait "$D18_REBUILD_PID" \
  && ok || { bad "D18 rebuild must publish after the handoff reader exits"; cat "$T/d18-rebuild.err"; }
[ "$(db_inode)" != "$BEFORE_HANDOFF_INODE" ] \
  && ok || bad "D18 rebuild must replace the database after the handoff reader exits"

# ---------- D19 an empty rebuild manifest remains a strict snapshot ----------
new_transcript_env
python3 - "$ENGINE_SRC" "$REPO_STATE_CLAUDE_DIR/projects/proj/S-empty/workflows" <<'PY'
import importlib.util, json, os, sys
engine_path, workflow_dir = sys.argv[1:]
spec = importlib.util.spec_from_file_location("transcriptctl_under_test", engine_path)
engine = importlib.util.module_from_spec(spec)
spec.loader.exec_module(engine)
assert engine.discover_rebuild_inputs() == ()
os.makedirs(workflow_dir)
with open(os.path.join(workflow_dir, "late.json"), "w", encoding="utf-8") as fh:
    json.dump({"runId": "late-workflow", "timestamp": "2026-07-09T00:00:00Z"}, fh)
db = engine.open_memory_index()
engine.index_sources(db, [], [], snapshot_entries={}, trust_stat=False)
assert db.execute("SELECT COUNT(*) FROM workflows").fetchone()[0] == 0
db.close()
PY
[ "$?" = "0" ] \
  && ok || bad "D19 empty snapshot mode must not rediscover later auxiliary inputs"

# ---------- D20 parser-error transcript does not hide its manifest meta ----------
new_transcript_env
write_fixture
mkdir -p "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard/subagents"
cat > "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard/subagents/a1.jsonl" <<'EOF'
{"type":"assistant","uuid":"a1-bad","timestamp":"2026-07-09T00:01:00Z","message":"bad-structure"}
EOF
cat > "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard/subagents/a1.meta.json" <<'EOF'
{
  "agentType": "reviewer",
  "description": "paired meta survives transcript parser error",
  "toolUseId": "tool-a1"
}
EOF
if python3 "$ENGINE_SRC" index --rebuild >"$T/d20-index.out" 2>"$T/d20-index.err"; then
  ok
else
  bad "D20 rebuild must retain the transcript parser-error contract"
  cat "$T/d20-index.err"
fi
grep -q "a1.jsonl" "$T/d20-index.err" \
  && ok || { bad "D20 parser-error transcript must remain observable"; cat "$T/d20-index.err"; }
cat > "$T/d20-query.py" <<'PY'
result = subagents("S-guard")
PY
python3 "$ENGINE_SRC" query-python --trusted "$T/d20-query.py" --no-index \
  >"$T/d20-query.json" 2>"$T/d20-query.err" \
  && grep -q '"agent_id": "a1"' "$T/d20-query.json" \
  && grep -q '"agent_type": "reviewer"' "$T/d20-query.json" \
  && ok || { bad "D20 manifest meta must be consumed independently"; cat "$T/d20-query.err"; cat "$T/d20-query.json"; }

# ---------- D21 concurrent query refreshes never turn lock contention into parser-error ----------
new_transcript_env
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D21 setup index"
python3 - "$R" "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard.jsonl" <<'PY'
import json, sys
repo, path = sys.argv[1:]
with open(path, "a", encoding="utf-8") as fh:
    for i in range(12000):
        row = {
            "type": "assistant", "uuid": f"u-race-{i}",
            "timestamp": f"2026-07-09T01:{i // 60:02d}:{i % 60:02d}Z", "cwd": repo,
            "message": {"role": "assistant", "content": f"racewriter marker {i}"},
        }
        fh.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
python3 "$ENGINE_SRC" search racewriter --project-path "$R" \
  >"$T/d21-a.json" 2>"$T/d21-a.err" &
D21_A_PID=$!
python3 "$ENGINE_SRC" search racewriter --project-path "$R" \
  >"$T/d21-b.json" 2>"$T/d21-b.err" &
D21_B_PID=$!
wait "$D21_A_PID" \
  && ok || { bad "D21 first concurrent query must complete"; cat "$T/d21-a.err"; }
wait "$D21_B_PID" \
  && ok || { bad "D21 second concurrent query must complete"; cat "$T/d21-b.err"; }
grep -q 'u-race-' "$T/d21-a.json" \
  && grep -q 'u-race-' "$T/d21-b.json" \
  && ok || bad "D21 both concurrent queries must retrieve the changed source"
python3 - "$REPO_STATE_DB" "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard.jsonl" <<'PY' \
  && ok || bad "D21 lock contention must preserve the healthy source as active"
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
state = conn.execute(
    "SELECT i.status, s.status FROM index_state i JOIN source_inventory s"
    " ON s.source_path=i.jsonl_path WHERE i.jsonl_path=?", (sys.argv[2],),
).fetchone()
assert state == ("active", "active"), state
assert conn.execute(
    "SELECT COUNT(*) FROM messages WHERE session_id='S-guard' AND uuid LIKE 'u-race-%'"
).fetchone()[0] == 12000
PY

# ---------- D22 a vanished main transcript takes its agent-thread rows with it ----------
new_transcript_env
write_fixture
mkdir -p "$REPO_STATE_CLAUDE_DIR/projects/proj/S-orph/subagents"
python3 - "$R" "$REPO_STATE_CLAUDE_DIR/projects/proj" <<'PY'
import json, sys
repo, proj = sys.argv[1], sys.argv[2]
with open(f"{proj}/S-orph.jsonl", "w", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "type": "user", "uuid": "orph-main-1",
        "timestamp": "2026-07-21T00:00:00Z", "cwd": repo,
        "message": {"role": "user", "content": "orphanmarker main question"},
    }, separators=(",", ":")) + "\n")
with open(f"{proj}/S-orph/subagents/agent-orph.jsonl", "w", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "type": "assistant", "uuid": "orph-sub-1",
        "timestamp": "2026-07-21T00:01:00Z", "cwd": repo,
        "message": {"role": "assistant", "content": "orphanmarker agent output"},
    }, separators=(",", ":")) + "\n")
PY
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D22 setup index"
python3 - "$REPO_STATE_DB" <<'PY' && ok || bad "D22 setup must index the agent-thread row"
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert conn.execute("SELECT COUNT(*) FROM messages WHERE session_id='S-orph'"
                    " AND agent_id='agent-orph'").fetchone()[0] == 1
PY
rm "$REPO_STATE_CLAUDE_DIR/projects/proj/S-orph.jsonl"
python3 "$ENGINE_SRC" sessions --project-path "$R" >/dev/null 2>"$T/d22.err" \
  && ok || { bad "D22 queries must survive a vanished main transcript"; sed -n '1,6p' "$T/d22.err"; }
python3 - "$REPO_STATE_DB" <<'PY' && ok || bad "D22 vanished main must take its agent rows with it"
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert conn.execute("SELECT COUNT(*) FROM messages WHERE session_id='S-orph'").fetchone()[0] == 0
assert conn.execute("SELECT COUNT(*) FROM sessions WHERE id='S-orph'").fetchone()[0] == 0
assert conn.execute("SELECT COUNT(*) FROM messages WHERE session_id='S-guard'").fetchone()[0] == 2
PY
python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>"$T/d22r.err" \
  && ok || { bad "D22 full rebuild must succeed with the orphaned agent file still on disk"; sed -n '1,6p' "$T/d22r.err"; }

# ---------- D23 a parser-error main transcript strands no agent rows ----------
new_transcript_env
write_fixture
mkdir -p "$REPO_STATE_CLAUDE_DIR/projects/proj/S-orph/subagents"
python3 - "$R" "$REPO_STATE_CLAUDE_DIR/projects/proj" <<'PY'
import json, sys
repo, proj = sys.argv[1], sys.argv[2]
with open(f"{proj}/S-orph.jsonl", "w", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "type": "user", "uuid": "orph-main-1",
        "timestamp": "2026-07-21T00:00:00Z", "cwd": repo,
        "message": {"role": "user", "content": "orphanmarker main question"},
    }, separators=(",", ":")) + "\n")
with open(f"{proj}/S-orph/subagents/agent-orph.jsonl", "w", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "type": "assistant", "uuid": "orph-sub-1",
        "timestamp": "2026-07-21T00:01:00Z", "cwd": repo,
        "message": {"role": "assistant", "content": "orphanmarker agent output"},
    }, separators=(",", ":")) + "\n")
PY
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D23 setup index"
printf '%s\n' '{"type":"user","uuid":"orph-main-2","timestamp":"2026-07-21T00:02:00Z","message":"not an object"}' \
  >> "$REPO_STATE_CLAUDE_DIR/projects/proj/S-orph.jsonl"
# sessions 在 uncovered 主源上按合同报错退出，用 search 验证引擎存活；
# 连查两次：第二次会走到孤儿登记的幂等分支（第一次后状态已是 parser-error）
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" >/dev/null 2>"$T/d23.err" \
  && ok || { bad "D23 queries must survive a parser-error main transcript"; sed -n '1,6p' "$T/d23.err"; }
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" >/dev/null 2>"$T/d23b.err" \
  && ok || { bad "D23 the second query must hit the idempotent orphan branch and survive"; sed -n '1,6p' "$T/d23b.err"; }
python3 - "$REPO_STATE_DB" <<'PY' && ok || bad "D23 parser-error main must strand no agent rows"
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert conn.execute("SELECT COUNT(*) FROM messages WHERE session_id='S-orph'").fetchone()[0] == 0
assert conn.execute("SELECT COUNT(*) FROM sessions WHERE id='S-orph'").fetchone()[0] == 0
state = conn.execute("SELECT status FROM index_state WHERE jsonl_path LIKE '%S-orph.jsonl'").fetchone()
assert state and state[0] == "parser-error", state
assert conn.execute("SELECT COUNT(*) FROM messages WHERE session_id='S-guard'").fetchone()[0] == 2
PY
python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>"$T/d23r.err" \
  && ok || { bad "D23 full rebuild must succeed while the main transcript stays unparseable"; sed -n '1,6p' "$T/d23r.err"; }

# ---------- D24 explicit index recovers a corrupt published database ----------
new_transcript_env
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D24 setup index"
printf 'garbage, not a sqlite file...............' > "$REPO_STATE_DB"
rm -f "$REPO_STATE_DB-wal" "$REPO_STATE_DB-shm"
python3 "$ENGINE_SRC" index >/dev/null 2>"$T/d24.err" \
  && ok || { bad "D24 explicit index must recover a corrupt published database"; sed -n '1,8p' "$T/d24.err"; }
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" --no-index 2>/dev/null \
  | grep -q "u-guard-1" && ok || bad "D24 recovered database must serve queries"

# ---------- D25 stale candidate leftovers are collected by the next full rebuild ----------
new_transcript_env
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D25 setup index"
printf 'stale' > "$T/transcripts.sqlite.rebuild-stale0"
printf 'stale' > "$T/transcripts.sqlite.rebuild-stale0-wal"
python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>&1 || bad "D25 rebuild with leftovers"
if ls "$T"/transcripts.sqlite.rebuild-* >/dev/null 2>&1; then
  bad "D25 stale rebuild candidates must be collected"
else
  ok
fi
python3 - "$ENGINE_SRC" <<'PY' && ok || bad "D25 a vanished rebuild input must be reported as SourceChanged"
import importlib.util, sys
spec = importlib.util.spec_from_file_location("engine", sys.argv[1])
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
try:
    mod.snapshot_file("/nonexistent/repo-state-d25")
except mod.SourceChanged:
    pass
else:
    raise AssertionError("expected SourceChanged")
PY

# ---------- D26 non-object auxiliary inputs must not abort a full rebuild ----------
new_transcript_env
write_fixture
mkdir -p "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard/subagents" \
         "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard/workflows"
python3 - "$R" "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard/subagents/agent-aux.jsonl" <<'PY'
import json, sys
repo, path = sys.argv[1:]
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "type": "assistant", "uuid": "aux-sub-1",
        "timestamp": "2026-07-09T00:00:03Z", "cwd": repo,
        "message": {"role": "assistant", "content": "auxguard agent output"},
    }, separators=(",", ":")) + "\n")
PY
printf '[]\n' > "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard/subagents/agent-aux.meta.json"
printf '[]\n' > "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard/workflows/wf1.json"
printf '[]\n' > "$REPO_STATE_CLAUDE_DIR/history.jsonl"
printf '[]\n' > "$REPO_STATE_CODEX_DIR/session_index.jsonl"
python3 "$ENGINE_SRC" index --rebuild >/dev/null 2>"$T/d26.err" \
  && ok || { bad "D26 full rebuild must survive non-object auxiliary inputs"; sed -n '1,8p' "$T/d26.err"; }
python3 - "$REPO_STATE_DB" <<'PY' && ok || bad "D26 transcript rows must survive non-object sibling meta"
import sqlite3, sys
conn = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
assert conn.execute("SELECT COUNT(*) FROM messages WHERE uuid='u-guard-1'").fetchone()[0] == 1
assert conn.execute("SELECT COUNT(*) FROM messages WHERE uuid='aux-sub-1'").fetchone()[0] == 1
PY
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" --no-index 2>/dev/null \
  | grep -q "u-guard-1" && ok || bad "D26 queries must work after the rebuild"

# ---------- D27 an unterminated invalid tail is uncovered, while stable malformed/valid EOF rows keep their contracts ----------
new_transcript_env
write_fixture
python3 "$ENGINE_SRC" index >/dev/null 2>&1 || bad "D27 setup index"
TAIL_SOURCE="$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard.jsonl"
python3 - "$TAIL_SOURCE" "$R" "$T/d27-tail.json" <<'PY'
import json, sys
path, cwd, saved = sys.argv[1:]
row = {
    "type": "assistant", "uuid": "u-tail-incomplete",
    "timestamp": "2026-07-09T00:00:03Z", "cwd": cwd,
    "message": {"role": "assistant", "content": "tailcompletionmarker resolved"},
}
encoded = json.dumps(row, separators=(",", ":"))
split = len(encoded) - 4
with open(path, "a", encoding="utf-8") as fh:
    fh.write(encoded[:split])
with open(saved, "w", encoding="utf-8") as fh:
    json.dump({"tail": encoded[split:]}, fh)
PY
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" > "$T/d27.json" 2>"$T/d27.err"
python3 - "$T/d27.json" <<'PY' \
  && ok || { bad "D27 a torn invalid tail must keep prior evidence but make freshness incomplete"; cat "$T/d27.err"; }
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert {row["uuid"] for row in payload["data"]} == {"u-guard-1", "u-guard-2"}, payload
freshness = payload["index_freshness"]
assert freshness["complete"] is False, freshness
assert freshness["uncovered_changed_sources"] == 1, freshness
PY
if python3 "$ENGINE_SRC" index >"$T/d27-index.json" 2>"$T/d27-index.err"; then
  bad "D27 explicit index must not publish an incomplete trailing record"
else
  grep -qi "unterminated\|incomplete" "$T/d27-index.json" \
    && ok || { bad "D27 explicit index failure must name the incomplete tail"; cat "$T/d27-index.err"; }
fi
python3 - "$TAIL_SOURCE" "$T/d27-tail.json" <<'PY'
import json, sys
path, saved = sys.argv[1:]
tail = json.load(open(saved, encoding="utf-8"))["tail"]
with open(path, "a", encoding="utf-8") as fh:
    fh.write(tail + "\n")
PY
python3 "$ENGINE_SRC" search tailcompletionmarker --project-path "$R" \
  > "$T/d27-complete.json" 2>"$T/d27-complete.err"
python3 - "$T/d27-complete.json" "$REPO_STATE_DB" <<'PY' \
  && ok || { bad "D27 completing the same tail must recover exactly one message"; cat "$T/d27-complete.err"; }
import json, sqlite3, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert [row["uuid"] for row in payload["data"]] == ["u-tail-incomplete"], payload
assert payload["index_freshness"]["complete"] is True, payload["index_freshness"]
conn = sqlite3.connect(f"file:{sys.argv[2]}?mode=ro", uri=True)
assert conn.execute(
    "SELECT COUNT(*) FROM messages WHERE uuid='u-tail-incomplete'"
).fetchone()[0] == 1
PY

# A syntactically valid final record does not require a trailing newline.
new_transcript_env
python3 - "$REPO_STATE_CLAUDE_DIR/projects/proj/legal-eof.jsonl" "$R" <<'PY'
import json, sys
path, cwd = sys.argv[1:]
row = {"type": "assistant", "uuid": "u-legal-eof",
       "timestamp": "2026-07-09T00:00:00Z", "cwd": cwd,
       "message": {"role": "assistant", "content": "legaleofmarker accepted"}}
open(path, "w", encoding="utf-8").write(json.dumps(row, separators=(",", ":")))
PY
python3 "$ENGINE_SRC" index >/dev/null 2>"$T/d27-legal-index.err" \
  && python3 "$ENGINE_SRC" search legaleofmarker --project-path "$R" \
       > "$T/d27-legal.json" 2>"$T/d27-legal.err" \
  && grep -q "u-legal-eof" "$T/d27-legal.json" \
  && ok || { bad "D27 valid JSON at EOF must remain immediately indexable"; cat "$T/d27-legal-index.err" "$T/d27-legal.err"; }

# A newline-terminated malformed record remains a durable parser skip, not a live tail.
new_transcript_env
write_fixture
printf '%s\n' '{"type":"assistant","uuid":"u-malformed"' \
  >> "$REPO_STATE_CLAUDE_DIR/projects/proj/S-guard.jsonl"
python3 "$ENGINE_SRC" index >/dev/null 2>"$T/d27-malformed-index.err" \
  || { bad "D27 newline-terminated malformed setup must index with a durable skip"; cat "$T/d27-malformed-index.err"; }
python3 "$ENGINE_SRC" search guardmarker --project-path "$R" \
  > "$T/d27-malformed.json" 2>"$T/d27-malformed.err"
python3 - "$T/d27-malformed.json" <<'PY' \
  && ok || { bad "D27 newline-terminated malformed rows must preserve parser-skipped evidence"; cat "$T/d27-malformed.err"; }
import json, sys
payload = json.load(open(sys.argv[1], encoding="utf-8"))
assert payload["index_freshness"]["complete"] is True, payload["index_freshness"]
assert {row["uuid"] for row in payload["data"]} == {"u-guard-1", "u-guard-2"}, payload
assert all(row["evidence_status"] == "parser-skipped" for row in payload["data"]), payload
PY

echo
echo "phase-d-pass=$PASS phase-d-fail=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo -e "failed:$FAILED"
  exit 1
fi
exit 0
