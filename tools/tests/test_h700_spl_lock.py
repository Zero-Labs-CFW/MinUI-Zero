"""Run shipping shell transactions against guarded regular-file fixtures, never devices."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import shlex
import re

from test_h700_stage2_recovery import egon_image, loader_image

ROOT = Path(__file__).resolve().parents[2]
SHELL = shlex.split(os.environ.get('H700_TEST_SHELL', 'sh'))

# A deliberately small dd adapter: all writes must remain inside the fixture.
DD = '''import os, pathlib, sys, time
root = pathlib.Path(os.environ['FIXTURE']).resolve()
a = dict(x.split('=', 1) for x in sys.argv[1:])
bs = int(a.get('bs', 512)); skip = int(a.get('skip', 0)); seek = int(a.get('seek', 0))
count = int(a['count']) * bs if 'count' in a else None
src, dst = a.get('if'), a.get('of')
if src and pathlib.Path(src).resolve() == root / 'card' and skip == 16 and count == 512 and os.environ.get('PAUSE_READ'):
    (root / 'entered').touch()
    end = time.monotonic() + 10
    while not (root / 'continue').exists():
        if time.monotonic() > end: sys.exit(90)
        time.sleep(.01)
if src == '/dev/zero':
    assert count is not None
    data = bytes(count)
elif src:
    p = pathlib.Path(src).resolve()
    assert p.is_relative_to(root), ('unsafe read', src)
    with p.open('rb') as f:
        f.seek(skip * bs); data = f.read() if count is None else f.read(count)
    if p == root / 'card' and os.environ.get('FAIL_READ') == str(skip): sys.exit(94)
    if p == root / 'card' and os.environ.get('SHORT_READ') == str(skip): data = data[:8]
else:
    data = sys.stdin.buffer.read()[skip * bs:]
    if count is not None: data = data[:count]
if dst:
    p = pathlib.Path(dst).resolve()
    assert p.is_relative_to(root), ('unsafe write', dst)
    if p == root / 'card':
        with (root / 'writes').open('a') as f: f.write(str(seek) + '\\n')
        if os.environ.get('PAUSE_WRITE') == str(seek):
            (root / 'entered').touch()
            end = time.monotonic() + 10
            while not (root / 'continue').exists():
                if time.monotonic() > end: sys.exit(90)
                time.sleep(.01)
        if os.environ.get('PARTIAL_WRITE') == str(seek):
            with p.open('r+b') as f:
                f.seek(seek * bs); f.write(data[:len(data)//2])
            sys.exit(91)
        if os.environ.get('FAIL_WRITE') == str(seek): sys.exit(91)
    with p.open('r+b' if 'notrunc' in a.get('conv', '') and p.exists() else 'wb') as f:
        f.seek(seek * bs); f.write(data)
else:
    sys.stdout.buffer.write(data)
'''


class LockTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='h700-lock-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.z = self.root / 'z'
        self.run = self.root / 'run'
        self.bin = self.root / 'bin'
        for p in (self.z, self.run, self.bin, self.root / 'tmp', self.z / 'boards', self.z / 'spl'):
            p.mkdir(parents=True, exist_ok=True)
        self.busy = self.run / 'zero-spl-busy'
        self.sleep = self.run / 'zero-spl-sleep'
        self.flag = self.z / '.spl-sleep-swapped'
        self.card = self.root / 'card'
        self.card.write_bytes(bytes(19000 * 512))
        with self.card.open('r+b') as f:
            for lba in (24576, 32800):
                f.seek(lba * 512); f.write(b'fixture package')
            for lba in (16, 512, 16384, 16512):
                f.seek(lba * 512); f.write(egon_image(stock=True))
        (self.root / 'spl.bin').write_bytes(egon_image())
        (self.root / 'cmdline').write_text('androidboot.serialno=1234567890abcdef123\n')
        (self.root / 'board').write_text('plus\n')
        for name in ('rg35xx-plus', 'plus', 'rg35xx-h', 'sp'):
            path = self.z / 'boards' / name
            path.mkdir()
            (path / 'package.fex').write_bytes(b'fixture package')
        loader = self.z / 'loader'
        loader.mkdir()
        (loader / 'zero-loader.bin').write_bytes(loader_image())
        (loader / 'build-id').write_text('a' * 64 + '\n')
        health = loader / 'boot-health'
        health.write_text('#!/bin/sh\ncase "$1" in --contract) echo zero-stage2-health-v1;; '
                          '--build-id) cat "$FIXTURE/z/loader/build-id";; *) test -e "$FIXTURE/receipt";; esac\n')
        health.chmod(0o755)
        (self.root / 'cardroot/.system/h700').mkdir(parents=True)
        (self.root / 'cardroot/.system/h700/board').write_text('plus\n')
        (self.root / 'drop_caches').touch()
        (self.root / 'mounts').write_text('x ' + str(self.root / 'cardroot') + ' vfat rw 0 0\n')
        for name, relative in (('boot0-slot.sh', 'tools/h700-strip/boot0-slot.sh'),
                               ('spl-auto.sh', 'tools/h700-strip/spl-auto.sh'),
                               ('zero-install.sh', 'workspace/h700/spl/zero-install.sh'),
                               ('boardpick.sh', 'tools/h700-strip/boardpick.sh'),
                               ('spl-lock.sh', 'tools/h700-strip/spl-lock.sh')):
            source = (ROOT / relative).read_text()
            redirects = dict((('/dev/mmcblk0', str(self.card)),
                             ('/opt/minui-zero', str(self.z)), ('/run/', str(self.run) + '/'),
                             ('/tmp/', str(self.root / 'tmp') + '/'),
                             ('/proc/cmdline', str(self.root / 'cmdline')),
                             ('/proc/sys/vm/drop_caches', str(self.root / 'drop_caches')),
                             ('/proc/mounts', str(self.root / 'mounts')),
                             ('/sys/firmware/devicetree/base/chosen/zero,loader', str(self.root / 'receipt')),
                             ('/mnt/mmc/.system/h700/board', str(self.root / 'board')),
                             ('/mnt/mmc', str(self.root / 'cardroot'))))
            source = re.sub('|'.join(re.escape(k) for k in redirects),
                            lambda match: redirects[match.group()], source)
            # ash may use its sleep builtin rather than PATH; keep unit-test time deterministic.
            source = source.replace('#!/bin/sh\n', '#!/bin/sh\nsleep() { "$FIXTURE/bin/sleep" "$@"; }\n', 1)
            p = self.z / ('spl/' + name if name == 'zero-install.sh' else name)
            p.write_text(source); p.chmod(0o755)
        (self.bin / 'dd').write_text('#!' + sys.executable + '\n' + DD)
        (self.bin / 'sync').write_text('#!/bin/sh\nexit 0\n')
        (self.bin / 'sleep').write_text('#!/bin/sh\nexit 0\n')
        (self.bin / 'wc').write_text('#!' + sys.executable + '\nimport sys\nassert sys.argv[1:] == ["-c"]\nprint(len(sys.stdin.buffer.read()))\n')
        if SHELL != ['sh']:
            (self.bin / 'sh').write_text('#!/bin/sh\nexec ' + shlex.join(SHELL) + ' "$@"\n')
        (self.bin / 'busybox').write_text('''#!/bin/sh
[ "$1" = devmem ] || exit 92
if [ "$#" = 4 ]; then
    echo "$2" >> "$FIXTURE/rtc-writes"
    [ "${FAIL_RTC-}" != "$2" ] || exit 93
    exit 0
fi
[ "${BAD_RTC_READ-}" != "$2" ] || { echo garbage; exit 0; }
case "$2" in
0x03006200) echo 0x00000000;;
0x03006204) echo 0x12300000;;
0x03006208) echo 0x4567890a;;
0x0300620c) echo 0xbcdef123;;
*) echo 0x00000000;;
esac
''')
        for p in self.bin.iterdir():
            p.chmod(0o755)
        self.env = {**os.environ, 'PATH': str(self.bin) + ':' + os.environ['PATH'],
                    'FIXTURE': str(self.root)}

    def call(self, name, *args, **env):
        return subprocess.run([*SHELL, str(self.z / name), *args], env={**self.env, **env},
                              capture_output=True, text=True, timeout=15)

    def ok(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def writes(self):
        p = self.root / 'writes'
        return p.read_text() if p.exists() else ''

    def reap(self, proc):
        if proc.poll() is None:
            proc.kill()
        proc.communicate(timeout=10)

    def test_all_entrypoints_refuse_foreign_owner(self):
        self.busy.write_text('foreign\n')
        for command in ('stock', 'ours', 'boot', 'remove', 'store', 'ack'):
            with self.subTest(command=command):
                (self.run / 'zero-menu-frame').touch()
                r = self.call('boot0-slot.sh', command, str(self.root / 'spl.bin'))
                self.assertNotEqual(r.returncode, 0)
                self.assertEqual(self.busy.read_text(), 'foreign\n')
                self.assertFalse(self.writes())
        r = self.call('spl/zero-install.sh', str(self.root / 'spl.bin'))
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.writes())

    def test_stock_sleep_intent_blocks_install_even_without_swap(self):
        self.ok(self.call('boot0-slot.sh', 'stock'))
        self.assertTrue(self.sleep.exists())
        self.assertFalse(self.busy.exists())
        for name, args in (('spl/zero-install.sh', (str(self.root / 'spl.bin'),)),
                           ('boot0-slot.sh', ('remove',)),
                           ('boot0-slot.sh', ('store', str(self.root / 'spl.bin')))):
            self.assertNotEqual(self.call(name, *args).returncode, 0)
            self.assertFalse(self.writes())
            self.assertFalse(self.busy.exists())
        self.ok(self.call('boot0-slot.sh', 'ours'))
        self.assertFalse(self.sleep.exists())

    def test_read_admission_is_already_locked(self):
        proc = subprocess.Popen([*SHELL, str(self.z / 'boot0-slot.sh'), 'stock'],
                                env={**self.env, 'PAUSE_READ': '1'}, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.reap, proc)
        end = time.monotonic() + 5
        while not (self.root / 'entered').exists() and time.monotonic() < end:
            time.sleep(.01)
        self.assertTrue((self.root / 'entered').exists())
        self.assertTrue(self.busy.exists())
        r = self.call('spl/zero-install.sh', str(self.root / 'spl.bin'))
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.writes())
        (self.root / 'continue').touch()
        out, err = proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 0, out + err)

    def test_install_then_sleep_restore(self):
        self.ok(self.call('spl/zero-install.sh', str(self.root / 'spl.bin')))
        self.assertFalse(self.busy.exists())
        self.ok(self.call('boot0-slot.sh', 'stock'))
        self.assertTrue(self.flag.exists())
        self.assertTrue(self.sleep.exists())
        self.ok(self.call('boot0-slot.sh', 'ours'))
        self.assertFalse(self.flag.exists())
        self.assertFalse(self.sleep.exists())
        self.assertFalse(self.busy.exists())
        with self.card.open('rb') as f:
            f.seek(16 * 512)
            self.assertEqual(f.read(1024), egon_image())

    def test_failed_write_retains_lock(self):
        r = self.call('spl/zero-install.sh', str(self.root / 'spl.bin'), FAIL_WRITE='16384')
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(self.busy.exists())
        self.assertIn('retaining', r.stderr)
        self.assertNotEqual(self.call('boot0-slot.sh', 'stock').returncode, 0)

    def test_validation_failure_releases_lock(self):
        self.card.write_bytes(bytes(19000 * 512))
        self.assertNotEqual(self.call('spl/zero-install.sh', str(self.root / 'spl.bin')).returncode, 0)
        self.assertFalse(self.busy.exists())
        self.assertFalse(self.writes())

    def test_every_installer_write_failure_quarantines(self):
        for lba in (16384, 16512, 16640, 16768, 16641, 16896, 17, 16):
            with self.subTest(lba=lba):
                x = LockTests(); x.setUp()
                try:
                    r = x.call('spl/zero-install.sh', str(x.root / 'spl.bin'), PARTIAL_WRITE=str(lba))
                    self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
                    self.assertTrue(x.busy.exists())
                    before = x.writes()
                    self.assertNotEqual(x.call('boot0-slot.sh', 'stock').returncode, 0)
                    self.assertEqual(x.writes(), before)
                finally:
                    x.doCleanups()

    def test_installer_owns_lock_while_child_write_is_alive(self):
        proc = subprocess.Popen([*SHELL, str(self.z / 'spl/zero-install.sh'), str(self.root / 'spl.bin')],
                                env={**self.env, 'PAUSE_WRITE': '16384'}, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.reap, proc)
        end = time.monotonic() + 5
        while not (self.root / 'entered').exists() and time.monotonic() < end:
            time.sleep(.01)
        self.assertTrue((self.root / 'entered').exists())
        self.assertTrue(self.busy.exists())
        before = self.writes()
        for action in ('stock', 'remove', 'ack'):
            (self.run / 'zero-menu-frame').touch()
            self.assertNotEqual(self.call('boot0-slot.sh', action).returncode, 0)
            self.assertEqual(self.writes(), before)
        proc.send_signal(15)
        self.assertTrue(self.busy.exists())
        (self.root / 'continue').touch()
        proc.communicate(timeout=10)
        self.assertNotEqual(proc.returncode, 0)
        self.assertTrue(self.busy.exists())

    def test_two_auto_workers_do_not_share_policy_scratch(self):
        (self.z / 'boards/chosen').write_text('rg35xx-plus\n')
        (self.z / 'spl-state').write_text('ready\n')
        (self.z / 'spl/zero-spl.bin').write_bytes(egon_image())
        proc = subprocess.Popen([*SHELL, str(self.z / 'spl-auto.sh')],
                                env={**self.env, 'PAUSE_READ': '1'}, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.reap, proc)
        end = time.monotonic() + 5
        while not (self.root / 'entered').exists() and time.monotonic() < end:
            time.sleep(.01)
        self.assertTrue((self.root / 'entered').exists())
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual((self.z / 'spl-state').read_text().strip(), 'ready')
        self.assertFalse(self.writes())
        (self.root / 'continue').touch()
        out, err = proc.communicate(timeout=10)
        self.assertEqual(proc.returncode, 0, out + err)
        self.assertEqual((self.z / 'spl-state').read_text().strip(), 'stage2:auto:plus')

    def test_release_auto_upgrade_and_fallback(self):
        (self.z / 'boards/chosen').write_text('rg35xx-h\n')
        (self.root / 'board').write_text('h\n')
        (self.root / 'cardroot/.system/h700/board').write_text('h\n')
        spl = self.z / 'spl/zero-spl.bin'
        spl.write_bytes(egon_image())
        self.ok(self.call('spl/zero-install.sh', str(spl)))
        state = self.z / 'spl-state'
        state.write_text('installed\n')
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(state.read_text().strip(), 'stage2:auto:h')
        self.assertEqual(self.card.read_bytes()[16896*512:16898*512], loader_image())
        (self.run / 'zero-stage2-provisioned').unlink()
        receipt = self.root / 'receipt'
        receipt.touch()
        before = self.writes()
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(self.writes(), before)
        receipt.unlink()
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(state.read_text().strip(), 'failed')
        data = self.card.read_bytes()
        self.assertEqual(data[16*512:144*512], egon_image(stock=True))
        self.assertEqual(data[16896*512:16897*512], bytes(512))
        before = self.writes()
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(self.writes(), before)

    def select_board(self, name):
        (self.z / 'boards/chosen').write_text(name + '\n')
        (self.root / 'board').write_text(name + '\n')
        (self.root / 'cardroot/.system/h700/board').write_text(name + '\n')
        (self.z / 'spl/zero-spl.bin').write_bytes(egon_image())

    def test_fresh_plus_and_explicit_off(self):
        self.select_board('plus')
        self.ok(self.call('spl-auto.sh'))
        self.assertFalse(self.writes())  # allow stock training on first chosen boot
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(self.card.read_bytes()[16896*512:16898*512], loader_image())
        (self.root / 'cardroot/fast-boot.txt').touch()
        (self.root / 'cardroot/fast-boot-off.txt').touch()
        self.ok(self.call('spl-auto.sh'))
        data = self.card.read_bytes()
        self.assertEqual(data[16*512:144*512], egon_image(stock=True))
        self.assertEqual(data[16896*512:16897*512], bytes(512))
        before = self.writes()
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(self.writes(), before)

    def test_trial_consent_and_withdrawal(self):
        self.select_board('sp')
        state = self.z / 'spl-state'
        state.write_text('ready\n')
        self.ok(self.call('spl-auto.sh'))
        self.assertFalse(self.writes())
        for old in ('fast-boot-trial.txt', 'fast-boot-stage2-trial.txt'):
            (self.root / 'cardroot' / old).touch()
            self.ok(self.call('spl-auto.sh'))
            self.assertFalse(self.writes())
        marker = self.root / 'cardroot/fast-boot.txt'
        marker.touch()
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(state.read_text().strip(), 'stage2:trial:sp')
        self.assertEqual(self.card.read_bytes()[16896*512:16898*512], loader_image())
        marker.unlink()
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(state.read_text().strip(), 'stock')
        self.assertEqual(self.card.read_bytes()[16896*512:16897*512], bytes(512))

    def test_unknown_board_neither_marker_can_authorize_writes(self):
        self.select_board('unknown')
        (self.z / 'spl-state').write_text('ready\n')
        for name in ('fast-boot-trial.txt', 'fast-boot-stage2-trial.txt', 'fast-boot.txt'):
            (self.root / ('cardroot/' + name)).touch()
            self.ok(self.call('spl-auto.sh'))
            self.assertFalse(self.writes())

    def test_mismatched_package_refuses_before_raw_writes(self):
        self.select_board('plus')
        (self.z / 'boards/plus/package.fex').write_bytes(b'other board')
        (self.z / 'spl-state').write_text('ready\n')
        self.ok(self.call('spl-auto.sh'))
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual((self.z / 'spl-state').read_text().strip(), 'failed')
        self.assertFalse(self.writes())

    def test_off_during_recovery_cannot_rearm(self):
        self.select_board('plus')
        state = self.z / 'spl-state'
        state.write_text('stage2:auto:plus\n')
        with self.card.open('r+b') as f:
            f.seek(16896 * 512); f.write(loader_image())
        marker = self.root / 'cardroot/fast-boot-off.txt'
        marker.touch()
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(state.read_text().strip(), 'failed')
        self.assertEqual(self.card.read_bytes()[16896*512:16897*512], bytes(512))
        marker.unlink()
        before = self.writes()
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(self.writes(), before)

    def test_cut_during_header_publish_restores_without_retry(self):
        self.select_board('plus')
        state = self.z / 'spl-state'
        state.write_text('ready\n')
        # Fail the loader body write, after the old header has been invalidated.
        self.ok(self.call('spl-auto.sh', PARTIAL_WRITE='16897'))
        self.assertTrue(self.busy.exists())
        self.assertEqual(self.card.read_bytes()[16896*512:16897*512], bytes(512))
        self.busy.unlink()  # /run starts empty at the next boot
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(state.read_text().strip(), 'failed')
        before = self.writes()
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(self.writes(), before)

    def test_ack_releases_before_auto(self):
        (self.run / 'zero-menu-frame').touch()
        (self.z / 'spl-auto.sh').write_text('#!/bin/sh\n[ ! -e "' + str(self.busy) + '" ] || exit 88\ntouch "' + str(self.root / 'auto-called') + '"\n')
        self.ok(self.call('boot0-slot.sh', 'ack'))
        self.assertTrue((self.root / 'auto-called').exists())
        self.assertFalse(self.busy.exists())

    def test_ack_retries_clean_contention_and_rechecks_marker(self):
        self.ok(self.call('spl/zero-install.sh', str(self.root / 'spl.bin')))
        with self.card.open('r+b') as f:
            f.seek(16640 * 512); f.write(b'ZERO-ATTEMPT-V1' + bytes(497))
        (self.run / 'zero-menu-frame').touch()
        (self.bin / 'sleep').write_text('#!' + sys.executable + '''
import os, pathlib, time
r = pathlib.Path(os.environ['FIXTURE'])
(r / 'ack-waited').touch()
end = time.monotonic() + 5
while (r / 'run/zero-spl-busy').exists():
    if time.monotonic() > end: raise SystemExit(95)
    time.sleep(.01)
''')
        holder = subprocess.Popen([*SHELL, '-c', '. "$1"; spl_lock_acquire "$2"; touch "$3"; '
                                   'while [ ! -e "$4" ]; do /bin/sleep .01; done', 'peer',
                                   str(self.z / 'spl-lock.sh'), str(self.busy),
                                   str(self.root / 'peer-ready'), str(self.root / 'peer-release')],
                                  env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.reap, holder)
        end = time.monotonic() + 5
        while not (self.root / 'peer-ready').exists() and time.monotonic() < end:
            time.sleep(.01)
        self.assertTrue((self.root / 'peer-ready').exists())
        ack = subprocess.Popen([*SHELL, str(self.z / 'boot0-slot.sh'), 'ack'], env=self.env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(self.reap, ack)
        end = time.monotonic() + 5
        while not (self.root / 'ack-waited').exists() and time.monotonic() < end:
            time.sleep(.01)
        self.assertTrue((self.root / 'ack-waited').exists())
        (self.root / 'peer-release').touch()
        out, err = holder.communicate(timeout=10)
        self.assertEqual(holder.returncode, 0, out + err)
        out, err = ack.communicate(timeout=10)
        self.assertEqual(ack.returncode, 0, out + err)
        self.assertFalse(self.busy.exists())
        with self.card.open('rb') as f:
            f.seek(16640 * 512); self.assertEqual(f.read(512), bytes(512))

    def test_auto_does_not_overwrite_raw_lock(self):
        (self.z / 'boards/chosen').write_text('rg35xx-plus\n')
        (self.z / 'spl-state').write_text('ready\n')
        (self.z / 'spl/zero-spl.bin').write_bytes(egon_image())
        self.busy.write_text('foreign\n')
        self.ok(self.call('spl-auto.sh'))
        self.assertEqual(self.busy.read_text(), 'foreign\n')
        self.assertFalse(self.writes())
        self.assertFalse((self.run / 'zero-spl-auto').exists())
        self.assertEqual((self.z / 'spl-state').read_text().strip(), 'ready')
        self.assertIn('install deferred', (self.root / 'cardroot/.userdata/h700/logs/fast-boot.txt').read_text())

    def test_another_suspend_cannot_clear_intent(self):
        self.ok(self.call('boot0-slot.sh', 'stock'))
        owner = self.sleep.read_text()
        # A distinct suspend parent attempts stock, then its usual abort-ours.
        r = subprocess.run([*SHELL, '-c', 'sh "$1" stock; sh "$1" ours; :',
                            'other-suspend', str(self.z / 'boot0-slot.sh')],
                           env=self.env, capture_output=True, text=True, timeout=15)
        self.ok(r)
        self.assertEqual(self.sleep.read_text(), owner)
        self.assertFalse(self.writes())
        self.assertNotEqual(self.call('boot0-slot.sh', 'boot').returncode, 0)
        self.ok(self.call('boot0-slot.sh', 'ours'))

    def test_zero_read_failure_never_verifies_remove(self):
        for fault in ('FAIL_READ', 'SHORT_READ'):
            with self.subTest(fault=fault):
                self.busy.unlink(missing_ok=True)
                r = self.call('boot0-slot.sh', 'remove', **{fault: '16640'})
                self.assertNotEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertTrue(self.busy.exists())

    def test_rtc_write_failure_retains_quarantine(self):
        r = self.call('boot0-slot.sh', 'remove', FAIL_RTC='0x0700013c')
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(self.busy.exists())

    def test_bad_safety_register_preserves_sleep_flag(self):
        self.ok(self.call('spl/zero-install.sh', str(self.root / 'spl.bin')))
        self.ok(self.call('boot0-slot.sh', 'stock'))
        r = self.call('boot0-slot.sh', 'ours', BAD_RTC_READ='0x07000138')
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(self.flag.exists())
        self.assertTrue(self.sleep.exists())

    def test_picker_refuses_foreign_owner_before_work(self):
        self.busy.write_text('foreign\n')
        self.assertNotEqual(self.call('boardpick.sh').returncode, 0)
        self.assertEqual(self.busy.read_text(), 'foreign\n')
        self.assertFalse(self.writes())

    def test_lock_owner_cannot_release_someone_elses_file(self):
        command = '. "$1"; spl_lock_acquire "$2"; echo foreign > "$2"; exit 0'
        r = subprocess.run([*SHELL, '-c', command, 'lock', str(self.z / 'spl-lock.sh'), str(self.busy)],
                           env=self.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.busy.read_text().strip(), 'foreign')

    def test_signal_during_dirty_transaction_keeps_lock(self):
        command = '. "$1"; spl_lock_acquire "$2"; _spl_lock_dirty=1; kill -TERM $$; exit 0'
        r = subprocess.run([*SHELL, '-c', command, 'lock', str(self.z / 'spl-lock.sh'), str(self.busy)],
                           env=self.env, capture_output=True, text=True, timeout=10)
        self.assertNotEqual(r.returncode, 0)
        self.assertTrue(self.busy.exists())

    def test_missing_helper_refuses_device_actions(self):
        (self.z / 'spl-lock.sh').unlink()
        for name, args in (('boot0-slot.sh', ('stock',)), ('boardpick.sh', ()),
                           ('spl/zero-install.sh', (str(self.root / 'spl.bin'),))):
            self.assertNotEqual(self.call(name, *args).returncode, 0)
        self.assertFalse(self.writes())

    def test_successful_remove(self):
        self.ok(self.call('spl/zero-install.sh', str(self.root / 'spl.bin')))
        self.ok(self.call('boot0-slot.sh', 'remove'))
        self.assertFalse(self.busy.exists())

    def test_contract_query_needs_no_helper(self):
        (self.z / 'spl-lock.sh').unlink()
        self.ok(self.call('boot0-slot.sh', 'stage2-contract'))

    def test_syntax(self):
        for p in self.z.rglob('*.sh'):
            self.ok(subprocess.run([*SHELL, '-n', str(p)], capture_output=True, text=True))


if __name__ == '__main__':
    unittest.main()
