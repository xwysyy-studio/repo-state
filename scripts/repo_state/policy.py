"""Durable local session exclusions for the indexer."""
from contextlib import contextmanager
import fcntl
import json
import os
from pathlib import Path
import re
import tempfile
import uuid

VERSION = 1


def key(provider, session_id):
    if provider not in ('claude', 'codex') or not isinstance(session_id, str):
        raise ValueError('session identity requires provider claude/codex and a string ID')
    sid = session_id.strip()
    prefix = provider + ':'
    if sid.startswith(prefix):
        sid = sid[len(prefix):]
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*', sid):
        raise ValueError('session ID must be a complete identifier, not a path or pattern')
    try:
        sid = str(uuid.UUID(sid))
    except ValueError:
        pass
    return provider, sid


def entries(keys):
    return [dict(provider=p, session_id=s) for p, s in sorted(set(keys))]


def keys(rows):
    if not isinstance(rows, list):
        raise ValueError('session identities must be a list')
    result = set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {'provider', 'session_id'}:
            raise ValueError('each identity must contain provider and session_id')
        result.add(key(row['provider'], row['session_id']))
    return frozenset(result)


def validate(data):
    if not isinstance(data, dict) or type(data.get('version')) is not int or data['version'] != VERSION:
        raise ValueError('unsupported session policy version')
    if set(data) - {'version', 'revision', 'ignored', 'pending_index'}:
        raise ValueError('unknown session policy fields')
    revision = data.get('revision', 0)
    if type(revision) is not int or revision < 0:
        raise ValueError('policy revision must be a nonnegative integer')
    ignored, pending = keys(data['ignored']), keys(data.get('pending_index', []))
    if ignored & pending:
        raise ValueError('an ignored session cannot also await indexing')
    return dict(version=VERSION, revision=revision, ignored=entries(ignored),
                pending_index=entries(pending))


def load(path):
    try:
        with open(path, encoding='utf-8') as src:
            return validate(json.load(src))
    except FileNotFoundError:
        return dict(version=VERSION, revision=0, ignored=[], pending_index=[])


def atomic_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temp = tempfile.mkstemp(prefix=path.name+'.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as out:
            json.dump(value, out, ensure_ascii=False, sort_keys=True, indent=2)
            out.write('\n')
            out.flush()
            os.fsync(out.fileno())
        os.replace(temp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temp):
            os.unlink(temp)


@contextmanager
def lock(path, exclusive=True, nonblocking=False):
    """Serialize policy changes and source publication against readers."""
    path = Path(path)
    try:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd = os.open(path, os.O_RDWR | os.O_CREAT | os.O_CLOEXEC, 0o600)
    except OSError:
        if exclusive:
            raise
        try:
            fd = os.open(path, os.O_RDONLY | os.O_CLOEXEC)
        except FileNotFoundError:
            # A read-only empty policy directory has no writer to coordinate.
            yield None
            return
    with os.fdopen(fd, 'rb') as handle:
        mode = fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH
        fcntl.flock(handle, mode | (fcntl.LOCK_NB if nonblocking else 0))
        yield handle


def deferred(path):
    return keys(load(path)["pending_index"])
