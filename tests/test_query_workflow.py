#!/usr/bin/env python3
"""Consumer regressions for transcript querying, paging and failure investigation."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ENGINE = Path(os.environ.get("REPO_STATE_TEST_ENGINE", Path(__file__).parents[1] / "scripts/transcriptctl.py"))


class QueryWorkflow(unittest.TestCase):
    @unittest.skipUnless(sys.platform == 'darwin', 'native macOS process identity')
    def test_macos_claude_registry_requires_exact_start_token(self):
        # Claude Code records `LC_ALL=C TZ=UTC ps -o lstart= -p PID` on macOS.
        launcher = '''
import json, os, pathlib, subprocess, sys
engine, root, mode = sys.argv[1:]
token = subprocess.check_output(['ps', '-o', 'lstart=', '-p', str(os.getpid())],
    text=True, env=dict(os.environ, LC_ALL='C', TZ='UTC')).strip()
registry = pathlib.Path(root) / 'sessions'
registry.mkdir(exist_ok=True)
(registry / f'{os.getpid()}.json').write_text(json.dumps(dict(
    pid=os.getpid(), sessionId='workflow', procStart=token if mode == 'valid' else 'stale')))
os.execv(sys.executable, [sys.executable, engine, 'search', 'configuration',
    '--current-session', '--all-projects'])
'''
        env = dict(self.env, TZ='Pacific/Honolulu')
        env.pop('CLAUDE_CODE_SESSION_ID', None)
        for mode in ('valid', 'stale'):
            with self.subTest(mode=mode):
                proc = subprocess.run([sys.executable, '-c', launcher, str(ENGINE),
                                       str(self.root/'claude'), mode], env=env,
                                      capture_output=True, text=True)
                result = json.loads(proc.stdout)
                if mode == 'valid':
                    self.assertEqual(proc.returncode, 0, result)
                    self.assertEqual(result['invocation'], dict(session_id='workflow', resolved=True))
                    self.assertTrue(result['data'])
                    self.assertTrue(all(row['session_id'] == 'workflow' for row in result['data']))
                else:
                    self.assertNotEqual(proc.returncode, 0)
                    self.assertFalse(result['invocation']['resolved'])

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="repo-state-workflow-")
        cls.root = Path(cls.tmp.name)
        cls.project = str(cls.root / "project")
        cls.env = dict(os.environ, REPO_STATE_CLAUDE_DIR=str(cls.root / "claude"),
                       REPO_STATE_CODEX_DIR=str(cls.root / "codex"),
                       REPO_STATE_DB=str(cls.root / "index.sqlite"),
                       REPO_STATE_AUDIT_LOG=str(cls.root / "audit.jsonl"),
                       REPO_STATE_DISABLE_JIEBA="1")
        cls.env.pop("CODEX_THREAD_ID", None)
        folder = cls.root / "claude/projects/workflow"
        folder.mkdir(parents=True)
        cls.long = "同一个开头。" * 2200
        rows = []
        parent = None
        def message(uid, role, content, **extra):
            nonlocal parent
            rows.append(dict(type=role, uuid=uid, parentUuid=parent, cwd=cls.project,
                             timestamp=f"2026-09-01T00:{len(rows):02}:00Z",
                             entrypoint="cli", userType="external",
                             message={"role":role,"content":content}, **extra))
            parent=uid
        message("proposal", "assistant", "The feature table should show capability support; configuration belongs in product descriptions.")
        message("confirmation", "user", "是的")
        message("execution", "assistant", "I will update the comparison.")
        message("proposal-two", "assistant", "Keep the complete original source material.")
        message("confirmation-two", "user", "是的")
        message("long-a", "user", cls.long + "FIRST END")
        message("long-b", "user", cls.long + "SECOND END")
        message("tool-call", "assistant", [{"type":"tool_use","id":"failing-tool","name":"Bash","input":{"command":"run the check"}}])
        cls.tool_output = "Traceback (most recent call last):\n" + "frame details\n"*1100 + "ValueError: invalid result\n"
        message("tool-result", "user", [{"type":"tool_result","tool_use_id":"failing-tool","is_error":False,"content":cls.tool_output}])
        message("success-call", "assistant", [{"type":"tool_use","id":"success-tool","name":"Bash","input":{"command":"true"}}])
        message("success-result", "user", [{"type":"tool_result","tool_use_id":"success-tool","is_error":False,"content":"Exit code 0\nall done"}])
        message("json-call", "assistant", [{"type":"tool_use","id":"json-tool","name":"exec","input":{"command":"check"}}])
        message("json-result", "user", [{"type":"tool_result","tool_use_id":"json-tool","is_error":False,"content":json.dumps({"exit_code":7,"output":"check failed"})}])
        message("quote-call", "assistant", [{"type":"tool_use","id":"quote-tool","name":"Read","input":{"file_path":"guide.md"}}])
        message("quote-result", "user", [{"type":"tool_result","tool_use_id":"quote-tool","content":"Documentation example: {\"exit_code\": 2}. Exit code 1 means failure."}])
        message("edit-call", "assistant", [{"type":"tool_use","id":"edit-tool","name":"Edit","input":{"file_path":cls.project+"/target.py","old_string":"a","new_string":"b"}}])
        cls.long_command="x"*12050+" first command"
        message("multi-call", "assistant", [
            {"type":"tool_use","id":"multi-one","name":"Bash","input":{"command":cls.long_command}},
            {"type":"tool_use","id":"multi-two","name":"Bash","input":{"command":"second command"}},
        ])
        message("multi-result", "user", [
            {"type":"tool_result","tool_use_id":"multi-one","content":"first result"},
            {"type":"tool_result","tool_use_id":"multi-two","content":"second result"},
        ])
        (folder / "workflow.jsonl").write_text("\n"+"".join(json.dumps(r,ensure_ascii=False)+"\n" for r in rows))
        second = [dict(type="assistant",uuid="other-call",cwd=cls.project,timestamp="2026-09-02T00:00:00Z",message={"role":"assistant","content":[{"type":"tool_use","id":"other-tool","name":"Bash","input":{"command":"other"}}]})]
        (folder / "other.jsonl").write_text("".join(json.dumps(r)+"\n" for r in second))
        # A failing result whose distinguishing text sits in the part trunc() drops
        # from the indexed copy, next to a healthy result that merely mentions it.
        cls.middle_marker = "middlemarker7c1e"
        long_failure = "x" * 9000 + " " + cls.middle_marker + " " + "y" * 9000
        third = [
            dict(type="assistant",uuid="trunc-call",cwd=cls.project,timestamp="2026-09-02T01:00:00Z",message={"role":"assistant","content":[{"type":"tool_use","id":"trunc-tool","name":"Bash","input":{"command":"long"}}]}),
            dict(type="user",uuid="trunc-result",cwd=cls.project,timestamp="2026-09-02T01:00:01Z",message={"role":"user","content":[{"type":"tool_result","tool_use_id":"trunc-tool","is_error":True,"content":long_failure}]}),
            dict(type="assistant",uuid="mention-call",cwd=cls.project,timestamp="2026-09-02T01:00:02Z",message={"role":"assistant","content":[{"type":"tool_use","id":"mention-tool","name":"Read","input":{"file_path":"notes.md"}}]}),
            dict(type="user",uuid="mention-result",cwd=cls.project,timestamp="2026-09-02T01:00:03Z",message={"role":"user","content":[{"type":"tool_result","tool_use_id":"mention-tool","content":"notes mention "+cls.middle_marker+" and Exit code 0 without any failure"}]}),
        ]
        (folder / "truncated.jsonl").write_text("".join(json.dumps(r)+"\n" for r in third))
        # A failing result whose content is a block list with an image between two
        # text blocks; the indexed copy, the exact read and the pattern match must
        # all see the same text.
        cls.mixed_text = "alpha\n\nbeta"
        mixed = [
            dict(type="assistant",uuid="mixed-call",cwd=cls.project,timestamp="2026-09-02T02:00:00Z",message={"role":"assistant","content":[{"type":"tool_use","id":"mixed-tool","name":"Bash","input":{"command":"shot"}}]}),
            dict(type="user",uuid="mixed-result",cwd=cls.project,timestamp="2026-09-02T02:00:01Z",message={"role":"user","content":[{"type":"tool_result","tool_use_id":"mixed-tool","is_error":True,"content":[
                {"type":"text","text":"alpha"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"c3ludGhldGlj"}},{"type":"text","text":"beta"}]}]}),
        ]
        (folder / "mixed.jsonl").write_text("".join(json.dumps(r)+"\n" for r in mixed))
        cls.codex_id="019ff111-0000-7000-8000-000000000001"
        codex_folder=cls.root / "codex/sessions/2026/09/01"
        codex_folder.mkdir(parents=True)
        codex_rows=[
            {"type":"session_meta","timestamp":"2026-09-01T01:00:00Z","payload":{"id":cls.codex_id,"cwd":cls.project,"source":"cli","thread_source":"user","originator":"codex-tui"}},
            {"type":"response_item","timestamp":"2026-09-01T01:01:00Z","payload":{"type":"function_call","name":"exec","call_id":"wrapped","arguments":json.dumps({"cmd":"run check"})}},
            {"type":"response_item","timestamp":"2026-09-01T01:02:00Z","payload":{"type":"function_call_output","call_id":"wrapped","output":[{"type":"input_text","text":"Script completed"},{"type":"input_text","text":json.dumps({"exit_code":3,"output":"failure detail"})}]}},
        ]
        (codex_folder / f"rollout-{cls.codex_id}.jsonl").write_text("".join(json.dumps(r)+"\n" for r in codex_rows))
        p=cls.run_cli("index")
        if p.returncode: raise RuntimeError(p.stdout+p.stderr)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    @classmethod
    def run_cli(cls,*args, merged=False, input=None, env=None):
        return subprocess.run([sys.executable,str(ENGINE),*args], env=env or cls.env,
                              text=True,input=input,stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT if merged else subprocess.PIPE)

    def data(self,*args):
        p=self.run_cli(*args)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        return json.loads(p.stdout)["data"]

    def test_partial_search_remains_json_when_streams_are_merged(self):
        p=self.run_cli("search","同一个开头 capability","--all-projects",merged=True)
        self.assertEqual(p.returncode,0,p.stdout)
        result=json.loads(p.stdout)
        self.assertEqual(result["retrieval"]["lexical_match"],"partial_only")
        self.assertTrue(result["index_freshness"]["complete"])

    def test_argument_errors_are_machine_readable_and_nonzero(self):
        p=self.run_cli("tool-history","--unknown-option",merged=True)
        self.assertNotEqual(p.returncode,0)
        self.assertIn("unrecognized arguments",json.loads(p.stdout)["error"])

    def test_failure_list_distinguishes_exit_zero_and_links_full_evidence(self):
        rows=self.data("failures","--all-projects","--session","workflow")
        self.assertEqual({r["tool_id"] for r in rows},{"failing-tool","json-tool"})
        for row in rows:
            self.assertTrue(row["source_path"])
            self.assertGreater(row["line_no"],0)
            self.assertEqual(row["session_id"],"workflow")
            self.assertIn(row["failure_kind"],{"traceback","exit_code"})

    def test_tool_output_pages_reconstruct_the_original(self):
        offset=0
        parts=[]
        while True:
            page=self.data("get-tool","failing-tool","--session","workflow","--offset",str(offset),"--limit","2000")
            parts.append(page["text"])
            self.assertEqual(page["text_offset"],offset)
            self.assertFalse(page["is_error"])
            self.assertEqual(page["failure"]["failure_kind"],"traceback")
            if page["next_offset"] is None: break
            offset=page["next_offset"]
        self.assertEqual("".join(parts),self.tool_output)
        call=self.data("get-tool","failing-tool","--session","workflow","--part","input")
        self.assertEqual(json.loads(call["text"]),{"command":"run the check"})

    def test_long_session_messages_have_independent_identity_and_continuation(self):
        page=self.data("get-session","workflow","--limit","20")
        messages={m["uuid"]:m for m in page["messages"]}
        self.assertIn("long-a",list(messages))
        self.assertIn("long-b",list(messages))
        self.assertIn("confirmation-two",list(messages))
        for uid,end in [("long-a","FIRST END"),("long-b","SECOND END")]:
            m=messages[uid]
            self.assertTrue(m["next_offset"])
            tail=self.data("get-message",uid,"--session","workflow","--offset",str(m["next_offset"]),"--limit","20000")
            self.assertEqual(m["text"]+tail["text"],self.long+end)

    def test_context_expands_short_confirmation_in_conversation_order(self):
        ctx=self.data("context","confirmation","--session","workflow","--before","1","--after","1")
        self.assertEqual(ctx["message"]["text"],"是的")
        self.assertEqual([m["uuid"] for m in ctx["before"]],["proposal"])
        self.assertIn("configuration belongs",ctx["before"][0]["text"])
        self.assertEqual([m["uuid"] for m in ctx["after"]],["execution"])
        self.assertEqual(ctx["before"][0]["evidence_status"],"fresh")

    def test_tool_history_has_explicit_session_scope_and_readable_tool_ids(self):
        rows=self.data("tool-history","--session","workflow","--all-projects")
        self.assertEqual({r["session_id"] for r in rows},{"workflow"})
        self.assertEqual({r["tool_id"] for r in rows},{"failing-tool","success-tool","json-tool","quote-tool","edit-tool","multi-one","multi-two"})

    def test_multiple_tools_in_one_message_are_separately_addressable(self):
        first=self.data("get-tool","multi-one","--session","workflow")
        second=self.data("get-tool","multi-two","--session","workflow")
        self.assertEqual(first["text"],"first result")
        self.assertEqual(second["text"],"second result")
        source_lines=Path(first["source_path"]).read_text().splitlines()
        self.assertEqual(json.loads(source_lines[first["line_no"]-1])["uuid"],"multi-result")
        head=self.data("get-tool","multi-one","--session","workflow","--part","input")
        tail=self.data("get-tool","multi-one","--session","workflow","--part","input","--offset",str(head["next_offset"]))
        self.assertEqual(json.loads(head["text"]+tail["text"])["command"],self.long_command)

    def test_tool_middle_rewrite_is_not_mislabeled_as_verified_old_evidence(self):
        path=self.root / "claude/projects/workflow/workflow.jsonl"
        original=path.read_bytes()
        try:
            rewritten=self.tool_output[:9500]+"X"+self.tool_output[9501:]
            changed=original.replace(json.dumps(self.tool_output).encode(),json.dumps(rewritten).encode())
            self.assertNotEqual(changed,original)
            path.write_bytes(changed)
            value=self.data("get-tool","failing-tool","--session","workflow","--no-index")
            self.assertNotEqual(value["evidence_status"],"fresh")
            self.assertTrue(value["evidence_suppressed"])
            self.assertIsNone(value["text"])
        finally:
            path.write_bytes(original)
            self.run_cli("index")

    def test_codex_wrapped_exit_and_result_reference_are_readable(self):
        sid="codex:"+self.codex_id
        rows=self.data("failures","--session",sid,"--all-projects")
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]["exit_code"],3)
        body=self.data("get-tool",rows[0]["tool_id"],"--session",sid)
        self.assertEqual(body["line_no"],3)
        self.assertIn("failure detail",body["text"])

    def test_current_session_exclusion_happens_before_limit(self):
        env=dict(self.env,CODEX_THREAD_ID=self.codex_id)
        p=self.run_cli("tool-history","--all-projects","--exclude-current-session","--limit","1",env=env)
        self.assertEqual(p.returncode,0,p.stdout+p.stderr)
        rows=json.loads(p.stdout)["data"]
        self.assertEqual(len(rows),1)
        self.assertNotEqual(rows[0]["session_id"],"codex:"+self.codex_id)

    def test_safe_query_uses_the_same_context_and_tool_scope(self):
        ctx=self.run_cli("query","/dev/stdin",input=json.dumps({"op":"context","uuid":"confirmation-two","project_path":self.project,"preceding":1,"following":0}))
        self.assertEqual(ctx.returncode,0,ctx.stdout+ctx.stderr)
        self.assertEqual(json.loads(ctx.stdout)["data"]["before"][0]["uuid"],"proposal-two")
        out=self.run_cli("query","/dev/stdin",input=json.dumps({"op":"get-tool","tool_id":"failing-tool","session_id":"workflow","project_path":"/unrelated"}))
        self.assertNotEqual(out.returncode,0)
        self.assertIsNone(json.loads(out.stdout)["data"])

    def test_failure_pattern_reaches_text_missing_from_the_indexed_copy(self):
        rows=self.data("failures",self.middle_marker,"--all-projects","--session","truncated")
        self.assertEqual([r["tool_id"] for r in rows],["trunc-tool"])
        self.assertEqual(rows[0]["failure_kind"],"tool_error")
        self.assertEqual(rows[0]["evidence_status"],"fresh")
        self.assertEqual([r["tool_id"] for r in self.data("failures","--all-projects","--session","truncated")],["trunc-tool"])
        self.assertEqual(self.data("failures","nowhere-in-any-result","--all-projects","--session","truncated"),[])

    def test_image_blocks_in_a_result_read_and_match_as_one_text(self):
        read=self.data("get-tool","mixed-tool","--session","mixed","--part","output")
        self.assertEqual(read["text"],self.mixed_text)
        self.assertEqual(read["evidence_status"],"fresh")
        rows=self.data("failures",self.mixed_text,"--all-projects","--session","mixed")
        self.assertEqual([(r["tool_id"],r["failure_kind"],r["evidence_status"]) for r in rows],[("mixed-tool","tool_error","fresh")])
        self.assertEqual([r["tool_id"] for r in self.data("failures","--all-projects","--session","mixed")],["mixed-tool"])

    def test_failure_count_matches_the_failure_list(self):
        rows=self.data("failures","--session","workflow","--all-projects")
        report=self.data("session-report","--session","workflow","--all-projects")
        self.assertEqual(report["failed_tool_results"],len(rows))

    def test_overlay_preserves_file_history_order_and_deduplicates_tools(self):
        path=self.root / "claude/projects/workflow/other.jsonl"
        original=path.read_bytes()
        db=self.root / "index.sqlite"
        mode=db.stat().st_mode
        try:
            row={"type":"assistant","uuid":"new-mention","timestamp":"2026-09-03T00:00:00Z","cwd":self.project,"message":{"role":"assistant","content":[{"type":"tool_use","id":"new-mention-tool","name":"Bash","input":{"command":"cat "+self.project+"/target.py"}}]}}
            with path.open("a") as stream:stream.write(json.dumps(row)+"\n")
            db.chmod(0o444)
            p=self.run_cli("tool-history","target.py","--all-projects",merged=True)
            self.assertEqual(p.returncode,0,p.stdout)
            body=json.loads(p.stdout)
            self.assertEqual(body["index_freshness"]["mode"],"overlay+base")
            self.assertTrue(body["index_freshness"]["complete"])
            self.assertEqual([r["tool_id"] for r in body["data"]],["edit-tool","new-mention-tool"])
            self.assertTrue(body.get("diagnostics"))
        finally:
            db.chmod(mode)
            path.write_bytes(original)
            self.run_cli("index")

    def test_query_output_budget_failure_has_nonzero_status_and_freshness(self):
        p=self.run_cli("query-python","--trusted","/dev/stdin","--output-limit","100",input="result = 'x' * 500\n",merged=True)
        self.assertNotEqual(p.returncode,0)
        body=json.loads(p.stdout)
        self.assertIn("output",body["error"])
        self.assertIn("index_freshness",body)

    def test_trusted_query_prints_do_not_corrupt_its_result(self):
        p=self.run_cli("query-python","--trusted","/dev/stdin",input="print('query progress')\nresult = {'answer': 42}\n",merged=True)
        self.assertEqual(p.returncode,0,p.stdout)
        body=json.loads(p.stdout)
        self.assertEqual(body["data"],{"answer":42})
        self.assertIn("query progress",json.dumps(body.get("diagnostics")))

    def test_trusted_query_exception_is_a_structured_failure(self):
        p=self.run_cli("query-python","--trusted","/dev/stdin",input="result = {}['missing']\n",merged=True)
        self.assertNotEqual(p.returncode,0)
        body=json.loads(p.stdout)
        self.assertEqual(body["error_type"],"KeyError")
        self.assertIn("missing",body["error"])


if __name__ == "__main__":
    unittest.main()
