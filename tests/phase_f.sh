#!/usr/bin/env bash
# Phase F abandoned-input marking contract verifier.
# Contract under test: rewind-abandoned user inputs (fork shape: same non-null
# parent, only the last user plain-text child survives) are marked at index
# time as structural inference; default read surfaces exclude them;
# --include-abandoned restores them WITH a label; identical-text live and
# abandoned instances are never collapsed into one representative row;
# explicit context/raw/proof reads label them; sidechain and
# null-parent (compaction-restart) shapes are never marked.
# Usage: bash tests/phase_f.sh   # exit 0 iff ALL PASS
# PHASE_F_ENGINE=<path> overrides the engine under test (red-run vs old rev).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${PHASE_F_ENGINE:-$ROOT/scripts/transcriptctl.py}"
PASS=0
FAIL=0
FAILED=""

ok() { PASS=$((PASS + 1)); }
bad() {
  FAIL=$((FAIL + 1))
  FAILED="$FAILED"$'\n'"  - $1"
  echo "FAIL: $1"
}

T="$(mktemp -d /tmp/repostate-phase-f.XXXXXX)"
trap 'rm -rf "$T"' EXIT
export REPO_STATE_CLAUDE_DIR="$T/claude"
export REPO_STATE_CODEX_DIR="$T/codex"
export REPO_STATE_DB="$T/transcripts.sqlite"
export REPO_STATE_AUDIT_LOG="$T/audit.jsonl"
export REPO_STATE_DISABLE_JIEBA=1
mkdir -p "$T/claude/projects/-tmp-fixture-proj" "$T/codex"

SID="f0000000-aaaa-bbbb-cccc-000000000001"
python3 - "$T/claude/projects/-tmp-fixture-proj/$SID.jsonl" <<'PYEOF'
import json
import sys

def rec(uuid, parent, role, text, ts, sidechain=False):
    return {
        "type": role, "uuid": uuid, "parentUuid": parent,
        "timestamp": f"2026-08-05T10:{ts:02d}:00.000Z",
        "cwd": "/tmp/fixture-proj", "isSidechain": sidechain,
        "message": {"role": role, "content": text},
    }

rows = [
    rec("u1", None, "user", "alpha start request", 1),
    rec("a1", "u1", "assistant", "ack one", 2),
    # fork 1: abandoned draft (unique keyword) vs corrected live sibling
    rec("u-ab-diff", "a1", "user", "beta draftinput abandonedonly", 3),
    rec("u-live-diff", "a1", "user", "beta corrected final", 4),
    rec("a2", "u-live-diff", "assistant", "ack two", 5),
    # fork 2: abandoned and live siblings with IDENTICAL text
    rec("u-ab-same", "a2", "user", "gamma identical text", 6),
    rec("u-live-same", "a2", "user", "gamma identical text", 7),
    rec("a3", "u-live-same", "assistant", "ack three", 8),
    # sidechain fan-out under one parent: must never be marked
    rec("sc-a", "a1", "user", "sidechain prompt one", 9, sidechain=True),
    rec("sc-b", "a1", "user", "sidechain prompt two", 10, sidechain=True),
    # compaction-restart shape: second null-parent root, must never be marked
    rec("r2", None, "user", "compact restart segment", 11),
]
with open(sys.argv[1], "w", encoding="utf-8") as fh:
    for r in rows:
        fh.write(json.dumps(r, ensure_ascii=False) + "\n")
PYEOF

python3 "$ENGINE" index >/dev/null 2>&1 || bad "index build failed"

# --- marking set: exactly the two fork losers ---
MARKED="$(python3 - <<PYEOF
import sqlite3, os
conn = sqlite3.connect(os.environ["REPO_STATE_DB"])
rows = conn.execute(
    "SELECT uuid FROM messages WHERE COALESCE(is_abandoned,0)=1 ORDER BY uuid"
).fetchall()
print(",".join(r[0] for r in rows))
PYEOF
)"
[ "$MARKED" = "u-ab-diff,u-ab-same" ] \
  && ok || bad "marked set is [$MARKED], want [u-ab-diff,u-ab-same]"

run() { python3 "$ENGINE" "$@" 2>/dev/null; }

# --- search: default excludes, opt-in restores with label ---
N_DEFAULT="$(run search abandonedonly --all-projects --no-index \
  | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["data"]))')"
