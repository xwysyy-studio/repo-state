"""Native file observations shared by the Linux/macOS lifecycle tests."""
import hashlib
import os
from pathlib import Path
import subprocess
import sys


def open_paths(pid):
    if sys.platform == 'darwin':
        result = subprocess.run(['lsof', '-nP', '-a', '-p', str(pid), '-Fn'],
                                capture_output=True, text=True, check=True)
        paths = [line[1:] for line in result.stdout.splitlines() if line.startswith('n/')]
    else:
        paths = []
        for path in Path(f'/proc/{pid}/fd').iterdir():
            try:
                paths.append(os.readlink(path))
            except FileNotFoundError:
                pass  # The inspected process may close a descriptor during enumeration.
    return {os.path.realpath(path) for path in paths}


if __name__ == '__main__':
    command, path = sys.argv[1:]
    if command == 'sha256':
        with open(path, 'rb') as source:
            print(hashlib.file_digest(source, 'sha256').hexdigest())
    else:
        print(getattr(os.stat(path), {'size': 'st_size', 'inode': 'st_ino', 'mtime': 'st_mtime_ns'}[command]))
