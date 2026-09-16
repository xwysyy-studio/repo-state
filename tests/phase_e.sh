#!/usr/bin/env bash
# Phase E verifier: locality ranking contract, original-user channel, and the
# freshness envelope. Pairwise fixtures pin the negotiated recall sort key
# (bonus_class -> tier -> substantive -> rrf band -> timestamp desc -> rrf):
#   E1 same class/tier/band            -> newer first (locality)
#   E2 old full-phrase vs new one-term -> relevance beats recency
#   E3 equal-footing user vs assistant -> original user utterance first
#   E4 identifier query                -> origin row survives newer citations
#   E5 user gem among assistant noise  -> reachable, and --speaker filters
#   E6 envelope contract + sessions fail-closed on uncovered main sources
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
      /tmp/repostate-phase-e.*) rm -rf -- "$dir" ;;
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
  T="$(mktemp -d /tmp/repostate-phase-e.XXXXXX)"
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
  mkdir -p "$R" "$HOME" "$REPO_STATE_CLAUDE_DIR/projects/proj" "$REPO_STATE_CODEX_DIR/sessions"
}

write_rows() {
  python3 - "$R" "$REPO_STATE_CLAUDE_DIR/projects/proj/$1" "$2" <<'PY'
import json, sys
repo, path, rows = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
with open(path, "w", encoding="utf-8") as fh:
    for row in rows:
        role = row.pop("role", "user")
        text = row.pop("text")
        row.setdefault("type", "assistant" if role == "assistant" else "user")
        row.setdefault("timestamp", "2026-07-09T00:00:00Z")
        row.setdefault("cwd", repo)
        row["message"] = {"role": role, "content": text}
        fh.write(json.dumps(row, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
}

rows_of() {
  python3 - "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = data.get("data") if isinstance(data, dict) else data
print(json.dumps([r.get("uuid") for r in rows or []]))
PY
}

uuid_before() {
  python3 - "$1" "$2" "$3" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = data.get("data") if isinstance(data, dict) else data
uuids = [r.get("uuid") for r in rows or []]
try:
    sys.exit(0 if uuids.index(sys.argv[2]) < uuids.index(sys.argv[3]) else 1)
except ValueError:
    sys.exit(1)
PY
}

uuid_present() {
  python3 - "$1" "$2" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
rows = data.get("data") if isinstance(data, dict) else data
sys.exit(0 if any(r.get("uuid") == sys.argv[2] for r in rows or []) else 1)
PY
}

PAD="补足实质度长度的占位说明文字，保持四十字符以上，不改变查询词命中结构。"

# ---------- E1 locality: same class/tier/band -> newer first ----------
new_transcript_env
write_rows "E1-old.jsonl" "[{\"uuid\":\"e1-old\",\"role\":\"assistant\",\"timestamp\":\"2026-05-01T00:00:00Z\",\"text\":\"深红警报 触发条件 复盘记录 甲 $PAD\"}]"
write_rows "E1-new.jsonl" "[{\"uuid\":\"e1-new\",\"role\":\"assistant\",\"timestamp\":\"2026-07-25T00:00:00Z\",\"text\":\"深红警报 触发条件 复盘记录 乙 $PAD\"}]"
python3 "$ENGINE_SRC" index >/dev/null 2>&1
python3 "$ENGINE_SRC" search 深红警报 触发条件 --project-path "$R" --limit 5 --no-index > "$T/e1.json" 2>/dev/null
uuid_before "$T/e1.json" e1-new e1-old \
  && ok || { bad "E1 same-band pair must rank newer first (locality)"; cat "$T/e1.json"; }

# ---------- E2 relevance beats recency across tiers ----------
new_transcript_env
write_rows "E2-old.jsonl" "[{\"uuid\":\"e2-old\",\"role\":\"assistant\",\"timestamp\":\"2026-05-01T00:00:00Z\",\"text\":\"蓝色风暴 演练手册 完整流程 $PAD\"}]"
write_rows "E2-new.jsonl" "[{\"uuid\":\"e2-new\",\"role\":\"assistant\",\"timestamp\":\"2026-07-25T00:00:00Z\",\"text\":\"蓝色风暴 值班室闲谈 $PAD\"}]"
python3 "$ENGINE_SRC" index >/dev/null 2>&1
python3 "$ENGINE_SRC" search 蓝色风暴 演练手册 --project-path "$R" --limit 5 --no-index > "$T/e2.json" 2>/dev/null
uuid_before "$T/e2.json" e2-old e2-new \
  && ok || { bad "E2 old full-phrase must outrank new single-term hit"; cat "$T/e2.json"; }

# ---------- E3 equal footing: original user utterance first ----------
new_transcript_env
write_rows "E3-a.jsonl" "[{\"uuid\":\"e3-a\",\"role\":\"assistant\",\"timestamp\":\"2026-07-10T05:00:00Z\",\"text\":\"紫色基线 采样窗口 说明 存档 $PAD\"}]"
write_rows "E3-u.jsonl" "[{\"uuid\":\"e3-u\",\"role\":\"user\",\"timestamp\":\"2026-07-10T05:00:00Z\",\"text\":\"紫色基线 采样窗口 说明 拍板 $PAD\"}]"
python3 "$ENGINE_SRC" index >/dev/null 2>&1
python3 "$ENGINE_SRC" search 紫色基线 采样窗口 --project-path "$R" --limit 5 --no-index > "$T/e3.json" 2>/dev/null
uuid_before "$T/e3.json" e3-u e3-a \
  && ok || { bad "E3 equal-footing pair must rank original user first"; cat "$T/e3.json"; }

# ---------- E4 identifier archaeology: origin survives citations ----------
new_transcript_env
write_rows "E4-origin.jsonl" "[{\"uuid\":\"e4-origin\",\"role\":\"user\",\"timestamp\":\"2026-04-01T00:00:00Z\",\"text\":\"决议 D-2026-04-01-09 原始决议全文 $PAD\"}]"
for i in 1 2 3; do
  write_rows "E4-cite$i.jsonl" "[{\"uuid\":\"e4-cite$i\",\"role\":\"assistant\",\"timestamp\":\"2026-07-2${i}T00:00:00Z\",\"text\":\"引用 D-2026-04-01-09 的后续讨论第${i}轮 $PAD\"}]"
done
python3 "$ENGINE_SRC" index >/dev/null 2>&1
python3 "$ENGINE_SRC" search D-2026-04-01-09 --project-path "$R" --limit 10 --no-index > "$T/e4.json" 2>/dev/null
uuid_present "$T/e4.json" e4-origin \
  && ok || { bad "E4 identifier query must keep the oldest origin row"; cat "$T/e4.json"; }
uuid_before "$T/e4.json" e4-origin e4-cite3 \
  && ok || { bad "E4 origin (user, substantive) must not sink below newest citation"; cat "$T/e4.json"; }

# ---------- E5 user gem among assistant noise + --speaker ----------
new_transcript_env
python3 - "$R" "$REPO_STATE_CLAUDE_DIR/projects/proj/E5-noise.jsonl" <<'PY'
import json, sys
repo, path = sys.argv[1], sys.argv[2]
pad = "冗长的迭代过程记录，包含大量重复展开的推理与实现细节描述，用于稀释检索面。"
with open(path, "w", encoding="utf-8") as fh:
    for i in range(120):
        fh.write(json.dumps({
            "type": "assistant", "uuid": f"e5-noise-{i:03d}",
            "timestamp": f"2026-07-{10 + i % 15:02d}T00:{i % 60:02d}:00Z",
            "cwd": repo,
            "message": {"role": "assistant",
                        "content": f"橙色协议 迭代讨论第{i}轮 {pad}"},
        }, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
write_rows "E5-user.jsonl" "[{\"uuid\":\"e5-gem\",\"role\":\"user\",\"entrypoint\":\"cli\",\"userType\":\"external\",\"timestamp\":\"2026-07-05T00:00:00Z\",\"text\":\"橙色协议 最终拍板 定稿 $PAD\"}]"
python3 "$ENGINE_SRC" index >/dev/null 2>&1
python3 "$ENGINE_SRC" search 橙色协议 --project-path "$R" --limit 5 --no-index > "$T/e5.json" 2>/dev/null
uuid_present "$T/e5.json" e5-gem \
  && ok || { bad "E5 user gem must reach top-5 through assistant noise"; cat "$T/e5.json"; }
python3 "$ENGINE_SRC" search 橙色协议 --project-path "$R" --limit 10 --speaker original-user --no-index > "$T/e5s.json" 2>/dev/null
uuid_present "$T/e5s.json" e5-gem && ! uuid_present "$T/e5s.json" e5-noise-001 \
  && ok || { bad "E5 --speaker original-user must return only real user text"; cat "$T/e5s.json"; }

# ---------- E6 envelope contract + sessions fail-closed ----------
new_transcript_env
for i in 0 1 2 3 4 5 6 7 8 9; do
  write_rows "E6-s$i.jsonl" "[{\"uuid\":\"e6-$i\",\"role\":\"user\",\"timestamp\":\"2026-07-0${i:0:1}T01:00:00Z\",\"text\":\"第${i}号会话的启动消息 $PAD\"}]"
done
python3 "$ENGINE_SRC" index >/dev/null 2>&1
python3 "$ENGINE_SRC" search 启动消息 --project-path "$R" --no-index > "$T/e6.json" 2>/dev/null
python3 - "$T/e6.json" <<'PY' && ok || bad "E6 search output must carry v2 envelope with index_freshness"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("schema_version") == 2, "schema_version missing"
assert "index_freshness" in data, "index_freshness missing"
assert isinstance(data.get("data"), list), "data missing"
PY
# touch every main source, then make the DB read-only: 10 changed mains vs the
# 8-source overlay cap must fail sessions closed with partial_data attached
for i in 0 1 2 3 4 5 6 7 8 9; do
  printf '%s\n' "{\"type\":\"user\",\"uuid\":\"e6-extra-$i\",\"timestamp\":\"2026-07-28T0$i:00:00Z\",\"cwd\":\"$R\",\"message\":{\"role\":\"user\",\"content\":\"追加消息$i\"}}" >> "$REPO_STATE_CLAUDE_DIR/projects/proj/E6-s$i.jsonl"
done
chmod 444 "$REPO_STATE_DB"
if python3 "$ENGINE_SRC" sessions --project-path "$R" > "$T/e6b.json" 2>"$T/e6b.err"; then
  bad "E6 sessions with uncovered changed mains must exit non-zero"
else ok; fi
python3 - "$T/e6b.json" <<'PY' && ok || { bad "E6 fail-closed payload must carry error + partial_data + uncovered count"; }
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert "coverage incomplete" in (data.get("error") or ""), "error text"
assert data.get("data") is None, "data must be null when failing closed"
assert isinstance(data.get("partial_data"), list), "partial_data missing"
f = data.get("index_freshness") or {}
assert (f.get("uncovered_main_sources") or 0) > 0, "uncovered mains not counted"
assert f.get("complete") is False, "complete must be false"
PY
python3 "$ENGINE_SRC" sessions --project-path "$R" --no-index > "$T/e6c.json" 2>/dev/null \
  && ok || bad "E6 --no-index must stay an explicit stale-read escape hatch"
# programmable surface must honor the same gate: safe JSON DSL op=sessions
printf '{"op":"sessions","project_path":"%s"}\n' "$R" > "$T/e6q.json.spec"
if python3 "$ENGINE_SRC" query "$T/e6q.json.spec" > "$T/e6q.json" 2>/dev/null; then
  bad "E6 query op=sessions must fail closed like the CLI"
else ok; fi
python3 - "$T/e6q.json" <<'PY' && ok || bad "E6 query op=sessions payload must carry envelope error + partial_data"
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data.get("schema_version") == 2
assert "coverage incomplete" in (data.get("error") or "")
assert isinstance(data.get("partial_data"), list)
PY
chmod 644 "$REPO_STATE_DB"

# ---------- E7 get-session pagination: distinct instances and complete traversal ----------
new_transcript_env
python3 - "$R" "$REPO_STATE_CLAUDE_DIR/projects/proj/E7-walk.jsonl" <<'PY'
import json, sys
repo, path = sys.argv[1], sys.argv[2]
texts = ["甲类结论", "乙类结论", "丙类结论", "甲类结论", "丁类结论", "甲类结论"]
with open(path, "w", encoding="utf-8") as fh:
    for i, text in enumerate(texts):
        fh.write(json.dumps({
            "type": "user", "uuid": f"e7-{i}",
            "timestamp": f"2026-07-10T00:0{i}:00Z", "cwd": repo,
            "message": {"role": "user", "content": text},
        }, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
python3 "$ENGINE_SRC" index >/dev/null 2>&1
python3 "$ENGINE_SRC" get-session E7-walk --limit 2 --no-index > "$T/e7a.json" 2>/dev/null
python3 "$ENGINE_SRC" get-session E7-walk --offset 2 --limit 2 --no-index > "$T/e7b.json" 2>/dev/null
python3 "$ENGINE_SRC" get-session E7-walk --offset 4 --limit 2 --no-index > "$T/e7c.json" 2>/dev/null
python3 - "$T/e7a.json" "$T/e7b.json" "$T/e7c.json" <<'PY' && ok || bad "E7 pagination must preserve distinct repeated statements"
import json, sys
a = json.load(open(sys.argv[1]))["data"]
b = json.load(open(sys.argv[2]))["data"]
c = json.load(open(sys.argv[3]))["data"]
assert a["total_visible_messages"] == 6, a["total_visible_messages"]
assert [m["uuid"] for m in a["messages"]] == ["e7-0", "e7-1"]
assert a["messages"][0]["uuid"] != b["messages"][1]["uuid"]
assert a["next_offset"] == 2
assert [m["uuid"] for m in b["messages"]] == ["e7-2", "e7-3"]
assert b["next_offset"] == 4
assert [m["uuid"] for m in c["messages"]] == ["e7-4", "e7-5"]
assert c["next_offset"] is None, "exhausted session must end pagination"
PY
python3 - "$R" "$REPO_STATE_CLAUDE_DIR/projects/proj/E7-big.jsonl" <<'PY'
import json, sys
repo, path = sys.argv[1], sys.argv[2]
with open(path, "w", encoding="utf-8") as fh:
    for i in range(2200):
        fh.write(json.dumps({
            "type": "user", "uuid": f"e7big-{i:04d}",
            "timestamp": f"2026-07-11T{i // 3600:02d}:{(i // 60) % 60:02d}:{i % 60:02d}Z",
            "cwd": repo,
            "message": {"role": "user", "content": f"独立消息第{i:04d}号"},
        }, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
python3 "$ENGINE_SRC" index >/dev/null 2>&1
python3 "$ENGINE_SRC" get-session E7-big --limit 5 --no-index > "$T/e7c.json" 2>/dev/null
python3 "$ENGINE_SRC" get-session E7-big --offset 2195 --limit 10 --no-index > "$T/e7d.json" 2>/dev/null
python3 - "$T/e7c.json" "$T/e7d.json" <<'PY' && ok || bad "E7 totals must not be faked by a 2000-row prefix"
import json, sys
first = json.load(open(sys.argv[1]))["data"]
last = json.load(open(sys.argv[2]))["data"]
assert first["total_visible_messages"] == 2200, first["total_visible_messages"]
assert last["total_visible_messages"] == 2200, last["total_visible_messages"]
assert last["returned"] == 5 and last["next_offset"] is None
PY

# ---------- E8 refreshed-mode gate: broken NEW main fails closed, broken OLD does not ----------
new_transcript_env
write_rows "E8-old.jsonl" "[{\"uuid\":\"e8-old\",\"role\":\"user\",\"timestamp\":\"2026-06-01T00:00:00Z\",\"text\":\"六月的旧会话 $PAD\"}]"
write_rows "E8-new.jsonl" "[{\"uuid\":\"e8-new\",\"role\":\"user\",\"timestamp\":\"2026-07-28T00:00:00Z\",\"text\":\"七月末的新会话 $PAD\"}]"
python3 "$ENGINE_SRC" index >/dev/null 2>&1
NEWF="$REPO_STATE_CLAUDE_DIR/projects/proj/E8-new.jsonl"
printf '%s\n' "{\"type\":\"user\",\"uuid\":\"e8-new-2\",\"timestamp\":\"2026-07-28T01:00:00Z\",\"cwd\":\"$R\",\"message\":{\"role\":\"user\",\"content\":\"追加\"}}" >> "$NEWF"
chmod 000 "$NEWF"
if python3 "$ENGINE_SRC" sessions --project-path "$R" > "$T/e8a.json" 2>/dev/null; then
  bad "E8 refreshed run with a broken NEWEST main must fail closed"
else ok; fi
chmod 644 "$NEWF"
python3 "$ENGINE_SRC" sessions --project-path "$R" > "$T/e8b.json" 2>/dev/null \
  && ok || bad "E8 sessions must recover once the broken main is readable again"
OLDF="$REPO_STATE_CLAUDE_DIR/projects/proj/E8-old.jsonl"
printf '%s\n' "{\"type\":\"user\",\"uuid\":\"e8-old-2\",\"timestamp\":\"2026-06-01T01:00:00Z\",\"cwd\":\"$R\",\"message\":{\"role\":\"user\",\"content\":\"旧追加\"}}" >> "$OLDF"
chmod 000 "$OLDF"
python3 - "$OLDF" <<'PY'
import os, sys, datetime
old = datetime.datetime(2026, 6, 1).timestamp()
os.utime(sys.argv[1], (old, old))
PY
python3 "$ENGINE_SRC" sessions --project-path "$R" > "$T/e8c.json" 2>/dev/null \
  && ok || bad "E8 an OLD broken main must not brick the latest-session route"
python3 - "$T/e8c.json" <<'PY' && ok || bad "E8 old-broken-main run must still report incomplete coverage"
import json, sys
data = json.load(open(sys.argv[1]))
f = data["index_freshness"]
assert f["complete"] is False and (f["uncovered_main_sources"] or 0) > 0
assert any(r["id"] == "E8-new" for r in data["data"])
PY
chmod 644 "$OLDF"

# ---------- E9 subagent-only change: companions must not pollute coverage ----------
new_transcript_env
write_rows "E9-main.jsonl" "[{\"uuid\":\"e9-main\",\"role\":\"user\",\"timestamp\":\"2026-07-20T00:00:00Z\",\"text\":\"主会话启动 $PAD\"}]"
mkdir -p "$REPO_STATE_CLAUDE_DIR/projects/proj/E9-main/subagents"
python3 - "$R" "$REPO_STATE_CLAUDE_DIR/projects/proj/E9-main/subagents/a1.jsonl" <<'PY'
import json, sys
repo, path = sys.argv[1], sys.argv[2]
with open(path, "w", encoding="utf-8") as fh:
    fh.write(json.dumps({
        "type": "assistant", "uuid": "e9-sub-1",
        "timestamp": "2026-07-20T00:01:00Z", "cwd": repo,
        "message": {"role": "assistant", "content": "subagent 初始输出"},
    }, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
python3 "$ENGINE_SRC" index >/dev/null 2>&1
printf '%s\n' "{\"type\":\"assistant\",\"uuid\":\"e9-sub-2\",\"timestamp\":\"2026-07-20T00:02:00Z\",\"cwd\":\"$R\",\"message\":{\"role\":\"assistant\",\"content\":\"subagent 追加输出\"}}" >> "$REPO_STATE_CLAUDE_DIR/projects/proj/E9-main/subagents/a1.jsonl"
chmod 444 "$REPO_STATE_DB"
python3 "$ENGINE_SRC" search 主会话启动 --project-path "$R" --no-index > /dev/null 2>&1
python3 "$ENGINE_SRC" sessions --project-path "$R" > "$T/e9.json" 2>/dev/null \
  && ok || bad "E9 subagent-only change under lock must not fail sessions closed"
python3 - "$T/e9.json" <<'PY' && ok || bad "E9 coverage counts must describe the real change set only"
import json, sys
f = json.load(open(sys.argv[1]))["index_freshness"]
assert f["mode"] == "overlay+base", f["mode"]
assert f["changed_sources"] == 1, f
assert f["covered_changed_sources"] == 1 and f["uncovered_changed_sources"] == 0
assert f["complete"] is True
PY
chmod 644 "$REPO_STATE_DB"

# ---------- E10 archaeology at scale: origin survives 60 newer citations ----------
new_transcript_env
write_rows "E10-origin.jsonl" "[{\"uuid\":\"e10-origin\",\"role\":\"user\",\"timestamp\":\"2026-03-01T00:00:00Z\",\"text\":\"决议 D-2026-03-01-77 原始决议全文 $PAD\"}]"
python3 - "$R" "$REPO_STATE_CLAUDE_DIR/projects/proj" <<'PY'
import json, sys, os
repo, proj = sys.argv[1], sys.argv[2]
pad = "冗长的引用讨论记录，包含大量重复展开的推理与实现细节描述，用于挤压候选窗口。"
for s in range(30):
    with open(os.path.join(proj, f"E10-cite{s:02d}.jsonl"), "w", encoding="utf-8") as fh:
        for j in range(2):
            fh.write(json.dumps({
                "type": "assistant", "uuid": f"e10-c{s:02d}-{j}",
                "timestamp": f"2026-07-{(s % 27) + 1:02d}T0{j}:00:00Z", "cwd": repo,
                "message": {"role": "assistant",
                            "content": f"引用 D-2026-03-01-77 的第{s}轮讨论{j} {pad}"},
            }, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
python3 "$ENGINE_SRC" index >/dev/null 2>&1
python3 "$ENGINE_SRC" search D-2026-03-01-77 --project-path "$R" --limit 5 --no-index > "$T/e10.json" 2>/dev/null
uuid_present "$T/e10.json" e10-origin \
  && ok || { bad "E10 identifier origin must survive 60 newer citations"; cat "$T/e10.json"; }

echo "phase-e-pass=$PASS phase-e-fail=$FAIL"
if [ "$FAIL" -gt 0 ]; then
  echo "failed:$FAILED"
  exit 1
fi
exit 0
