#!/usr/bin/env python3
"""Incremental index passes check and renormalize only what they touched.

Every scenario compares the scoped pass with a full recomputation on a copy of
the same database: the invariants must hold everywhere and Codex effective
timestamps must be identical."""
from contextlib import closing
import json
import os
from pathlib import Path
import runpy
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ENGINE = Path(__file__).parents[1] / 'scripts/transcriptctl.py'
ROOT_A = '019a0000-0000-7000-8000-00000000000a'
FORK_B = '019a0000-0000-7000-8000-00000000000b'
FORK_C = '019a0000-0000-7000-8000-00000000000c'
ROOT_D = '019a0000-0000-7000-8000-00000000000d'
CLAUDE = 'aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa'


def stamp(minute):
    return f'2026-03-01T00:{minute:02d}:00.000Z'


class IncrementalMaintenance(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='repo-state-maintenance-')
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
        (self.root/'codex/sessions').mkdir(parents=True)
        (self.root/'claude/projects/synthetic').mkdir(parents=True)
        # Root A, fork B copies A's prefix, fork C copies B's prefix: C inherits
        # A's timestamps through B for the shared prefix.
        self.a_msgs = [('user', 'alpha one', 1), ('assistant', 'alpha reply', 2)]
        self.b_msgs = [('user', 'alpha one', 10), ('assistant', 'alpha reply', 11),
                       ('user', 'beta three', 12)]
        self.c_msgs = [('user', 'alpha one', 20), ('assistant', 'alpha reply', 21),
                       ('user', 'beta three', 22), ('user', 'gamma four', 23)]
        self.d_msgs = [('user', 'delta one', 5), ('assistant', 'delta reply', 6)]
        self.codex(ROOT_A, self.a_msgs)
        self.codex(FORK_B, self.b_msgs, parent=ROOT_A)
        self.codex(FORK_C, self.c_msgs, parent=FORK_B)
        self.codex(ROOT_D, self.d_msgs)
        self.claude(CLAUDE, [('user', 'claude one'), ('assistant', 'claude reply')])

    def codex(self, sid, messages, parent=None):
        meta = dict(id=sid, cwd='/synthetic', source='cli', thread_source='user',
                    originator='codex-tui', timestamp=stamp(0))
        if parent:
            meta['forked_from_id'] = parent
        rows = [dict(type='session_meta', timestamp=stamp(0), payload=meta)]
        for role, text, minute in messages:
            kind = 'user_message' if role == 'user' else 'agent_message'
            rows.append(dict(type='event_msg', timestamp=stamp(minute),
                             payload=dict(type=kind, message=text)))
        path = self.root/'codex/sessions'/f'rollout-{sid}.jsonl'
        path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
        return path

    def claude(self, sid, messages, agent=None):
        if agent:
            path = self.root/'claude/projects/synthetic'/sid/'subagents'/f'{agent}.jsonl'
        else:
            path = self.root/'claude/projects/synthetic'/f'{sid}.jsonl'
        path.parent.mkdir(parents=True, exist_ok=True)
        rows = []
        parent = None
        for n, (role, text) in enumerate(messages):
            uid = f'{sid}-{agent or "main"}-{n}'
            rows.append(dict(type=role, uuid=uid, parentUuid=parent, sessionId=sid,
                             cwd='/synthetic', timestamp=stamp(n),
                             message=dict(role=role, content=text)))
            parent = uid
        path.write_text(''.join(json.dumps(r)+'\n' for r in rows))
        return path

    def cli(self, *args, ok=True):
        p = subprocess.run([sys.executable, str(ENGINE), *args], env=self.env,
                           text=True, capture_output=True)
        if ok:
            self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
        return p

    def index(self, expect):
        p = self.cli('index')
        self.assertIn(expect, p.stdout, p.stdout+p.stderr)
        self.assert_equivalent_to_full_pass()
        return p

    def engine(self):
        with patch.dict(os.environ, self.env):
            return runpy.run_path(str(ENGINE), run_name='maintenance_probe')

    def effective(self, db):
        return db.execute("SELECT session_id,uuid,effective_timestamp FROM messages"
                          " WHERE source='codex' ORDER BY session_id,uuid").fetchall()

    def assert_equivalent_to_full_pass(self):
        """The scoped pass must leave exactly the state a full pass produces."""
        module = self.engine()
        copy = self.root/'copy.sqlite'
        with closing(sqlite3.connect(self.root/'index.sqlite')) as live:
            with closing(sqlite3.connect(copy)) as out:
                live.backup(out)
        with closing(sqlite3.connect(copy)) as db:
            module['register_sql_functions'](db)
            module['validate_index_invariants'](db)
            before = self.effective(db)
            module['normalize_codex_effective_timestamps'](db)
            self.assertEqual(before, self.effective(db))
            self.assertTrue(module['index_pass_complete'](db))
        copy.unlink()

    def timestamps(self, sid):
        with closing(sqlite3.connect(self.root/'index.sqlite')) as db:
            rows = db.execute("SELECT effective_timestamp FROM messages WHERE session_id=?"
                              " AND content_type='text' ORDER BY record_no",
                              ('codex:'+sid,)).fetchall()
        return [r[0] for r in rows]

    def test_no_change_pass_checks_nothing_and_keeps_inherited_timestamps(self):
        self.index('checks: full')
        self.assertEqual(self.timestamps(FORK_B), [stamp(1), stamp(2), None])
        self.assertEqual(self.timestamps(FORK_C), [stamp(1), stamp(2), stamp(12), None])
        self.index('checks: scoped to 0 sessions, 0 sources')

    def test_ancestor_change_renormalizes_descendants_only(self):
        self.index('checks: full')
        self.codex(ROOT_A, self.a_msgs + [('assistant', 'alpha more', 3)])
        p = self.index('checks: scoped to 3 sessions, 1 sources')
        self.assertIn('scoped', p.stdout)
        self.assertEqual(self.timestamps(FORK_C), [stamp(1), stamp(2), stamp(12), None])

    def test_reparenting_a_fork_recomputes_its_subtree(self):
        self.index('checks: full')
        self.codex(FORK_B, self.b_msgs, parent=ROOT_D)
        self.index('checks: scoped to 2 sessions, 1 sources')
        self.assertEqual(self.timestamps(FORK_B), [None, None, None])
        self.assertEqual(self.timestamps(FORK_C), [stamp(10), stamp(11), stamp(12), None])

    def test_deleted_parent_and_policy_cleanup(self):
        self.index('checks: full')
        (self.root/'codex/sessions'/f'rollout-{ROOT_A}.jsonl').unlink()
        self.index('checks: scoped to 3 sessions, 1 sources')
        self.assertEqual(self.timestamps(FORK_B), [None, None, None])
        self.assertEqual(self.timestamps(FORK_C), [stamp(10), stamp(11), stamp(12), None])
        # A policy purge removes rows outside a pass: the next pass checks everything once.
        self.cli('ignore-session', 'codex:'+ROOT_D)
        self.index('checks: full')
        self.index('checks: scoped to 0 sessions, 0 sources')

    def test_parser_failure_and_recovery_keep_the_index_consistent(self):
        self.claude(CLAUDE, [('user', 'agent work')], agent='agent-1')
        self.index('checks: full')
        main = self.root/'claude/projects/synthetic'/f'{CLAUDE}.jsonl'
        good = main.read_bytes()
        main.write_bytes(json.dumps(dict(type='user', uuid='broken', sessionId=CLAUDE,
                                         cwd='/synthetic', timestamp=stamp(0),
                                         message='not-an-object')).encode()+b'\n')
        self.index('checks: scoped to 1 sessions, 2 sources')
        with closing(sqlite3.connect(self.root/'index.sqlite')) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM messages WHERE session_id=?",
                                        (CLAUDE,)).fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT status FROM index_state WHERE jsonl_path=?",
                                        (str(main),)).fetchone()[0], 'parser-error')
        main.write_bytes(good)
        self.index('checks: scoped to 1 sessions, 2 sources')
        with closing(sqlite3.connect(self.root/'index.sqlite')) as db:
            self.assertEqual(db.execute("SELECT COUNT(*) FROM messages WHERE session_id=?",
                                        (CLAUDE,)).fetchone()[0], 3)

    def test_failed_check_forces_a_full_check_next_time(self):
        self.index('checks: full')
        with closing(sqlite3.connect(self.root/'index.sqlite')) as db:
            db.execute("INSERT INTO tool_calls (id,message_uuid,session_id,name) VALUES"
                       " ('ghost','missing-message',?,'Bash')", ('codex:'+ROOT_A,))
            db.commit()
        # The damaged session is touched by this pass, so the scoped check sees it.
        self.codex(ROOT_A, self.a_msgs + [('assistant', 'alpha more', 3)])
        p = self.cli('index', ok=False)
        self.assertNotEqual(p.returncode, 0)
        self.assertIn('index invariant failure: orphan_tool_calls=1', p.stdout+p.stderr)
        with closing(sqlite3.connect(self.root/'index.sqlite')) as db:
            db.execute("DELETE FROM tool_calls WHERE id='ghost'")
            db.commit()
        self.index('checks: full')
        self.index('checks: scoped to 0 sessions, 0 sources')

    def test_rebuild_validates_the_published_artifact(self):
        self.index('checks: full')
        p = self.cli('index', '--rebuild')
        self.assertIn('checks: full', p.stdout)
        self.assert_equivalent_to_full_pass()
        self.assertEqual(self.timestamps(FORK_C), [stamp(1), stamp(2), stamp(12), None])
        self.index('checks: scoped to 0 sessions, 0 sources')


if __name__ == '__main__':
    unittest.main()