[ "$N_DEFAULT" = "0" ] && ok || bad "search default returned $N_DEFAULT rows, want 0"

LABELED="$(run search abandonedonly --all-projects --no-index --include-abandoned \
  | python3 -c 'import json,sys
rows=json.load(sys.stdin)["data"]
print(len(rows) >= 1 and all(r.get("is_abandoned") is True for r in rows))')"
[ "$LABELED" = "True" ] && ok || bad "search --include-abandoned did not restore labeled row"

# --- get-session: default excludes; opt-in keeps live and abandoned separate ---
GS_DEFAULT="$(run get-session "$SID" --no-index --limit 100 \
  | python3 -c 'import json,sys
ms=json.load(sys.stdin)["data"]["messages"]
draft=[m for m in ms if "draftinput" in (m.get("text") or "")]
gamma=[m for m in ms if (m.get("text") or "").strip()=="gamma identical text"]
print(len(draft)==0 and len(gamma)==1 and not gamma[0].get("is_abandoned"))')"
[ "$GS_DEFAULT" = "True" ] && ok || bad "get-session default surface wrong"

GS_INC="$(run get-session "$SID" --no-index --limit 100 --include-abandoned \
  | python3 -c 'import json,sys
ms=json.load(sys.stdin)["data"]["messages"]
draft=[m for m in ms if "draftinput" in (m.get("text") or "")]
gamma=[m for m in ms if (m.get("text") or "").strip()=="gamma identical text"]
flags=sorted(bool(m.get("is_abandoned")) for m in gamma)
print(len(draft)==1 and bool(draft[0].get("is_abandoned"))
      and len(gamma)==2 and flags==[False, True])')"
[ "$GS_INC" = "True" ] && ok || bad "get-session opt-in must show live+abandoned separately, labeled"

# --- sessions: real_user_msgs default vs opt-in ---
CNT_DEFAULT="$(run sessions --all-projects --no-index \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["real_user_msgs"])')"
CNT_INC="$(run sessions --all-projects --no-index --include-abandoned \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["real_user_msgs"])')"
[ "$CNT_DEFAULT" = "4" ] && ok || bad "sessions real_user_msgs default=$CNT_DEFAULT, want 4"
[ "$CNT_INC" = "6" ] && ok || bad "sessions real_user_msgs opt-in=$CNT_INC, want 6"

# --- session-report: opt-in accepted, counts follow ---
# user_messages 与 sessions.real_user_msgs 同口径（唯一「真实用户原话」
# 谓词：主链用户纯文本，排 sidechain/tool_result/注入）
SR_DEFAULT="$(run session-report --session "$SID" --all-projects --no-index \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["user_messages"])')"
SR_INC="$(run session-report --session "$SID" --all-projects --no-index --include-abandoned \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["user_messages"])')"
[ "$SR_DEFAULT" = "4" ] && ok || bad "session-report user_messages default=$SR_DEFAULT, want 4"
[ "$SR_INC" = "6" ] && ok || bad "session-report user_messages opt-in=$SR_INC, want 6"

# --- context excludes abandoned neighbors by default; explicit reads retain labels ---
CTX="$(python3 - "$ENGINE" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("tctl", sys.argv[1])
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)
api = t.make_api(t.open_ro())
ctx = api["context"]("u-live-same", before=10, after=10)
assert not any(m.get("is_abandoned") for m in ctx["before"] + ctx["after"])
ctx = api["context"]("u-live-same", before=10, after=10, include_abandoned=True)
nb = {n["uuid"]: bool(n.get("is_abandoned")) for n in ctx["before"] + ctx["after"]}
raw = api["raw"]("u-ab-diff")
ctx_ab = api["context"]("u-ab-diff")
print(nb.get("u-ab-same") is True
      and bool(raw and raw.get("is_abandoned"))
      and ctx_ab["message"].get("is_abandoned") is True)

PYEOF
)"
[ "$CTX" = "True" ] && ok || bad "context/raw label missing on abandoned rows"

PROOF="$(run proof --message u-ab-diff --no-index \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"].get("is_abandoned") is True)' \
  || echo False)"
[ "$PROOF" = "True" ] && ok || bad "proof on abandoned uuid did not carry is_abandoned"

echo "phase-f-pass=$PASS phase-f-fail=$FAIL"
[ -n "$FAILED" ] && echo "failed:$FAILED"
[ "$FAIL" -eq 0 ]
