"""A ZIP cannot replace the two older generations of rootfs boot helpers."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest
import zipfile


class UpdateTests(unittest.TestCase):
    def test_old_rootfs_refuses_without_installing(self):
        tools = Path(__file__).resolve().parents[1]
        build = (tools / 'build-h700-stripped.sh').read_text()
        levels = [int(re.search(r'^' + key + r'=(\d+)$', build, re.M)[1])
                  for key in ('ROOTFS_LEVEL', 'PAYLOAD_MIN_ROOTFS')]
        self.assertGreaterEqual(levels[0], levels[1])
        self.assertGreater(levels[1], 2)
        for old in (1, 2):
            with self.subTest(old=old), tempfile.TemporaryDirectory() as tmp:
                card = Path(tmp)
                (card / 'rootfs-level').write_text(str(old))
                save = card / 'save.sav'
                save.write_bytes(b'keep')
                archive = card / 'MinUI.zip'
                with zipfile.ZipFile(archive, 'w') as z:
                    z.writestr('.system/h700/min-rootfs', str(levels[1]))
                    z.writestr('.system/h700/paks/MinUI.pak/launch.sh', 'exit 0')
                before = archive.read_bytes()
                subprocess.run(['sh', tools / 'h700-strip/card-update.sh'],
                               env=dict(os.environ, SDCARD_PATH=tmp, ZERO_STATE_DIR=tmp),
                               check=True, capture_output=True)
                self.assertIn('flashing the full image', (card / 'MinUI-update-failed.txt').read_text())
                self.assertEqual(save.read_bytes(), b'keep')
                self.assertEqual(archive.read_bytes(), before)
                self.assertFalse((card / '.system').exists())
