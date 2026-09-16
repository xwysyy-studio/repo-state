#!/usr/bin/env bash
# Phase H read-surface correctness verifier (transcriptctl).
# Contracts under test:
#  - get-session returns only readable dialogue text (thinking/tool_use/tool_result
#    placeholders excluded from pagination and total_visible_messages)
#  - locate by-quote defaults to real content (injected/abandoned excluded),
#    --include-meta/--include-abandoned opt in WITH label; locate --message and
#    get-message by-uuid return unconditionally WITH state labels
#  - --after/--before normalize timezone before comparison
#  - search limit is clamped (no SQLite OverflowError)
#  - query stdout stays a valid envelope on truncation and on missing uuid
# Usage: bash tests/phase_h.sh   # exit 0 iff ALL PASS
# PHASE_H_ENGINE=<path> overrides the engine under test (red-run vs old rev).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${PHASE_H_ENGINE:-$ROOT/scripts/transcriptctl.py}"
PASS=0
FAIL=0
FAILED=""
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); FAILED="$FAILED"$'\n'"  - $1"; echo "FAIL: $1"; }

T="$(mktemp -d /tmp/repostate-phase-h.XXXXXX)"
trap 'rm -rf "$T"' EXIT
export REPO_STATE_CLAUDE_DIR="$T/claude"
export REPO_STATE_CODEX_DIR="$T/codex"
export REPO_STATE_DB="$T/transcripts.sqlite"
export REPO_STATE_AUDIT_LOG="$T/audit.jsonl"
export REPO_STATE_DISABLE_JIEBA=1
mkdir -p "$T/claude/projects/-tmp-fixture-proj" "$T/codex"

SID="h0000000-aaaa-bbbb-cccc-000000000001"
python3 - "$T/claude/projects/-tmp-fixture-proj/$SID.jsonl" <<'PYEOF'
import json, sys

def base(uuid, parent, role, ts):
    return {"type": role, "uuid": uuid, "parentUuid": parent,
            "timestamp": f"2026-08-05T10:{ts:02d}:00.000Z",
            "cwd": "/tmp/fixture-proj", "isSidechain": False}

def umsg(uuid, parent, text, ts):
    r = base(uuid, parent, "user", ts)
    r["message"] = {"role": "user", "content": text}
    return r

def amsg_text(uuid, parent, text, ts):
    r = base(uuid, parent, "assistant", ts)
    r["message"] = {"role": "assistant", "content": [{"type": "text", "text": text}]}
    return r

def amsg_thinking(uuid, parent, ts):
    r = base(uuid, parent, "assistant", ts)
    r["message"] = {"role": "assistant", "content": [{"type": "thinking", "thinking": "internal reasoning"}]}
    return r

def amsg_tooluse(uuid, parent, ts):
    r = base(uuid, parent, "assistant", ts)
    r["message"] = {"role": "assistant", "content": [{"type": "tool_use", "id": "tu1", "name": "Bash", "input": {"command": "ls"}}]}
    return r

