#!/usr/bin/env python3
"""Exercise the actual shipping shell gate without devices, RTC or card writes."""
from pathlib import Path
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / 'h700-strip/boot0-slot.sh'


class AckTests(unittest.TestCase):
    def test_bounded_retry(self):
        source = SOURCE.read_text()
        start = source.index('stage2_health_ok() {')
        function = source[start:source.index('\n}\n', start) + 3]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            helper, count = root / 'helper', root / 'count'
            for succeed, attempts in ((3, 3), (99, 15)):
                count.write_text('0\n')
                helper.write_text('#!/bin/sh\nn=$(cat "' + str(count) + '"); n=$((n+1)); '
                                  'echo "$n" > "' + str(count) + '"\n[ "$n" -ge ' + str(succeed) + ' ]\n')
                helper.chmod(0o755)
                result = subprocess.run(['sh', '-c', 'sleep() { :; }\n' + function +
                                         '\nstage2_health_ok 0x5A560045 /missing "$1"',
                                         'gate', str(helper)], capture_output=True)
                self.assertEqual(result.returncode == 0, succeed == 3)
                self.assertEqual(int(count.read_text()), attempts)

    def test_gate(self):
        source = SOURCE.read_text()
        start = source.index('stage2_health_ok() {')
        end = source.index('\n}\n', start) + 3
        function = source[start:end]
        self.assertLess(source.index('stage2_health_ok "$_stage_mark"'), source.index('dd if=/dev/zero of=$D bs=512 seek=16640', source.index('ack)')))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record, helper = root / 'record', root / 'health'
            for mark in ('0x5A560009', '0x5A560045', '0x5a560045'):
                for present in (False, True):
                    if present:
                        record.write_bytes(b'not a parsed record; helper owns validation')
                    else:
                        record.unlink(missing_ok=True)
                    for helper_state in ('missing', 'not-executable', 'reject', 'accept'):
                        helper.unlink(missing_ok=True)
                        if helper_state != 'missing':
                            helper.write_text('#!/bin/sh\nexit ' + ('0' if helper_state == 'accept' else '1') + '\n')
                            helper.chmod(0o755 if helper_state != 'not-executable' else 0o644)
                        result = subprocess.run(['sh', '-c', 'sleep() { :; }\n' + function + '\nstage2_health_ok "$1" "$2" "$3"',
                                                 'gate', mark, str(record), str(helper)], capture_output=True)
                        required = mark.lower() == '0x5a560045' or present
                        self.assertEqual(result.returncode == 0, not required or helper_state == 'accept')


if __name__ == '__main__':
    unittest.main()
