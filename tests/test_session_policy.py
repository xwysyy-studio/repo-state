"""Session exclusions must survive failures and every ingestion/query path."""
from contextlib import closing
import json
import os
from pathlib import Path
import runpy
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ENGINE = Path(__file__).parents[1] / 'scripts/transcriptctl.py'
SID = '24681012-2468-4123-8123-246810121416'


class SessionPolicy(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='repo-state-policy-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, REPO_STATE_DB=str(self.root/'index.sqlite'),
                        REPO_STATE_POLICY=str(self.root/'policy.json'),
                        REPO_STATE_CLAUDE_DIR=str(self.root/'claude'),
                        REPO_STATE_CODEX_DIR=str(self.root/'codex'),
                        REPO_STATE_AUDIT_LOG=str(self.root/'audit.jsonl'),
                        REPO_STATE_DISABLE_JIEBA='1',
                        REPO_STATE_SYNC_CONFIG=str(self.root/'absent-sync.json'))
        self.env.pop('CODEX_THREAD_ID', None)

    def cli(self, *args, ok=True):
        p = subprocess.run([sys.executable, str(ENGINE), *args], env=self.env,
                           text=True, capture_output=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        return p

    def claude(self, sid=SID):
        p = self.root / 'claude/projects/synthetic' / (sid+'.jsonl')
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(dict(type='user', uuid=sid+'-user', sessionId=sid,
            cwd='/synthetic', timestamp='2026-01-01T00:00:00Z',
            message=dict(role='user', content='policycontractneedle'))) + '\n')
        return p

    def codex(self, name='renamed.jsonl'):
        p = self.root/'codex/sessions'/name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text('\n'.join(json.dumps(r) for r in [
            dict(type='session_meta', timestamp='2026-01-01T00:00:00Z',
                 payload=dict(id=SID, cwd='/synthetic', originator='codex-tui', source='cli')),
            dict(type='event_msg', timestamp='2026-01-01T00:00:01Z',
                 payload=dict(type='user_message', message='policycontractneedle')),
        ])+'\n')
        return p

    def hits(self, *args):
        return json.loads(self.cli('search', 'policycontractneedle', '--all-projects', *args).stdout)['data']

    def test_ignore_survives_index_upgrade_failure(self):
        self.claude()
        self.cli('index')
        self.cli('ignore-session', 'claude:'+SID)
        with closing(sqlite3.connect(self.root/'index.sqlite')) as db:
            db.execute('PRAGMA user_version=0')
        self.cli('ignore-session', 'claude:'+SID, ok=False)
        policy = json.loads((self.root/'policy.json').read_text())
        self.assertIn(dict(provider='claude', session_id=SID), policy['ignored'])

    def test_unignore_requires_explicit_index_even_after_queries(self):
        p = self.claude()
        before = p.read_bytes()
        self.cli('index')
        self.cli('ignore-session', 'claude:'+SID)
        self.cli('unignore-session', 'claude:'+SID)
        self.assertEqual(self.hits(), [])
        self.assertEqual(self.hits('--no-index'), [])
        self.cli('index')
        self.assertEqual(len(self.hits()), 1)
        self.assertEqual(p.read_bytes(), before)

    def test_codex_metadata_identity_survives_rename_and_rebuild(self):
        p = self.codex()
        p.write_text(json.dumps(dict(type='session_meta',payload={}))+'\n'+p.read_text())
        before = p.read_bytes()
        self.cli('index')
        self.cli('ignore-session', 'codex:'+SID)
        for args in [(), ('index',), ('index', '--rebuild')]:
            if args: self.cli(*args)
            with closing(sqlite3.connect(self.root/'index.sqlite')) as db:
                self.assertEqual(db.execute('SELECT COUNT(*) FROM messages WHERE session_id=?',
                                            ('codex:'+SID,)).fetchone()[0], 0)
            self.assertEqual(self.hits(), [])
        self.assertEqual(p.read_bytes(), before)

    def test_codex_ignore_does_not_remove_same_uuid_claude(self):
        self.claude()
        self.codex('rollout-'+SID+'.jsonl')
        self.cli('index')
        self.cli('ignore-session', 'codex:'+SID)
        self.assertEqual([r['session_id'] for r in self.hits()], [SID])

    def test_ignore_can_be_registered_before_first_index(self):
        self.claude()
        self.cli('ignore-session', 'claude:'+SID)
        self.cli('index')
        self.assertEqual(self.hits(), [])

    def test_missing_source_does_not_leave_content_rows_after_ignore(self):
        p = self.claude()
        self.cli('index')
        p.unlink()
        self.cli('ignore-session', 'claude:'+SID)
        with closing(sqlite3.connect(self.root/'index.sqlite')) as db:
            for table, column in [('messages','session_id'),('session_sources','session_id'),
                                  ('source_inventory','session_id')]:
                self.assertEqual(db.execute(f'SELECT COUNT(*) FROM {table} WHERE {column}=?',
                                            (SID,)).fetchone()[0], 0)

    def test_bare_ignored_claude_id_can_be_unignored(self):
        self.claude()
        self.cli('index')
        self.cli('ignore-session', 'claude:'+SID)
        self.cli('unignore-session', SID)
        self.assertEqual(json.loads((self.root/'policy.json').read_text())['ignored'], [])

    def test_ignore_is_targeted_and_tolerates_unrelated_incomplete_source(self):
        self.claude()
        self.cli('index')
        other = self.root/'claude/projects/synthetic/other.jsonl'
        other.write_text('{"unfinished":')
        self.cli('ignore-session', 'claude:'+SID)
        self.assertEqual(self.hits('--no-index'), [])

    def test_policy_revision_is_monotonic_and_idempotent(self):
        self.claude()
        self.cli('index')
        self.cli('ignore-session', 'claude:'+SID)
        first = json.loads((self.root/'policy.json').read_text())['revision']
        self.cli('ignore-session', 'claude:'+SID)
        self.assertEqual(json.loads((self.root/'policy.json').read_text())['revision'], first)
        self.cli('unignore-session', 'claude:'+SID)
        self.assertGreater(json.loads((self.root/'policy.json').read_text())['revision'], first)

    def test_failed_cleanup_cannot_leak_through_exact_or_sql_read(self):
        self.claude()
        self.cli('index')
        (self.root/'policy.json').write_text(json.dumps(dict(version=1,revision=1,
            ignored=[dict(provider='claude', session_id=SID)])))
        self.assertEqual(self.hits('--no-index'), [])
        p = self.cli('get-message', SID+'-user','--session',SID,'--no-index',ok=False)
        self.assertNotIn('policycontractneedle', p.stdout)
        script = self.root/'query.py'
        script.write_text('result = sql("SELECT text FROM messages")')
        p = self.cli('query-python','--trusted',str(script),'--no-index',ok=False)
        self.assertNotIn('policycontractneedle', p.stdout)

    def test_readonly_cleanup_reports_pending_and_preserves_exclusions(self):
        self.claude()
        self.cli('index')
        (self.root/'index.sqlite').chmod(0o444)
        try:
            value = json.loads(self.cli('ignore-session','claude:'+SID).stdout)['data']
            self.assertEqual(value['index']['status'],'pending')
            self.assertNotIn('remote', value)
            self.assertEqual(self.hits('--no-index'),[])
        finally:
            (self.root/'index.sqlite').chmod(0o600)

    def test_qualified_sql_cannot_bypass_exclusions_in_a_stale_index(self):
        self.claude()
        self.cli('index')
        (self.root/'policy.json').write_text(json.dumps(dict(version=1,revision=1,
            ignored=[dict(provider='claude', session_id=SID)])))
        script=self.root/'qualified.py'
        for table in ('main.messages','messages_fts'):
            script.write_text('result = sql("SELECT text FROM '+table+'")')
            result=self.cli('query-python','--trusted',str(script),'--no-index',ok=False)
            self.assertNotIn('policycontractneedle',result.stdout)

    def test_retention_candidates_return_metadata_without_mutation(self):
        source=self.claude()
        original=source.read_bytes()
        self.cli('index')
        output=self.cli('retention-candidates','--older-than','1d','--no-index')
        rows=json.loads(output.stdout)['data']['candidates']
        self.assertEqual([r['session_id'] for r in rows],[SID])
        self.assertNotIn('policycontractneedle',output.stdout)
        self.assertEqual(source.read_bytes(),original)

    def test_codex_attached_threads_follow_parent_but_user_forks_remain(self):
        parent=self.codex('rollout-'+SID+'.jsonl')
        child='11111111-2222-4222-8222-111111111111'
        grandchild='22222222-2222-4222-8222-222222222222'
        fork='33333333-2222-4222-8222-333333333333'
        original=parent.read_text()
        for sid,owner in ((child,SID),(grandchild,child),(fork,None)):
            records=[json.loads(line) for line in original.splitlines()]
            records[0]['payload'].update(id=sid)
            if owner:
                records[0]['payload']['source']={'subagent':{'thread_spawn':{'parent_thread_id':owner}}}
            else:
                records[0]['payload']['forked_from_id']=SID
            (parent.parent/('rollout-'+sid+'.jsonl')).write_text(''.join(json.dumps(r)+'\n' for r in records))
        self.cli('index')
        self.cli('ignore-session','codex:'+SID)
        self.assertEqual({r['session_id'] for r in self.hits()}, {'codex:'+fork})
        with closing(sqlite3.connect(self.root/'index.sqlite')) as db:
            for sid in (SID,child,grandchild):
                self.assertEqual(db.execute('SELECT COUNT(*) FROM messages WHERE session_id=?',
                                            ('codex:'+sid,)).fetchone()[0],0)
        self.cli('index','--rebuild')
        self.assertEqual({r['session_id'] for r in self.hits()}, {'codex:'+fork})
        self.cli('unignore-session','codex:'+SID)
        self.assertEqual({r['session_id'] for r in self.hits()}, {'codex:'+fork})
        self.cli('index')
        with closing(sqlite3.connect(self.root/'index.sqlite')) as db:
            self.assertEqual(db.execute('SELECT COUNT(*) FROM messages').fetchone()[0],4)
        self.assertEqual(parent.read_text(),original)

    def test_new_attached_thread_is_excluded_after_the_initial_policy_scan(self):
        parent=self.codex('rollout-'+SID+'.jsonl')
        self.cli('index')
        self.cli('ignore-session','codex:'+SID)
        with patch.dict(os.environ,self.env):
            engine=runpy.run_path(str(ENGINE),run_name='live_child_probe')
        ingest=engine['index_codex_jsonl']
        ingest.__globals__['_ACTIVE_EXCLUSIONS']=frozenset({('codex',SID)})
        child='44444444-2222-4222-8222-444444444444'
        records=[json.loads(line) for line in parent.read_text().splitlines()]
        records[0]['payload'].update(id=child,source={'subagent':{'thread_spawn':{'parent_thread_id':SID}}})
        path=parent.parent/('rollout-'+child+'.jsonl')
        path.write_text(''.join(json.dumps(r)+'\n' for r in records))
        db=engine['open_rw']()
        try:
            self.assertFalse(ingest(db,str(path)))
            self.assertEqual(db.execute('SELECT COUNT(*) FROM messages').fetchone()[0],0)
        finally:
            db.close()


if __name__ == '__main__':
    unittest.main()
