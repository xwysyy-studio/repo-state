"""Exercise local commands with stale server settings and guarded network APIs."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ENGINE = Path(os.environ.get('REPO_STATE_TEST_ENGINE',
              Path(__file__).parents[1] / 'scripts/transcriptctl.py'))
SID = '24681012-2468-4123-8123-246810121416'
WRAPPER = r'''
import os, pathlib, runpy, sys
def guard(event, args):
    blocked = event.startswith('socket.')
    if event == 'subprocess.Popen':
        blocked = pathlib.Path(str(args[0])).name != 'ps'
    if event == 'open' and isinstance(args[0], (str, bytes)):
        blocked = blocked or pathlib.Path(os.fsdecode(args[0])).name in ('sync.json', 'machine.json')
    if blocked:
        with open(os.environ['ATTEMPT_LOG'], 'a') as out:
            out.write(event + '\n')
        raise RuntimeError('local-only contract: forbidden operation ' + event)
sys.addaudithook(guard)
sys.path.insert(0, str(pathlib.Path(sys.argv[1]).parent))
sys.argv = sys.argv[1:]
runpy.run_path(sys.argv[0], run_name='__main__')
'''


class LocalOnly(unittest.TestCase):
    def test_local_lifecycle_ignores_server_configuration(self):
        self.check_lifecycle(False)

    def test_stale_server_snapshot_flag_cannot_disable_local_refresh(self):
        self.check_lifecycle(True)

    def check_lifecycle(self, snapshot):
        with tempfile.TemporaryDirectory(prefix='repo-state-local-') as tmp:
            root = Path(tmp)
            state = root / '.repo-state'
            state.mkdir()
            (state / 'sync.json').write_text(json.dumps(dict(
                version=1, host='unused.invalid', remote_root='/srv/repo-state',
                remote_search_enabled=True, port=22)))
            (state / 'machine.json').write_text(json.dumps(dict(id=SID, name='fixture')))
            source = root / 'claude/projects/fixture' / (SID + '.jsonl')
            source.parent.mkdir(parents=True)
            source.write_text(json.dumps(dict(type='user', uuid='local-message',
                sessionId=SID, cwd='/fixture', timestamp='2026-01-01T00:00:00Z',
                message=dict(role='user', content='localonlyneedle'))) + '\n')
            original = source.read_bytes()
            attempts = root / 'attempts.log'
            env = dict(os.environ, REPO_STATE_HOME=str(state),
                REPO_STATE_SYNC_CONFIG=str(state/'sync.json'),
                REPO_STATE_PUBLISHED_SNAPSHOT='1' if snapshot else '0',
                REPO_STATE_DB=str(state/'transcripts.sqlite'),
                REPO_STATE_POLICY=str(state/'session-policy.json'),
                REPO_STATE_AUDIT_LOG=str(state/'audit.jsonl'),
                REPO_STATE_CLAUDE_DIR=str(root/'claude'),
                REPO_STATE_CODEX_DIR=str(root/'codex'),
                ATTEMPT_LOG=str(attempts))
            def cli(*args):
                p = subprocess.run([sys.executable, '-c', WRAPPER, str(ENGINE), *args],
                    env=env, text=True, capture_output=True)
                self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
                self.assertFalse(attempts.exists(), attempts.read_text() if attempts.exists() else '')
                return p.stdout if args[0] == 'index' else json.loads(p.stdout)
            cli('index')
            found = cli('search', 'localonlyneedle', '--all-projects')
            self.assertEqual(len(found['data']), 1)
            self.assertEqual(found['index_freshness']['mode'], 'refreshed')
            message = cli('get-message', 'local-message', '--session', SID)
            self.assertIn('localonlyneedle', json.dumps(message))
            ignored = cli('ignore-session', 'claude:'+SID)
            self.assertNotIn('remote', ignored['data'])
            self.assertEqual(cli('search', 'localonlyneedle', '--all-projects')['data'], [])
            cli('unignore-session', 'claude:'+SID)
            self.assertEqual(cli('search', 'localonlyneedle', '--all-projects')['data'], [])
            cli('index')
            self.assertEqual(len(cli('search', 'localonlyneedle', '--all-projects')['data']), 1)
            self.assertEqual(source.read_bytes(), original)


if __name__ == '__main__':
    unittest.main()
