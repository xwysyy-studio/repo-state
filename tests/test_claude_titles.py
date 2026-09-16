"""Claude title precedence, incremental parsing and existing-index upgrades."""
from contextlib import closing
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest


ENGINE = Path(__file__).parents[1] / 'scripts/transcriptctl.py'
SID = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'
TITLE_MIGRATION = '__claude_titles_v1__'


class ClaudeTitles(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='repo-state-titles-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.db = self.root / 'index.sqlite'
        self.source = self.root / 'claude/projects/example' / (SID + '.jsonl')
        self.source.parent.mkdir(parents=True)
        self.env = dict(os.environ, REPO_STATE_DB=str(self.db),
                        REPO_STATE_CLAUDE_DIR=str(self.root / 'claude'),
                        REPO_STATE_CODEX_DIR=str(self.root / 'codex'),
                        REPO_STATE_POLICY=str(self.root / 'policy.json'),
                        REPO_STATE_AUDIT_LOG=str(self.root / 'audit.jsonl'),
                        REPO_STATE_SYNC_CONFIG=str(self.root / 'absent-sync.json'),
                        REPO_STATE_DISABLE_JIEBA='1')
        self.env.pop('CODEX_THREAD_ID', None)
        self.message = dict(type='user', uuid='title-message', sessionId=SID,
                            cwd='/Users/example/Code/project',
                            timestamp='2026-09-01T00:00:00Z',
                            entrypoint='cli', userType='external',
                            message=dict(role='user', content='titlecontractneedle'))

    def cli(self, *args):
        p = subprocess.run([sys.executable, str(ENGINE), *args], env=self.env,
                           text=True, capture_output=True)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return p.stdout

    def data(self, *args):
        return json.loads(self.cli(*args))['data']

    def write(self, *rows, append=False, path=None):
        path = path or self.source
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open('a' if append else 'w') as out:
            for row in rows:
                out.write(json.dumps(row) + '\n')

    def assert_title(self, expected):
        session = self.data('get-session', SID)['session']
        self.assertEqual(session['title'], expected)
        hits = self.data('search', 'titlecontractneedle', '--all-projects')
        self.assertEqual([h['session_title'] for h in hits], [expected])

    def evidence(self):
        with closing(sqlite3.connect(self.db)) as db:
            return {table: db.execute(f'SELECT * FROM {table} ORDER BY rowid').fetchall()
                    for table in ('messages', 'records', 'tool_calls', 'tool_results')}

    def test_custom_title_wins_over_later_ai_and_agent_names(self):
        self.write(dict(type='custom-title', customTitle='Named session'),
                   dict(type='agent-name', agentName='Display agent'), self.message,
                   dict(type='ai-title', aiTitle='Generated title'))
        self.cli('index')
        self.assert_title('Named session')

    def test_append_keeps_precedence_and_latest_custom_name(self):
        self.write(self.message, dict(type='ai-title', aiTitle='Initial AI'))
        self.cli('index')
        self.assert_title('Initial AI')
        self.write(dict(type='custom-title', customTitle='First name'), append=True)
        self.assert_title('First name')
        self.write(dict(type='ai-title', aiTitle='Later AI'), append=True)
        self.assert_title('First name')
        self.write(dict(type='custom-title', customTitle='Renamed'),
                   dict(type='custom-title', customTitle=''), append=True)
        self.assert_title('Renamed')
        before = self.evidence()
        self.cli('index', '--rebuild')
        self.assert_title('Renamed')
        self.assertEqual(self.evidence(), before)

    def test_rewrite_removes_custom_name_and_uses_remaining_sources(self):
        self.write(dict(type='custom-title', customTitle='Old name'), self.message)
        history = self.root / 'claude/history.jsonl'
        self.write(dict(sessionId=SID, title='History title'), path=history)
        self.cli('index')
        self.assert_title('Old name')
        self.write(self.message, dict(type='ai-title', aiTitle='Current AI'))
        self.assert_title('Current AI')
        self.write(self.message)
        self.assert_title('History title')

    def test_subagent_title_does_not_rename_main_session(self):
        self.write(self.message, dict(type='ai-title', aiTitle='Main session'))
        agent = self.source.with_suffix('') / 'subagents/agent-example.jsonl'
        self.write(dict(type='custom-title', customTitle='Agent session'), path=agent)
        self.cli('index')
        self.assert_title('Main session')

    def test_existing_unchanged_source_gets_title_only_backfill(self):
        self.write(dict(type='custom-title', customTitle='Recovered name'), self.message)
        self.cli('index')
        # The pre-upgrade index kept custom-title records but had no title projection.
        with closing(sqlite3.connect(self.db)) as db:
            db.execute('UPDATE sessions SET title=NULL WHERE id=?', (SID,))
            db.execute('DELETE FROM index_state WHERE jsonl_path=?', (TITLE_MIGRATION,))
            before_session = db.execute('SELECT * FROM sessions WHERE id=?', (SID,)).fetchone()
            db.commit()
        original = self.source.read_bytes()
        before_stat = self.source.stat()
        before = self.evidence()
        self.assert_title('Recovered name')
        with closing(sqlite3.connect(self.db)) as db:
            after_session = db.execute('SELECT * FROM sessions WHERE id=?', (SID,)).fetchone()
        self.assertEqual(after_session[:1] + after_session[2:],
                         before_session[:1] + before_session[2:])
        self.assertEqual(self.evidence(), before)
        self.assertEqual(self.source.read_bytes(), original)
        self.assertEqual(self.source.stat().st_mtime_ns, before_stat.st_mtime_ns)
        self.assertIn('checks: scoped to 0 sessions, 0 sources', self.cli('index'))


if __name__ == '__main__':
    unittest.main()