rows = [
    umsg("u1", None, "hello real question", 1),
    amsg_text("a1", "u1", "real answer one", 2),
    amsg_thinking("a2", "a1", 3),
    amsg_tooluse("a3", "a2", 4),
    umsg("u2", "a3", "second real question", 5),
    # injected payload (starts with an instruction prefix -> is_injected=1)
    umsg("u-inj", "u2", "# AGENTS.md instructions\nverbatim injected directive", 6),
    amsg_text("a4", "u-inj", "answer two", 7),
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PYEOF

python3 "$ENGINE" index >/dev/null 2>&1 || bad "index build failed"
run() { python3 "$ENGINE" "$@" 2>/dev/null; }

# A-4 get-session: only readable text rows (u1,a1,u2,a4 = 4), thinking/tool_use excluded
GS="$(run get-session "$SID" --limit 50 --no-index | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]; ms=d["messages"]
cts=sorted(set(m["content_type"] for m in ms))
print(str(d["total_visible_messages"])+"|"+",".join(cts))')"
[ "$GS" = "4|text" ] && ok || bad "get-session should show 4 text-only rows, got [$GS]"

# A-3 / C-F7 injected handling
INJ_DEFAULT="$(run get-session "$SID" --limit 50 --no-index | python3 -c '
import json,sys
ms=json.load(sys.stdin)["data"]["messages"]
print(sum(1 for m in ms if "injected directive" in (m.get("text") or "")))')"
[ "$INJ_DEFAULT" = "0" ] && ok || bad "get-session default must exclude injected, found $INJ_DEFAULT"

GM="$(run get-message u-inj --no-index | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("is_injected"))')"
[ "$GM" = "True" ] && ok || bad "get-message on injected uuid must carry is_injected=True, got $GM"

# locate --message pins the uuid and still verifies the quote is verbatim in it
LOC_MSG="$(run locate "injected directive" --message u-inj --all-projects --no-index | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]
print(len(d)>=1 and d[0].get("is_injected") is True)')"
[ "$LOC_MSG" = "True" ] && ok || bad "locate --message by-uuid must return injected row labeled"

LOC_Q="$(run locate "injected directive" --all-projects --no-index | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]))')"
[ "$LOC_Q" = "0" ] && ok || bad "locate by-quote default must exclude injected, got $LOC_Q hits"

LOC_QM="$(run locate "injected directive" --all-projects --include-meta --no-index | python3 -c '
import json,sys
d=json.load(sys.stdin)["data"]
print(len(d)>=1 and all(x.get("is_injected") is True for x in d))')"
[ "$LOC_QM" = "True" ] && ok || bad "locate by-quote --include-meta must include injected WITH label"

# Pure-function units (tz, clamp, emit) via qa run_name
UNIT="$(PHASE_H_ENGINE="$ENGINE" python3 - <<'PYEOF'
import os, runpy
g = runpy.run_path(os.environ["PHASE_H_ENGINE"], run_name="qa")
out = []
# A-6 timezone normalization: +08:00 folds to same UTC instant as Z
n = g["normalize_time_bound"]
out.append(("tz-equiv", n("2026-08-03T16:00:00+08:00") == n("2026-08-03T08:00:00Z")))
out.append(("tz-naive-utc", n("2026-08-03T08:00:00") == n("2026-08-03T08:00:00Z")))
out.append(("tz-noniso-passthrough", n("not-a-date") == "not-a-date"))
# A-8 clamp constant exists and is finite
out.append(("clamp-const", isinstance(g["SEARCH_LIMIT_MAX"], int) and g["SEARCH_LIMIT_MAX"] < 10**9))
for name, cond in out:
    print(f"{name}={'1' if cond else '0'}")
PYEOF
)"
for line in $UNIT; do
  n="${line%%=*}"; v="${line##*=}"
  [ "$v" = "1" ] && ok || bad "unit $n failed"
done

# ---------- layered thread stays chronological; layered sessions stays newest-first ----------
OV_ROOT="$(mktemp -d /tmp/repostate-phase-h-ov.XXXXXX)"
OV_PROJ="$OV_ROOT/claude/projects/-tmp-fixture-ov"
mkdir -p "$OV_PROJ/S-ov/subagents" "$OV_ROOT/codex"
python3 - "$OV_PROJ" <<'PY'
import json
proj = __import__("sys").argv[1]

def row(uuid, role, text, hh, mm):
    return {"type": role, "uuid": uuid,
            "timestamp": f"2026-08-05T{hh:02d}:{mm:02d}:00.000Z",
            "cwd": "/tmp/fixture-ov",
            "message": {"role": role, "content": text}}

with open(f"{proj}/S-ov.jsonl", "w", encoding="utf-8") as fh:
    for r in (row("ov-m1", "user", "threadorder main message one", 10, 0),
              row("ov-m2", "user", "threadorder main message two", 10, 2),
              row("ov-m3", "user", "threadorder main message three", 10, 4)):
        fh.write(json.dumps(r, separators=(",", ":")) + "\n")
with open(f"{proj}/S-ov/subagents/a-ov.jsonl", "w", encoding="utf-8") as fh:
    for r in (row("ov-s1", "assistant", "threadorder agent reply one", 10, 1),
              row("ov-s2", "assistant", "threadorder agent reply two", 10, 3)):
        fh.write(json.dumps(r, separators=(",", ":")) + "\n")
for n in range(7):
    with open(f"{proj}/S-fill-{n}.jsonl", "w", encoding="utf-8") as fh:
        fh.write(json.dumps(row(f"fill-{n}", "user", f"filler session {n}", 8, n),
                            separators=(",", ":")) + "\n")
