"""Exercise the actual two shell helpers against regular-file hardware fixtures."""
import gzip
import importlib.util
import os
from pathlib import Path
import re
import struct
import subprocess
import tempfile
import time
import unittest

TOOLS = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("analyzer", TOOLS / "h700-device-check.py")
analyzer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(analyzer)
BOOT = "4c3b698d-7dc7-4066-b456-a2bdf3cbd211"


class DeviceCheck(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.z = "/opt/minui-zero/"
        self.c = "/mnt/mmc/"
        self.dt = "/sys/firmware/devicetree/base/chosen/zero,loader"
        self.report = self.root / "report"
        for name, value in {
            "/proc/sys/kernel/random/boot_id": BOOT, "/proc/uptime": "21.4 56.2",
            "/proc/cmdline": "androidboot.serialno=SECRET_SERIAL snum=SECRET_SERIAL lcd_type=old",
            "/sys/block/mmcblk0/device/cid": "SECRET_CID",
            self.c + ".userdata/h700/logs/fast-boot.txt": "2026-01-01 00:00:00 serial SECRET_SERIAL\n",
            self.z + "spl-state": "stage2:auto:h", self.z + "boards/chosen": "rg35xx-h",
            self.c + ".system/h700/board": "h", self.c + ".system/version.txt": "v1.10.1",
            self.z + "rootfs-level": "4", self.z + "loader/build-id": "ab"*32,
            self.z + "boards/rg35xx-h/package.fex": "test-package",
            self.z + "boards/rg35xx-h/kernel": "test.gz",
            self.z + "boards/kernels/test.gz": gzip.compress(b"K"*512),
            self.z + "loader/boot-health": '#!/bin/sh\ncase "$1" in --build-id) echo ' + 'ab'*32
                + ';; *) echo "boot-health: accepted";; esac\n',
            self.dt: struct.pack(">4s7I", b"ZHL1", 1, 64, 2, 0, 640, 480, 0) + bytes.fromhex("ab"*32),
            "/run/zero-menu-frame": "", "/run/zero-display-frame": "v1 boot=" + BOOT + " raw_ns=100",
            "/bin/busybox": '#!/bin/sh\n[ "$1" = devmem ] && [ "$#" = 3 ] || exit 99\necho 0x00000000\n'
        }.items():
            self.put(name, value)
        for exe in (self.z+"loader/boot-health", "/bin/busybox"):
            self.path(exe).chmod(0o755)
        self.spl = bytearray(512)
        self.spl[4:12] = b"eGON.BT0"
        struct.pack_into("<I", self.spl, 16, 512)
        self.spl[20:23] = b"SPL"
        self.stock = bytearray(65536)
        self.stock[4:12] = b"eGON.BT0"
        struct.pack_into("<I", self.stock, 16, 65536)
        struct.pack_into("<I", self.stock, 60, 8)
        loader = b"ZEROLDR1" + struct.pack("<I", 512) + bytes(500)
        self.put(self.z+"spl/zero-spl.bin", self.spl)
        self.put(self.z+"loader/zero-loader.bin", loader)
        for lba, data in ((16,self.spl),(512,self.stock),(16384,self.stock),(16512,self.stock),
                          (16641,b"SECRET_BIND"),(16768,self.spl),(16896,loader),
                          (24576,b"test-package"),(32800,b"test-package"),(188416,b"K"*512)):
            self.block(lba, data)
        self.path("/tmp").mkdir()

    def path(self, p):
        return self.root / p.lstrip("/")

    def put(self, name, data):
        p = self.path(name)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data.encode() if isinstance(data, str) else data)

    def block(self, lba, data):
        dev = self.path("/dev/mmcblk0")
        dev.parent.mkdir(exist_ok=True)
        with dev.open("r+b" if dev.exists() else "w+b") as f:
            f.seek(lba*512); f.write(data)

    def run_script(self, name, *args):
        source = (TOOLS/"h700-strip"/name).read_text()
        source = re.sub(r"/(?:opt/minui-zero|mnt/mmc|dev/mmcblk0|proc/|sys/|run/|tmp/)",
                        lambda m: str(self.root) + m[0], source)
        subprocess.run(["sh", "-eu", "-c", source, "fixture", *args], check=True,
                       env=dict(os.environ, PATH=str(self.root/"bin")+":"+os.environ["PATH"]))

    def collect(self, *args):
        self.run_script("boot-evidence.sh", *args, str(self.report))
        return analyzer.analyze(self.report)

    def test_private_by_default_and_complete_run(self):
        result = self.collect()
        self.assertEqual(result["verdict"], "PASS", result)
        self.assertEqual(result["installed"], "stage2")
        self.assertNotIn(b"SECRET", b"".join(p.read_bytes() for p in self.report.iterdir()))
        statuses = (self.report/"status.tsv").read_text()
        self.assertIn("zero-menu-frame-end\tempty", statuses)
        self.assertIn("off-end\tabsent", statuses)
        for name, data, field, expected in (
                ("expected-id", "00"*32, "verdict", "FAIL"),
                ("frame", f"v1 boot={BOOT} raw_ns=0", "verdict", "UNKNOWN"),
                ("boot-id-end", "different", "verdict", "UNKNOWN")):
            p = self.report/name
            old = p.read_bytes(); p.write_text(data)
            try:
                self.assertEqual(analyzer.analyze(self.report)[field], expected)
            finally:
                p.write_bytes(old)

    def test_opt_in_privacy(self):
        self.collect("--include-identifiers")
        self.assertIn(b"SECRET_BIND", (self.report/"binding.bin").read_bytes())
        self.assertIn("SECRET_CID", (self.report/"cid").read_text())
        self.assertIn("SECRET_SERIAL", (self.report/"policy-log").read_text())

    def test_charger_is_not_failure(self):
        self.path(self.dt).unlink()
        self.put("/run/zero-stage2-charger", "")
        result = self.collect()
        self.assertEqual((result["verdict"], result["ran_this_boot"]), ("PENDING", "vendor"))

    def test_optout_applies_to_next_boot(self):
        for lba, data in ((16,self.stock),(16768,bytes(512)),(16896,bytes(512))):
            self.block(lba, data)
        self.put(self.c+"fast-boot-off.txt", "")
        self.put(self.z+"spl-state", "off")
        result = self.collect()
        self.assertEqual((result["verdict"],result["ran_this_boot"],result["opt_out"]),
                         ("PASS","stage2","applied for next start"))

    def test_preack_published_without_mutating_attempt(self):
        self.put("/proc/mounts", f"{self.path('/dev/mmcblk0')}p6 {self.path('/mnt/mmc')} vfat rw 0 0\n")
        self.block(16640, b"ZERO-ATTEMPT-V1")
        base = self.path(self.c+".userdata/h700/logs/stage2-receipts")
        origin = base / ("a"*36)
        (origin/"provisioned").mkdir(parents=True)
        (base/"current").write_text(origin.name)
        self.run_script("boot-preack.sh")
        p = self.path(self.c+".userdata/h700/logs/boot-preack.txt")
        for _ in range(100):
            if p.exists():
                break
            time.sleep(.02)
        self.assertEqual(p.read_bytes(), self.path("/run/zero-boot-preack").read_bytes())
        self.assertIn("attempt=pending", p.read_text())
        with self.path("/dev/mmcblk0").open("rb") as f:
            f.seek(16640*512)
            self.assertEqual(f.read(15), b"ZERO-ATTEMPT-V1")
        first = origin/"first-return"
        for _ in range(100):
            if first.exists():
                break
            time.sleep(.02)
        self.assertEqual((first/f"preack-{BOOT}.txt").read_bytes(), p.read_bytes())
        self.assertEqual((first/f"loader-{BOOT}.bin").read_bytes(), self.path(self.dt).read_bytes())
        self.path("/run/zero-boot-preack").unlink()
        self.put("/proc/sys/kernel/random/boot_id", "b"*36)
        self.path(self.dt).unlink()
        self.run_script("boot-preack.sh")
        for _ in range(100):
            if "b"*36 in p.read_text():
                break
            time.sleep(.02)
        self.assertIn("b"*36, p.read_text())
        self.assertEqual(sorted(x.name for x in first.iterdir()), [f"loader-{BOOT}.bin", f"preack-{BOOT}.txt"])
