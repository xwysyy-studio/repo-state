"""Read a Codex thread before and after a paginated thread/revert.

The native recorder keeps SessionMeta.id but changes the rollout filename;
history_base names the previous rollout and the retained byte/ordinal prefix.
"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ENGINE = Path(__file__).parents[1] / 'scripts/transcriptctl.py'
SID = '019a0000-0000-7000-8000-00000000000a'
REVERT = '019a0000-0000-7000-8000-00000000000b'


class CodexRollouts(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='repo-state-rollouts-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.folder = self.root / 'codex/sessions'
        self.folder.mkdir(parents=True)
        self.env = dict(os.environ, REPO_STATE_CODEX_DIR=str(self.root/'codex'),
                        REPO_STATE_CLAUDE_DIR=str(self.root/'claude'),
                        REPO_STATE_DB=str(self.root/'index.sqlite'),
                        REPO_STATE_POLICY=str(self.root/'policy.json'),
                        REPO_STATE_AUDIT_LOG=str(self.root/'audit.jsonl'),
                        REPO_STATE_SYNC_CONFIG=str(self.root/'absent-sync.json'),
                        REPO_STATE_DISABLE_JIEBA='1', CODEX_THREAD_ID=SID)
        self.first = self.folder / f'rollout-2026-09-15T10-00-00-{SID}.jsonl'
        self.second = self.folder / f'rollout-2026-09-15T11-00-00-{SID}_{REVERT}.jsonl'
        prefix = self.encode(self.meta(0, '10:00'), self.message(1, 'retainedneedle'))
        self.cutoff = len(prefix)
        self.first.write_bytes(prefix + self.encode(self.message(2, 'revertedneedle'),
                                                   self.message(3, 'oldtailneedle')))

    def meta(self, ordinal, time, base=None):
        payload = dict(id=SID, session_id=SID, cwd='/synthetic',
                       timestamp=f'2026-09-15T{time}:00Z', originator='Codex Desktop',
                       source='vscode', thread_source='user', history_mode='paginated')
        if base is not None:
            payload['history_base'] = dict(thread_id=SID, end_ordinal_exclusive=2,
                                           end_byte_offset=base)
        return dict(type='session_meta', ordinal=ordinal, payload=payload)

    def message(self, ordinal, text):
        return dict(type='response_item', ordinal=ordinal,
                    timestamp=f'2026-09-15T11:{ordinal:02}:00Z',
                    payload=dict(type='message', role='user',
                                 content=[dict(type='input_text', text=text)]))

    def encode(self, *rows):
        return ''.join(json.dumps(row)+'\n' for row in rows).encode()

    def revert(self):
        self.second.write_bytes(self.encode(self.meta(2, '11:00', self.cutoff),
                                             self.message(3, 'replacementneedle')))

    def cli(self, *args):
        proc = subprocess.run([sys.executable, str(ENGINE), *args], env=self.env,
                              capture_output=True, text=True)
        self.assertEqual(proc.returncode, 0, proc.stdout+proc.stderr)
        return proc.stdout if args[0] == 'index' else json.loads(proc.stdout)

    def assert_visible(self, *expected):
        result = self.cli('get-session', 'codex:'+SID)
        self.assertTrue(result['index_freshness']['complete'], result)
        self.assertEqual([m['text'] for m in result['data']['messages']], list(expected))
        return result['data']['messages']

    def test_rebuild_keeps_both_sources_and_marks_reverted_tail(self):
        self.revert()
        before = {p: hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in (self.first, self.second)}
        self.cli('index')
        visible = self.assert_visible('retainedneedle', 'replacementneedle')
        all_rows = self.cli('get-session', 'codex:'+SID, '--include-abandoned')['data']['messages']
        self.assertEqual({m['text'] for m in all_rows},
                         {'retainedneedle', 'revertedneedle', 'oldtailneedle', 'replacementneedle'})
        self.assertEqual(len({m['uuid'] for m in all_rows}), 4)
        self.assertEqual({m['text'] for m in all_rows if m.get('is_abandoned')},
                         {'revertedneedle', 'oldtailneedle'})
        for message in all_rows:
            exact = self.cli('get-message', message['uuid'], '--session', 'codex:'+SID)
            self.assertEqual(exact['data']['text'], message['text'])
            self.assertEqual(exact['data']['evidence_status'], 'fresh')
        self.assertEqual(self.cli('search', 'revertedneedle', '--all-projects')['data'], [])
        self.assertEqual(len(self.cli('search', 'replacementneedle', '--speaker', 'original-user',
                                      '--current-session', '--all-projects')['data']), 1)
        self.cli('index', '--rebuild')
        self.assertEqual([m['uuid'] for m in self.assert_visible('retainedneedle', 'replacementneedle')],
                         [m['uuid'] for m in visible])
        self.assertEqual(before, {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in before})

    def test_incremental_revert_and_updates_to_either_rollout(self):
        self.cli('index')
        self.assert_visible('retainedneedle', 'revertedneedle', 'oldtailneedle')
        self.revert()
        self.cli('index')
        self.assert_visible('retainedneedle', 'replacementneedle')
        with self.first.open('ab') as out:
            out.write(self.encode(self.message(4, 'lateoldneedle')))
        self.cli('index')
        self.assert_visible('retainedneedle', 'replacementneedle')
        with self.second.open('ab') as out:
            out.write(self.encode(self.message(4, 'appendedneedle')))
        self.cli('index')
        self.assert_visible('retainedneedle', 'replacementneedle', 'appendedneedle')

    def test_readonly_overlay_observes_revert_boundary(self):
        self.cli('index')
        self.revert()
        db = self.root/'index.sqlite'
        mode = db.stat().st_mode
        try:
            db.chmod(0o444)
            result = self.cli('search', 'needle', '--all-projects')
            self.assertEqual(result['index_freshness']['mode'], 'overlay+base')
            self.assertTrue(result['index_freshness']['complete'], result)
            self.assertEqual({row['snippet'] for row in result['data']},
                             {'retainedneedle', 'replacementneedle'})
            self.assert_visible('retainedneedle', 'replacementneedle')
        finally:
            db.chmod(mode)


if __name__ == '__main__':
    unittest.main()
