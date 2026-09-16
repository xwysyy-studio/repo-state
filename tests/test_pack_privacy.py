"""Generated package metadata must not disclose source directory identities."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import zipfile

PACK = Path(__file__).parents[1] / 'scripts/packctl.py'


class PackPrivacy(unittest.TestCase):
    def test_absolute_source_paths_stay_out_of_manifests(self):
        with tempfile.TemporaryDirectory(prefix='repo-state-pack-privacy-') as tmp:
            root = Path(tmp)
            source = root/'private-user'/'internal-project'
            source.mkdir(parents=True)
            task = b'Read the attached example.\n'
            (source/'TASK.md').write_bytes(task)
            (source/'.env').write_text('example=excluded\n')
            (source/'uncertain.json').write_text('synthetic invalid JSON\n')
            p = subprocess.run([sys.executable, str(PACK), str(source),
                '--topic', 'privacy', '--out', str(root/'output'),
                '--ack', str(source)+':synthetic fixture approved'],
                cwd=root, text=True, capture_output=True)
            self.assertEqual(p.returncode, 0, p.stdout+p.stderr)
            archive = next((root/'output').rglob('*.zip'))
            with zipfile.ZipFile(archive) as z:
                data = z.read('MANIFEST.json')
                self.assertEqual(z.read('TASK.md'), task)
            self.assertNotIn(str(root).encode(), data)
            self.assertNotIn(b'private-user', data)
            self.assertNotIn(b'internal-project', data)
            manifest = json.loads(data)
            row = next(r for r in manifest['included'] if r['dest']=='TASK.md')
            self.assertEqual(row['sha256'], hashlib.sha256(task).hexdigest())
            self.assertEqual(row['source'], 'input-1/TASK.md')
            self.assertEqual(manifest['excluded'][0]['path'], 'input-1/.env')
            self.assertEqual(manifest['privacy_acks'][0]['ack_prefix'], 'input-1')
            self.assertIn('could not privacy-check', manifest['privacy_acks'][0]['finding'])
            self.assertEqual((archive.parent/'MANIFEST.json').read_bytes(), data)


if __name__ == '__main__':
    unittest.main()
