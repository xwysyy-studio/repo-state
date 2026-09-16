#!/usr/bin/env python3
"""packctl - 外发协作打包（独立工具）。

把文件/目录打成一个可外发的批次：冻结副本 → 隐私扫描（拒绝 raw transcript、
hidden thinking、密钥、symlink/越界）→ 逐文件 SHA-256 写入
MANIFEST → ZIP 并核对字节一致。批次目录默认 exchange/<date>-<topic>/。

PROMPT.txt 是用户上传 ZIP 后粘贴给 web 模型的启动语，跨任务逐字不变，默认由
本工具写出；任务定制内容一律进包内 TASK.md，不进提示词。

用法:
  python3 packctl.py <文件/目录>... --topic <主题> [--prompt 提示词文件]
                     [--out 目录] [--ack PREFIX:REASON]
"""

import argparse
import datetime
import fnmatch
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile

PACK_SCANNER_VERSION = "repo-state-pack-scanner/0.18.0"

DEFAULT_PROMPT = (
    "Please open the uploaded ZIP, read TASK.md first, invest substantial "
    "effort in your environment, iterate until the package instructions are "
    "strongly satisfied, and return the requested downloadable artifact."
)


def sh(args, cwd=None):
    return subprocess.run(
        args, capture_output=True, text=True, encoding="utf-8",
        errors="replace", cwd=cwd)


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def utc_now_iso():
    return datetime.datetime.now(datetime.UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z")


PACK_EXCLUDE_DIRS = {
    ".git", ".hg", ".svn", ".repo-state", "__pycache__", ".pytest_cache",
    ".mypy_cache", ".ruff_cache", ".cache", "exchange", "artifacts",
}
PACK_EXCLUDE_FILE_GLOBS = (
    ".env*", "*.sqlite", "*.sqlite3", "*.db", "*.db-wal",
    "*.db-shm", "*.sqlite-wal", "*.sqlite-shm", "transcripts.sqlite",
)
FORBIDDEN_TRANSCRIPT_SEQUENCES = (
    (".claude", "projects"),
    (".codex", "sessions"),
    (".repo-state", "transcripts"),
)


def path_is_within(child, parent):
    child_abs = os.path.abspath(child)
    parent_abs = os.path.abspath(parent)
    try:
        return os.path.commonpath([child_abs, parent_abs]) == parent_abs
    except ValueError:
        return False


def realpath_is_within(child, parent):
    child_abs = os.path.realpath(child)
    parent_abs = os.path.realpath(parent)
    try:
        return os.path.commonpath([child_abs, parent_abs]) == parent_abs
    except ValueError:
        return False


def path_parts(path):
    return [p for p in path.replace(os.sep, "/").split("/") if p]


def parts_contain_sequence(parts, seq):
    if len(parts) < len(seq):
        return False
    for i in range(0, len(parts) - len(seq) + 1):
        if tuple(parts[i:i + len(seq)]) == tuple(seq):
            return True
    return False


def forbidden_transcript_root_reason(path):
    apparent = path_parts(path)
    real = path_parts(os.path.realpath(path))
    for seq in FORBIDDEN_TRANSCRIPT_SEQUENCES:
        if parts_contain_sequence(apparent, seq) or parts_contain_sequence(real, seq):
            if seq == (".claude", "projects"):
                return "raw Claude transcript directory"
            if seq == (".codex", "sessions"):
                return "raw Codex transcript directory"
            return "raw transcript cache"
    return None


def display_source(src_label, base, path):
    try:
        rel = os.path.relpath(path, base)
    except ValueError:
        rel = os.path.basename(path)
    if rel == ".":
        return src_label
    # 只清尾部分隔符，保留绝对输入的前导 /：否则 /tmp/x 与相对 tmp/x 会
    # 塌成同一显示路径，一条 --ack 会同时豁免两份不同来源的未审内容
    return (src_label.rstrip("/\\") + "/" + rel.replace(os.sep, "/")).rstrip("/\\")


def pack_exclusion_reason(path, is_dir=False):
    norm = path.replace(os.sep, "/")
    name = os.path.basename(path)
    reason = forbidden_transcript_root_reason(path)
    if reason:
        return reason
    if is_dir and name in PACK_EXCLUDE_DIRS:
        return f"excluded directory `{name}`"
    if not is_dir:
        for pat in PACK_EXCLUDE_FILE_GLOBS:
            if fnmatch.fnmatch(name, pat):
                return f"excluded file pattern `{pat}`"
    return None


def copy_pack_file(src, dst, src_label, src_base, manifest):
    shown = display_source(src_label, src_base, src)
    if os.path.islink(src):
        raise RuntimeError(f"{shown}: symlink file refused")
    if not realpath_is_within(src, src_base):
        raise RuntimeError(f"{shown}: realpath escapes pack source root")
    forbidden = forbidden_transcript_root_reason(src)
    if forbidden:
        raise RuntimeError(f"{shown}: {forbidden} must not be exported")
    reason = pack_exclusion_reason(src, is_dir=False)
    if reason:
        manifest["excluded"].append({"path": shown, "reason": reason})
        return
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        fd = os.open(src, flags)
    except OSError as e:
        raise RuntimeError(f"{shown}: source open failed: {e}") from e
    try:
        before = os.fstat(fd)
        if not stat.S_ISREG(before.st_mode):
            raise RuntimeError(f"{shown}: pack source is not a regular file")
        with os.fdopen(fd, "rb", closefd=False) as source, open(dst, "xb") as target:
            shutil.copyfileobj(source, target, 1024 * 1024)
            target.flush()
        after = os.fstat(fd)
        stable = (
            before.st_dev == after.st_dev
            and before.st_ino == after.st_ino
            and before.st_size == after.st_size
            and before.st_mtime_ns == after.st_mtime_ns
        )
        if not stable:
            os.unlink(dst)
            raise RuntimeError(f"{shown}: source changed while snapshotting")
    finally:
        os.close(fd)
    manifest["included"].append({
        "source": shown,
        "_source_path": os.path.abspath(src),
        "dest": os.path.relpath(dst, manifest["payload"]).replace(os.sep, "/"),
        "bytes": os.path.getsize(dst),
    })


def copy_pack_dir(src, dst, src_label, manifest):
    if os.path.islink(src):
        raise RuntimeError(f"{src_label}: symlink directory refused")
    src_abs = os.path.abspath(src)
    src_real = os.path.realpath(src_abs)
    for dirpath, dirnames, filenames in os.walk(src_abs, followlinks=False):
        if not realpath_is_within(dirpath, src_real):
            continue
        kept = []
        for d in sorted(dirnames):
            dpath = os.path.join(dirpath, d)
            shown = display_source(src_label, src_abs, dpath)
            if os.path.islink(dpath):
                raise RuntimeError(f"{shown}: symlink directory refused")
            if not realpath_is_within(dpath, src_real):
                raise RuntimeError(f"{shown}: realpath escapes pack source root")
            forbidden = forbidden_transcript_root_reason(dpath)
            if forbidden:
                raise RuntimeError(f"{shown}: {forbidden} must not be exported")
            reason = pack_exclusion_reason(dpath, is_dir=True)
            if reason:
                manifest["excluded"].append({"path": shown, "reason": reason})
            else:
                kept.append(d)
        dirnames[:] = kept
        rel_dir = os.path.relpath(dirpath, src_abs)
        out_dir = dst if rel_dir == "." else os.path.join(dst, rel_dir)
        os.makedirs(out_dir, exist_ok=True)
        for name in sorted(filenames):
            copy_pack_file(os.path.join(dirpath, name),
                           os.path.join(out_dir, name),
                           src_label, src_abs, manifest)


def write_manifest(batch, payload, manifest):
    def public_label(value):
        for source, alias in manifest["source_labels"]:
            if value == source or value.startswith(source + "/") or value.startswith(source + ":"):
                return alias + value[len(source):]
        return value

    included = [
        {key: public_label(value) if key == "source" else value
         for key, value in item.items() if not key.startswith("_")}
        for item in manifest["included"]
    ]
    public = {
        "schema": "repo-state.pack-manifest/v1",
        "scanner": PACK_SCANNER_VERSION,
        "created_at": utc_now_iso(),
        "included": included,
        "excluded": [dict(item, path=public_label(item["path"]))
                     for item in manifest["excluded"]],
    }
    if manifest.get("privacy_acks"):
        public["privacy_acks"] = [
            dict(item, finding=public_label(item["finding"]),
                 ack_prefix=public_label(item["ack_prefix"]))
            for item in manifest["privacy_acks"]]
    for path in (os.path.join(payload, "MANIFEST.json"),
                 os.path.join(batch, "MANIFEST.json")):
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(public, fh, ensure_ascii=False, indent=2)
            fh.write("\n")


def verify_pack_snapshot(payload, zip_file, manifest):
    with zipfile.ZipFile(zip_file) as archive:
        file_names = [info.filename for info in archive.infolist() if not info.is_dir()]
        names = set(file_names)
        if len(file_names) != len(names):
            raise RuntimeError("ZIP contains duplicate file members")
        expected_names = {"MANIFEST.json"}
        for item in manifest["included"]:
            dest = item["dest"]
            expected = item["sha256"]
            expected_names.add(dest)
            payload_path = os.path.join(payload, *dest.split("/"))
            if sha256_file(payload_path) != expected:
                raise RuntimeError(f"payload changed after privacy scan: {dest}")
            if dest not in names:
                raise RuntimeError(f"ZIP is missing scanned payload file: {dest}")
            if hashlib.sha256(archive.read(dest)).hexdigest() != expected:
                raise RuntimeError(f"ZIP bytes differ from scanned payload: {dest}")
        payload_files = {
            os.path.relpath(os.path.join(dirpath, name), payload).replace(os.sep, "/")
            for dirpath, _dirnames, filenames in os.walk(payload)
            for name in filenames
        }
        if payload_files != expected_names:
            raise RuntimeError("payload file set changed after privacy scan")
        if names != expected_names:
            raise RuntimeError("ZIP file set differs from scanned payload")
        manifest_path = os.path.join(payload, "MANIFEST.json")
        with open(manifest_path, "rb") as fh:
            manifest_bytes = fh.read()
        if archive.read("MANIFEST.json") != manifest_bytes:
            raise RuntimeError("ZIP manifest differs from scanned payload manifest")


def ack_scope_matches(path, prefix):
    """Match one path or a descendant, never an adjacent lexical prefix."""
    path_norm = os.path.normpath(str(path))
    prefix_norm = os.path.normpath(str(prefix))
    if path_norm == prefix_norm:
        return True
    try:
        if os.path.isabs(path_norm) and os.path.isabs(prefix_norm):
            return os.path.commonpath([path_norm, prefix_norm]) == prefix_norm
    except ValueError:
        return False
    path_parts_norm = path_norm.replace("\\", "/")
    prefix_parts_norm = prefix_norm.replace("\\", "/").rstrip("/")
    return path_parts_norm.startswith(prefix_parts_norm + "/")


def cmd_pack(root, a):
    """外发协作打包：payload 复制 + 统一提示词快照 + ZIP，提示词打印供复制。

    批次目录是一次性快照，蒸馏完返回稿后可清。
    """
    date = datetime.date.today().isoformat()
    if a.topic in ("", ".", "..") or os.path.basename(a.topic) != a.topic:
        sys.exit("pack: --topic 必须是单个名字，不能含路径分隔符或指向上级目录")
    out_base = a.out or "exchange"
    batch_rel = f"{out_base.rstrip('/')}/{date}-{a.topic}"
    batch = os.path.join(root, batch_rel)
    if os.path.exists(batch):
        sys.exit(f"pack: {batch_rel} 已存在（同日同主题请换 --topic 后缀）")
    prompt_text = DEFAULT_PROMPT
    if a.prompt:
        prompt_abs = a.prompt if os.path.isabs(a.prompt) \
            else os.path.join(root, a.prompt)
        if not os.path.exists(prompt_abs):
            sys.exit(f"pack: 提示词文件不存在: {a.prompt}")
        with open(prompt_abs, encoding="utf-8") as fh:
            prompt_text = fh.read().strip()
    resolved = []
    for src in a.paths:
        s = src if os.path.isabs(src) else os.path.join(root, src)
        if os.path.islink(s):
            sys.exit(f"pack: {src}: symlink input refused")
        if not (os.path.isdir(s) or os.path.isfile(s)):
            sys.exit(f"pack: 找不到 {src}")
        resolved.append((src, s))
    for src, s in resolved:
        if os.path.isdir(s) and path_is_within(batch, s):
            sys.exit(
                f"pack: 输出目录 {batch_rel} 位于输入目录 {src} 内，"
                "会递归自吞；请改用已准备好的 payload 子目录，或把 --out 放到输入目录外")
    acks = []
    for spec in (getattr(a, "ack", None) or []):
        prefix, sep, reason = spec.partition(":")
        if not sep or not prefix.strip() or not (4 <= len(reason.strip()) <= 200):
            sys.exit("pack: --ack 格式为 PREFIX:REASON（理由 4-200 字符）")
        acks.append((prefix.strip(), reason.strip()))
    out_parent = os.path.dirname(batch)
    os.makedirs(out_parent, exist_ok=True)
    stage = tempfile.mkdtemp(prefix=".repo-state-pack-", dir=out_parent)
    stage_payload = os.path.join(stage, "payload")
    os.makedirs(stage_payload)
    manifest = {"payload": stage_payload, "included": [], "excluded": []}
    manifest["source_labels"] = sorted(
        {(label.rstrip("/\\"), f"input-{index}")
         for index, (src, path) in enumerate(resolved, 1)
         for label in (src, os.path.abspath(path))},
        key=lambda item: len(item[0]), reverse=True)
    acked = []
    try:
        single = a.paths[0] if len(a.paths) == 1 else None
        for src, s in resolved:
            if os.path.isdir(s):
                if single is not None:
                    # 单目录 = 已备好的包：内容平铺到 ZIP 根（TASK.md 要在根层）
                    copy_pack_dir(s, stage_payload, src, manifest)
                else:
                    copy_pack_dir(
                        s,
                        os.path.join(stage_payload, os.path.basename(os.path.normpath(s))),
                        src,
                        manifest,
                    )
            elif os.path.isfile(s):
                copy_pack_file(
                    s,
                    os.path.join(stage_payload, os.path.basename(s)),
                    src,
                    os.path.dirname(os.path.abspath(s)),
                    manifest,
                )

        # Privacy classification and the manifest digest bind to this private snapshot.
        staged = []
        for item in manifest["included"]:
            scan_path = os.path.join(stage_payload, *item["dest"].split("/"))
            item["sha256"] = sha256_file(scan_path)
            staged.append((item["source"], scan_path, item["_source_path"]))
        privacy = privacy_findings(staged)
        if privacy and acks:
            remaining = []
            for item in privacy:
                hit = next(
                    (
                        ack
                        for ack in acks
                        if item["ackable"] and ack_scope_matches(item["path"], ack[0])
                    ),
                    None,
                )
                if hit:
                    acked.append(
                        {
                            "finding": item["display"],
                            "ack_prefix": os.path.normpath(hit[0]),
                            "reason": hit[1],
                        }
                    )
                else:
                    remaining.append(item)
            privacy = remaining
        if privacy:
            print("ERROR  pack privacy guard blocked this payload:")
            for item in privacy[:50]:
                print(f"ERROR  {item['display']}")
            return 1
        for row in acked:
            print(f"WARN   pack privacy ack: {row['finding']}  [ack: {row['reason']}]")
        if acked:
            manifest["privacy_acks"] = acked

        if not os.path.isfile(os.path.join(stage_payload, "TASK.md")):
            print("ERROR  ZIP 根层缺 TASK.md：提示词让对方先读 TASK.md，"
                  "缺了这份包对方无从下手；补上任务书再打包")
            return 1
        write_manifest(stage, stage_payload, manifest)
        with open(os.path.join(stage, "PROMPT.txt"), "w", encoding="utf-8") as fh:
            fh.write(prompt_text + "\n")
        staged_zip = shutil.make_archive(
            os.path.join(stage, a.topic), "zip", root_dir=stage_payload)
        verify_pack_snapshot(stage_payload, staged_zip, manifest)
        os.replace(stage, batch)
        zip_file = os.path.join(batch, os.path.basename(staged_zip))
    except (OSError, RuntimeError, zipfile.BadZipFile) as e:
        if os.path.exists(batch):
            shutil.rmtree(batch)
        print(f"ERROR  pack snapshot failed: {e}")
        return 1
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    print(f"包已生成: {os.path.relpath(zip_file, root)}")
    print(f"批次目录: {batch_rel}/")
    print("\n----- 复制以下提示词投喂 -----\n")
    print(prompt_text)
    print("\n-----------------------------")
    print("返回稿收到后：解包进批次目录 returns/；代码工件先跑验证器再落库。")
    return 0

SECRET_RE = re.compile(
    r"(?i)(api[_-]?key|secret|token|bearer|authorization|"
    r"aws_secret_access_key|private[_-]?key|client[_-]?secret)\s*[:=]\s*"
    r"(bearer\s+)?['\"]?[A-Za-z0-9_./+=-]{16,}"
)
# 无标签也能高信度判定的凭据形态：PEM/OpenSSH 私钥块头、AWS access key id。
# SECRET_RE 只认『标签 + 分隔符 + 长值』，这两类没有前导标签会整体漏过。
UNLABELED_SECRET_RES = (
    re.compile(r"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY-----"),
    re.compile(r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"),
)


HIDDEN_THINKING_KEYS = {"thinking", "agent_reasoning"}


def is_reasoning_item(obj):
    """OpenAI 侧 reasoning item：{"type": "reasoning", "summary"/"content": [...]}。
    键名 reasoning 不单独判，普通文档里那是常用词，误拦代价高于漏拦。"""
    return (
        isinstance(obj, dict)
        and obj.get("type") == "reasoning"
        and any(obj.get(k) not in (None, "", [], {}) for k in ("summary", "content"))
    )


def has_hidden_thinking_payload(obj):
    if isinstance(obj, dict):
        if is_reasoning_item(obj):
            return True
        for key, value in obj.items():
            if key in HIDDEN_THINKING_KEYS and value not in (None, "", [], {}):
                return True
            if has_hidden_thinking_payload(value):
                return True
    elif isinstance(obj, list):
        return any(has_hidden_thinking_payload(item) for item in obj)
    return False


def looks_like_claude_transcript_record(obj):
    if not isinstance(obj, dict):
        return False
    msg = obj.get("message")
    has_main = all(k in obj for k in ("uuid", "timestamp", "type")) \
        and isinstance(msg, dict) and ("content" in msg or "role" in msg)
    if has_main:
        return True
    # Claude transcript 专有 record type：queue-operation 带 verbatim 用户
    # prompt，ai-title 是模型对会话内容生成的标题，都不带 message 但属 raw 内容
    if obj.get("type") == "ai-title" and obj.get("aiTitle"):
        return True
    if obj.get("type") == "queue-operation" and obj.get("sessionId"):
        return True
    if obj.get("sessionId"):
        strong = {"parentUuid", "toolUseResult", "isSidechain", "gitBranch", "version", "cwd"}
        if len(strong.intersection(obj)) >= 2:
            return True
    return False


def looks_like_codex_transcript_record(obj):
    if not isinstance(obj, dict):
        return False
    typ = obj.get("type")
    payload = obj.get("payload")
    if typ == "session_meta" and isinstance(payload, dict) \
            and (payload.get("id") or payload.get("cwd") or payload.get("cli_version")):
        return True
    if typ in ("event_msg", "response_item", "turn_context") and "payload" in obj:
        return True
    if isinstance(payload, dict) and payload.get("type") in (
            "user_message", "agent_message", "agent_reasoning", "function_call",
            "function_call_output", "custom_tool_call", "custom_tool_call_output"):
        return True
    return False


def looks_like_raw_transcript_record(obj):
    return looks_like_claude_transcript_record(obj) or looks_like_codex_transcript_record(obj)


def raw_text_looks_transcript_shaped(text):
    return (
        (('"sessionId"' in text or '"uuid"' in text) and '"message"' in text)
        or ('"type"' in text and '"payload"' in text
            and any(k in text for k in ('"session_meta"', '"event_msg"', '"response_item"')))
    )

def iter_json_objects(obj):
    yield obj
    if isinstance(obj, dict):
        for value in obj.values():
            yield from iter_json_objects(value)
    elif isinstance(obj, list):
        for item in obj:
            yield from iter_json_objects(item)


def privacy_finding(path, display, ackable=False):
    """path 是 --ack 前缀的比对口径，ackable finding 必须传用户在报错里看到的
    那个路径标签，否则用户照着 display 写的 ack 永远匹配不上。
    ackable 只在分类点判定：True 仅限『无法完成校验』的不确定类。
    确凿违规（真 transcript 记录、thinking 载荷、密钥、symlink/越界）
    一律 ackable=False，路径内容永远不参与该判定。"""
    return {"path": path, "display": display, "ackable": ackable}


def classify_json_object(obj, path, rel, label):
    out = []
    for item in iter_json_objects(obj):
        if looks_like_raw_transcript_record(item):
            out.append(privacy_finding(
                path, f"{label}: raw transcript-shaped JSON must not be exported"))
        if has_hidden_thinking_payload(item):
            out.append(privacy_finding(
                path, f"{label}: hidden thinking/reasoning payload present"))
    return out


def content_json_findings(path, rel, finding_path=None):
    finding_path = finding_path or path
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as e:
        return [privacy_finding(
            rel, f"{rel}: could not privacy-check file: {e}", ackable=True)]
    try:
        raw = data.decode("utf-8")
    except (UnicodeDecodeError, UnicodeError) as e:
        return [privacy_finding(
            rel, f"{rel}: could not privacy-check file: invalid UTF-8 ({e})",
            ackable=True)]
    stripped = raw.strip()
    if not stripped:
        return []
    out = []
    try:
        obj = json.loads(stripped)
    except ValueError as whole_err:
        jsonish_lines = [line for line in raw.splitlines() if line.strip()]
        if not jsonish_lines or not all(line.lstrip().startswith(("{", "["))
                                       for line in jsonish_lines):
            if raw_text_looks_transcript_shaped(raw):
                return [privacy_finding(
                    rel,
                    f"{rel}: could not privacy-check transcript-shaped JSON: {whole_err}",
                    ackable=True)]
            if os.path.splitext(path)[1].lower() in (".json", ".jsonl"):
                # 坏掉的 JSON 载荷扫不动，报出来交人判，不静默放行
                return [privacy_finding(
                    rel,
                    f"{rel}: could not privacy-check malformed JSON: {whole_err}",
                    ackable=True)]
            # 非 JSON 扩展名的混合内容（散文里嵌 JSON 行等）：仍逐行嗅探能
            # 解析出的对象里的 hidden thinking / raw transcript，藏在散文里的
            # 载荷不能静默放行；解析不出的普通文本行不生成 finding
            for lineno, line in enumerate(raw.splitlines(), 1):
                s = line.strip()
                if not s or s[0] not in "{[":
                    continue
                try:
                    prefix, _end = json.JSONDecoder().raw_decode(s)
                except ValueError:
                    continue
                out.extend(classify_json_object(
                    prefix, finding_path, rel, f"{rel}:{lineno}"))
            return out
        for lineno, line in enumerate(raw.splitlines(), 1):
            if not line.strip():
                continue
            try:
                obj = json.loads(line)
            except ValueError as e:
                prefix = None
                try:
                    prefix, _end = json.JSONDecoder().raw_decode(line.lstrip())
                except ValueError:
                    pass
                if prefix is not None:
                    out.extend(classify_json_object(
                        prefix, finding_path, rel, f"{rel}:{lineno}"))
                out.append(privacy_finding(
                    rel,
                    f"{rel}:{lineno}: could not privacy-check JSONL: {e}",
                    ackable=True))
                continue
            out.extend(classify_json_object(
                obj, finding_path, rel, f"{rel}:{lineno}"))
        return out
    out.extend(classify_json_object(obj, finding_path, rel, rel))
    return out


def file_has_secret(path):
    try:
        with open(path, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                for match in SECRET_RE.finditer(line):
                    # 值部分紧跟左括号说明是调用表达式（如
                    # token = env.change_token()），是代码标识符不是
                    # 字面量凭据；字面量密钥不会以 ( 续接
                    if line[match.end():match.end() + 1] == "(":
                        continue
                    return True
                if any(r.search(line) for r in UNLABELED_SECRET_RES):
                    return True
    except OSError:
        return None
    return False


def privacy_findings(resolved):
    findings = []
    for resolved_item in resolved:
        if len(resolved_item) == 3:
            src_label, path, logical_root = resolved_item
        else:
            src_label, path = resolved_item
            logical_root = path
        paths = []
        if os.path.islink(path):
            findings.append(privacy_finding(
                logical_root, f"{src_label}: symlink input refused"))
            continue
        root_real = os.path.realpath(path)
        root_reason = forbidden_transcript_root_reason(path)
        if root_reason:
            findings.append(privacy_finding(
                path, f"{path}: {root_reason} must not be exported"))
            continue
        if os.path.isdir(path):
            for dirpath, dirnames, filenames in os.walk(path, followlinks=False):
                if not realpath_is_within(dirpath, root_real):
                    findings.append(privacy_finding(
                        dirpath, f"{dirpath}: realpath escapes pack source root"))
                    dirnames[:] = []
                    continue
                kept = []
                for d in sorted(dirnames):
                    dpath = os.path.join(dirpath, d)
                    if os.path.islink(dpath):
                        findings.append(privacy_finding(
                            dpath, f"{dpath}: symlink directory refused"))
                        continue
                    if not realpath_is_within(dpath, root_real):
                        findings.append(privacy_finding(
                            dpath, f"{dpath}: realpath escapes pack source root"))
                        continue
                    if d in (".git", "__pycache__"):
                        continue
                    kept.append(d)
                dirnames[:] = kept
                for name in filenames:
                    p = os.path.join(dirpath, name)
                    if os.path.islink(p):
                        findings.append(privacy_finding(
                            p, f"{p}: symlink file refused"))
                        continue
                    if not realpath_is_within(p, root_real):
                        findings.append(privacy_finding(
                            p, f"{p}: realpath escapes pack source root"))
                        continue
                    paths.append(p)
        else:
            paths.append(path)
        for p in paths:
            if os.path.isdir(path):
                suffix = os.path.relpath(p, path)
                logical_path = os.path.join(logical_root, suffix)
                rel = display_source(src_label, path, p)
            else:
                logical_path = logical_root
                rel = src_label if len(resolved_item) == 3 else p
            reason = forbidden_transcript_root_reason(p)
            if reason:
                findings.append(privacy_finding(
                    logical_path, f"{rel}: {reason} must not be exported"))
                continue
            if os.path.basename(p) == "transcripts.sqlite":
                findings.append(privacy_finding(
                    logical_path, f"{rel}: raw transcript sqlite/cache must not be exported"))
                continue
            findings.extend(content_json_findings(p, rel, finding_path=logical_path))
            secret = file_has_secret(p)
            if secret is None:
                findings.append(privacy_finding(
                    rel, f"{rel}: could not privacy-check file", ackable=True))
            elif secret:
                findings.append(privacy_finding(
                    logical_path, f"{rel}: possible secret/token material present"))
    return findings


def main():
    ap = argparse.ArgumentParser(
        prog="packctl",
        description="打包外发批次：payload 冻结副本 + 隐私扫描 + MANIFEST + ZIP")
    ap.add_argument("paths", nargs="+", help="要打包的文件/目录")
    ap.add_argument("--topic", required=True, help="批次主题（进目录名与 zip 名）")
    ap.add_argument("--out", help="批次根目录（默认 exchange/）")
    ap.add_argument("--prompt", help="覆盖默认通用启动语的提示词文件；"
                                     "不给就用内置固定提示词。两种情况都写进批次 "
                                     "PROMPT.txt 并在结尾打印供复制")
    ap.add_argument("--ack", action="append", metavar="PREFIX:REASON",
                    help="豁免『could not privacy-check』类不确定 finding（理由 4-200"
                         " 字符，记入 MANIFEST）；确凿违规不可豁免")
    a = ap.parse_args()
    r = sh(["git", "rev-parse", "--show-toplevel"])
    if r.returncode == 0:
        root = r.stdout.strip()
    else:
        root = os.getcwd()
        print("pack: 当前目录不是 git 仓库，以 cwd 为打包根（该目录无 git 回滚保障）",
              file=sys.stderr)
    return cmd_pack(root, a)


if __name__ == "__main__":
    sys.exit(main())
