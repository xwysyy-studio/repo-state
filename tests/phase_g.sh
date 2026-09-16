#!/usr/bin/env bash
# Phase G packctl privacy-scan contract verifier.
# Contract (SKILL.md): raw transcript records, hidden thinking/reasoning
# payloads, and secrets are hard-rejected before an outbound ZIP; default
# excludes cover .env*; one --ack must not span two distinct inputs.
# All fixtures below use SYNTHETIC fake values, never real credentials.
# Usage: bash tests/phase_g.sh   # exit 0 iff ALL PASS
# PHASE_G_ENGINE=<path> overrides the packctl under test (red-run vs old rev).
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENGINE="${PHASE_G_ENGINE:-$ROOT/scripts/packctl.py}"

RESULT="$(ENGINE="$ENGINE" python3 - <<'PYEOF'
import os, runpy, tempfile
m = runpy.run_path(os.environ["ENGINE"])
fhs = m["file_has_secret"]
cjf = m["content_json_findings"]
cjo = m["classify_json_object"]
ds = m["display_source"]
pex = m["pack_exclusion_reason"]

passed = 0
failed = []
def check(name, cond):
    global passed
    if cond:
        passed += 1
    else:
        failed.append(name)

def sfile(suffix, content):
    fd, p = tempfile.mkstemp(suffix=suffix)
    with os.fdopen(fd, "w") as fh:
        fh.write(content)
    return p

# F1 secrets (synthetic fakes)
pem = sfile(".pem", "-----BEGIN RSA PRIVATE KEY-----\nMIIfake0000000000\n-----END RSA PRIVATE KEY-----\n")
aws = sfile(".env2", "AWS_SECRET_ACCESS_KEY=wJalrFAKEexampleKEY00000000000000000AAA\n")
akia = sfile(".txt", "id = AKIAFAKE1234567890XY\n")
openai = sfile(".txt", "api_key = 'sk-FAKEfakefakefakefakefake0000'\n")
callexpr = sfile(".py", "token = env.change_token()\n")
check("F1-pem", fhs(pem) is True)
check("F1-aws-label", fhs(aws) is True)
check("F1-akia", fhs(akia) is True)
check("F1-openai-control", fhs(openai) is True)
check("F1-callexpr-not-flagged", fhs(callexpr) is False)
for p in (pem, aws, akia, openai, callexpr):
    os.unlink(p)

# F2 raw transcript records
check("F2-queue-op", bool(cjo({"type": "queue-operation", "operation": "enqueue",
                               "sessionId": "s", "content": "verbatim prompt"}, "x", "x", "x")))
check("F2-ai-title", bool(cjo({"type": "ai-title", "sessionId": "s", "aiTitle": "t"}, "x", "x", "x")))
check("F2-main-msg-still", bool(cjo({"uuid": "u", "timestamp": "t", "type": "user",
                                     "sessionId": "s", "message": {"role": "user", "content": "hi"}},
                                    "x", "x", "x")))

# F3 hidden thinking hidden in a non-json file vs pure prose
mixed = sfile(".txt", 'diary notes\n{"thinking":"secret private reasoning"}\nmore notes\n')
mixed_reason = sfile(".md", 'log\n{"type":"reasoning","summary":["chain"]}\n')
prose = sfile(".md", "# heading\njust prose, no json here\nanother line\n")
check("F3-mixed-thinking-caught", bool(cjf(mixed, "mixed.txt")))
check("F3-mixed-reasoning-caught", bool(cjf(mixed_reason, "m.md")))
check("F3-pure-prose-noise-free", cjf(prose, "p.md") == [])
for p in (mixed, mixed_reason, prose):
    os.unlink(p)

# F4 ack path collision between absolute and relative inputs
abs_d = ds("/tmp/x", "/tmp/x", "/tmp/x/a/b")
rel_d = ds("tmp/x", "tmp/x", "tmp/x/a/b")
check("F4-no-collision", abs_d != rel_d)
check("F4-abs-keeps-leading-slash", abs_d.startswith("/"))

# F6 .env* default exclusion
check("F6-envrc", pex(".envrc") is not None)
check("F6-env", pex(".env") is not None)
check("F6-env-local", pex(".env.local") is not None)
check("F6-plain-file-kept", pex("notes.txt") is None)

print(f"pass={passed}")
print("fail=" + ",".join(failed) if failed else "fail=")
PYEOF
)"

echo "$RESULT"
FAILS="$(printf '%s\n' "$RESULT" | sed -n 's/^fail=//p')"
if [ -n "$FAILS" ]; then
  echo "phase-g FAILED: $FAILS"
  exit 1
fi
echo "phase-g-pass ok"