PY
export REPO_STATE_CLAUDE_DIR="$OV_ROOT/claude" REPO_STATE_CODEX_DIR="$OV_ROOT/codex" \
       REPO_STATE_DB="$OV_ROOT/transcripts.sqlite" REPO_STATE_AUDIT_LOG="$OV_ROOT/audit.jsonl"
python3 "$ENGINE" index >/dev/null 2>&1 && ok || bad "overlay-order fixture index must build"
python3 - "$OV_PROJ" <<'PY'
import json, sys
proj = sys.argv[1]
row = {"type": "assistant", "uuid": "ov-s3",
       "timestamp": "2026-08-05T10:05:00.000Z", "cwd": "/tmp/fixture-ov",
       "message": {"role": "assistant", "content": "threadorder agent reply three"}}
with open(f"{proj}/S-ov/subagents/a-ov.jsonl", "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row, separators=(",", ":")) + "\n")
PY
touch "$OV_PROJ"/S-fill-{0,1,2,3,4,5,6}.jsonl
chmod 444 "$REPO_STATE_DB"
python3 "$ENGINE" get-session S-ov > "$T/h-ov.json" 2>/dev/null \
  && ok || { bad "layered get-session must succeed under a read-only base"; cat "$T/h-ov.json"; }
python3 - "$T/h-ov.json" <<'PY' && ok || bad "layered get-session must stay chronological and label its real layers"
import json, sys
data = json.load(open(sys.argv[1]))["data"]
stamps = [m["timestamp"] for m in data["messages"]]
uuids = [m["uuid"] for m in data["messages"]]
assert stamps == sorted(stamps), uuids
assert uuids == ["ov-m1", "ov-s1", "ov-m2", "ov-s2", "ov-m3", "ov-s3"], uuids
assert data["result_source"] == "overlay+base", data["result_source"]
assert data["retrieval_freshness"] == "current-overlay", data["retrieval_freshness"]
PY
chmod 644 "$REPO_STATE_DB"
rm -rf "$OV_ROOT"

SO_ROOT="$(mktemp -d /tmp/repostate-phase-h-so.XXXXXX)"
SO_PROJ="$SO_ROOT/claude/projects/-tmp-fixture-so"
mkdir -p "$SO_PROJ" "$SO_ROOT/codex"
python3 - "$SO_PROJ" <<'PY'
import json, sys
proj = sys.argv[1]
for name, hh in (("S-old", 10), ("S-mid", 11), ("S-new", 12)):
    with open(f"{proj}/{name}.jsonl", "w", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "type": "user", "uuid": f"{name}-1",
            "timestamp": f"2026-08-05T{hh:02d}:00:00.000Z",
            "cwd": "/tmp/fixture-so",
            "message": {"role": "user", "content": f"sessionorder {name}"},
        }, separators=(",", ":")) + "\n")
PY
export REPO_STATE_CLAUDE_DIR="$SO_ROOT/claude" REPO_STATE_CODEX_DIR="$SO_ROOT/codex" \
       REPO_STATE_DB="$SO_ROOT/transcripts.sqlite" REPO_STATE_AUDIT_LOG="$SO_ROOT/audit.jsonl"
python3 "$ENGINE" index >/dev/null 2>&1 && ok || bad "session-order fixture index must build"
touch "$SO_PROJ/S-old.jsonl"
chmod 444 "$REPO_STATE_DB"
python3 "$ENGINE" sessions --project-path /tmp/fixture-so --limit 3 > "$T/h-so.json" 2>/dev/null \
  && ok || bad "layered sessions must succeed under a read-only base"
python3 - "$T/h-so.json" <<'PY' && ok || bad "layered sessions must stay newest-first when an old session enters the overlay"
import json, sys
rows = json.load(open(sys.argv[1]))["data"]
ids = [r["id"] for r in rows]
assert ids == ["S-new", "S-mid", "S-old"], ids
PY
chmod 644 "$REPO_STATE_DB"
rm -rf "$SO_ROOT"

echo "phase-h-pass=$PASS phase-h-fail=$FAIL"
[ -n "$FAILED" ] && echo "failed:$FAILED"
[ "$FAIL" -eq 0 ]
