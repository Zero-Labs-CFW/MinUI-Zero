#!/usr/bin/env python3
"""Exercise the installer's actual pre-write consumer gate without device access."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ConsumerTests(unittest.TestCase):
    def test_installed_contract(self):
        source = (ROOT / 'workspace/h700/spl/zero-install.sh').read_text()
        start = source.index('stage2_consumer_ok() {')
        function = source[start:source.index('\n}\n', start) + 3]
        self.assertLess(source.index('stage2_consumer_ok /opt/'), source.index('want=$(md5sum'))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ack, helper, ident = (root / n for n in ('ack', 'helper', 'id'))
            for ack_ok, helper_ok, valid_id, matching_id in (
                    (True, True, True, True), (False, True, True, True),
                    (True, False, True, True), (True, True, False, True),
                    (True, True, True, False)):
                for path, ok in ((ack, ack_ok), (helper, helper_ok)):
                    body = 'echo zero-stage2-health-v1\n'
                    if path == helper:
                        compiled_id = ('a' if matching_id else 'b') * 64
                        body = ('case "$1" in\n--contract) echo zero-stage2-health-v1 ;;\n'
                                '--build-id) echo ' + compiled_id + ' ;;\n*) exit 1 ;;\nesac\n')
                    path.write_text('#!/bin/sh\n' + body + 'exit ' + ('0' if ok else '1') + '\n')
                    path.chmod(0o755)
                ident.write_text(('a' * 64 if valid_id else 'invalid') + '\n')
                result = subprocess.run(['sh', '-c', function + '\nstage2_consumer_ok "$1" "$2" "$3"',
                                         'gate', str(ack), str(helper), str(ident)])
                self.assertEqual(result.returncode == 0, ack_ok and helper_ok and valid_id and matching_id)
            helper.unlink()
            result = subprocess.run(['sh', '-c', function + '\nstage2_consumer_ok "$1" "$2" "$3"',
                                     'gate', str(ack), str(helper), str(ident)])
            self.assertNotEqual(result.returncode, 0)

    def test_ack_query_is_read_only(self):
        result = subprocess.run(['sh', str(ROOT / 'tools/h700-strip/boot0-slot.sh'), 'stage2-contract'],
                                capture_output=True, check=True)
        self.assertEqual(result.stdout, b'zero-stage2-health-v1\n')


if __name__ == '__main__':
    unittest.main()
