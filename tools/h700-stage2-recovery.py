#!/usr/bin/env python3
"""Stage one attended Plus fatal-recovery trial; default is read-only and local.

There is deliberately no SSH transport. Printed device commands are a reviewable
handoff, not deployment approval. --execute operates ONLY on a regular-file image.
Shared helpers validate saved admission, recovery proof and cleanup before staging.
"""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import stat
import struct
import subprocess
import tempfile


SECTOR = 512
ZERO = bytes(SECTOR)
FATAL_MARK = 0x5A56004E
REGIONS = {"slot16.bin": (16, 128), "slot512.bin": (512, 128),
           "pinA.bin": (16384, 128), "pinB.bin": (16512, 128),
           "attempt.bin": (16640, 1), "binding.bin": (16641, 1),
           "store.bin": (16768, 96)}
LOADER = 16896
REPO = Path(__file__).resolve().parents[1]
SHIPPING = {"installer": "workspace/h700/spl/zero-install.sh",
            "spl_auto": "tools/h700-strip/spl-auto.sh",
            "boot0_slot": "tools/h700-strip/boot0-slot.sh"}
ROLES = ("spl", "normal", "fatal", *SHIPPING)
REBOOT_RECIPE = (
    "set -eu; echo performance > /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor; sleep 1; "
    "busybox devmem 0x030090b4 32 1; busybox devmem 0x030090b8 32 0x71; "
    "busybox devmem 0x030090b0 32 0x14af; sync; reboot -f"
)


class Refusal(RuntimeError):
    pass


def require(ok, message):
    if not ok:
        raise Refusal(message)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def regular_open(path, writable=False):
    fd = os.open(path, (os.O_RDWR if writable else os.O_RDONLY) | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(stat.S_ISREG(os.fstat(fd).st_mode), "regular files only; no devices/pipes")
        return os.fdopen(fd, "r+b" if writable else "rb", buffering=0)
    except BaseException:
        os.close(fd)
        raise


def read_file(path):
    with regular_open(path) as stream:
        return stream.read()


def u32(data, offset):
    require(offset + 4 <= len(data), "short word")
    return struct.unpack_from("<I", data, offset)[0]


def checksum(data, offset):
    require(len(data) % 4 == 0, "unaligned checksum")
    words = list(struct.unpack("<%dI" % (len(data) // 4), data))
    words[offset // 4] = 0x5F0A6C39
    return sum(words) & 0xFFFFFFFF


def egon(data, stock=False):
    require(len(data) >= 512 and len(data) % 512 == 0, "bad eGON size")
    require(data[4:12] == b"eGON.BT0" and u32(data, 16) == len(data), "bad eGON header")
    require(u32(data, 12) == checksum(data, 12), "bad eGON checksum")
    if stock:
        require(len(data) == 65536 and data[20:23] != b"SPL", "not valid stock boot0")
    else:
        require(len(data) <= 49152 and data[20:23] == b"SPL", "not a bounded SPL")
        require(b"zero: vendor hand-off" in data and b"zero: dram lp4" in data
                and b"zero: dram lp3" not in data, "not the Plus LPDDR4 Zero SPL")


def loader(data):
    require(512 <= len(data) <= 983040 and len(data) % 512 == 0, "bad loader length")
    require(data[:8] == b"ZEROLDR1" and u32(data, 8) == len(data)
            and u32(data, 12) == 64 and u32(data, 20) == 2, "not a v2 loader")
    require(64 <= u32(data, 24) <= len(data) - 4 and u32(data, 24) % 4 == 0,
            "bad preflight entry")
    require(data[28:64] == bytes(36) and u32(data, 16) == checksum(data, 16),
            "bad loader reserved words/checksum")


class Cohort:
    """The operator's SHA-sealed saved cohort, not a built-in card identity."""

    def __init__(self, manifest):
        self.path = Path(manifest).resolve()
        encoded = read_file(self.path)
        self.digest = sha(encoded)
        self.manifest = json.loads(encoded)
        require(self.manifest["board"] == "plus", "cohort must be Plus")
        self.saved = {name: self.entry(self.manifest["files"][name], name)
                      for name in (*REGIONS, "card.txt", "cmdline.txt")}
        self.config = self.manifest["recovery"]
        self.artifacts = {role: self.entry(self.config["artifacts"][role]) for role in ROLES}
        self.cid = self.saved["card.txt"].decode().strip()
        require(re.fullmatch(r"[0-9a-f]{32}", self.cid) and int(self.cid, 16) != 0,
                "missing known card CID")
        serials = re.findall(r"(?:^|\s)androidboot.serialno=([0-9a-f]{19})(?=\s|$)",
                             self.saved["cmdline.txt"].decode())
        require(len(serials) == 1 and int(serials[0], 16) != 0, "missing unique serial")
        self.serial = serials[0]
        for name, (_, count) in REGIONS.items():
            require(len(self.saved[name]) == count * SECTOR, "wrong cohort region size: " + name)
        for name in ("slot512.bin", "pinA.bin", "pinB.bin"):
            egon(self.saved[name], stock=True)
        self.pin = self.saved["pinA.bin"]
        require(self.pin == self.saved["pinB.bin"] == self.saved["slot512.bin"],
                "full stock512/pins must be identical")
        require(u32(self.pin, 60) == 8, "Plus LPDDR4 only")
        require(self.saved["attempt.bin"] == ZERO, "cohort attempt is not zero")
        binding = (b"ZERO-BIND-V1" + bytes(4)
                   + struct.pack("<4I", int(self.serial[:3], 16), int(self.serial[3:11], 16),
                                 int(self.serial[11:], 16), 0)
                   + self.pin[56:184] + bytes(352))
        require(self.saved["binding.bin"] == binding, "binding does not describe cohort serial/pin")
        self.spl = self.artifacts["spl"]
        egon(self.spl)
        require(self.saved["slot16.bin"][:len(self.spl)] == self.spl
                and self.saved["store.bin"][:len(self.spl)] == self.spl,
                "cohort primary/store are not the exact approved SPL")
        for role in ("normal", "fatal"):
            loader(self.artifacts[role])
        require(self.artifacts["normal"] != self.artifacts["fatal"], "normal cannot be fatal")
        for role, path in SHIPPING.items():
            require(self.artifacts[role] == read_file(REPO / path), "shipping helper moved: " + role)
        self.trained = None
        if "trained_stock" in self.config:
            self.trained = self.entry(self.config["trained_stock"]["file"])
            self.stock_equivalent(self.trained)

    def entry(self, entry, default=None):
        path = entry.get("path", default)
        require(isinstance(path, str), "artifact needs a path")
        path = Path(path)
        data = read_file(path if path.is_absolute() else self.path.parent / path)
        require(type(entry["bytes"]) is int and len(data) == entry["bytes"]
                and sha(data) == entry["sha256"], "sealed file mismatch: " + str(path))
        return data

    def stock_equivalent(self, data):
        egon(data, stock=True)
        if data == self.pin:
            return []
        # No blanket DRAM/checksum mask: every changed DRAM word must be explicitly
        # explained and tied to a saved, independently sealed write-back capture.
        info = self.config.get("trained_stock", {})
        require(bool(info.get("evidence")), "unaccounted stock training write-back")
        changes = []
        for offset in range(0, len(data), 4):
            before, after = u32(self.pin, offset), u32(data, offset)
            if before != after and offset != 12:
                require(56 <= offset < 184, "stock code/non-DRAM bytes changed")
                changes.append({"offset": offset, "before": before, "after": after})
        require(bool(changes) and changes == info.get("changes"), "unlisted training word change")
        if self.trained is not None:
            require(data == self.trained, "stock differs from sealed trained capture")
        return changes

    def shipping_check(self):
        """Run the CURRENT installer's real host --check, never its device branch."""
        with tempfile.TemporaryDirectory(prefix="h700-recovery-check-") as directory:
            root = Path(directory)
            for name, data in (("stock", self.pin), ("spl", self.spl),
                               ("installer", self.artifacts["installer"])):
                (root / name).write_bytes(data)
            result = subprocess.run(["sh", str(root / "installer"), "--check", str(root / "stock"),
                                     str(root / "spl"), self.serial, str(root / "binding")],
                                    capture_output=True, timeout=10, check=False,
                                    env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LC_ALL": "C"})
            require(result.returncode == 0 and result.stdout.strip() == b"0",
                    "shipping installer --check refused: " + result.stdout.decode(errors="replace"))
            require(read_file(root / "binding") == self.saved["binding.bin"], "shipping binding differs")


def register(status, name):
    value = status[name]
    require(type(value) is int or isinstance(value, str), "invalid register " + name)
    value = int(value, 0) if isinstance(value, str) else value
    require(0 <= value <= 0xFFFFFFFF, "invalid register " + name)
    return value


def guard(cohort, status, recovery=False):
    require(status["board"] == "plus" and status["card"] == cohort.cid, "wrong Plus/card")
    require(type(status["capacity"]) is int and 50 < status["capacity"] <= 100, "battery must exceed 50")
    require(status["menu"] is True and status["emu"] == "", "idle menu/no core required")
    require(bool(status["boot_id"]), "missing boot ID")
    for name in ("gp5", "gp15", "wdt_mode"):
        require(register(status, name) == 0, "pending RTC/WDT: " + name)
    require(register(status, "gp14") == (FATAL_MARK if recovery else 0), "unexpected GP14")
    register(status, "gp13")
    background = status["background"]
    require(background["spl_state"] == "failed" and background["busy"] is False
            and background["sleep_swap"] is False and background["actors"] == [],
            "background rearm/sleep/ack/kit guard not quiescent")
    for role in ("spl_auto", "boot0_slot"):
        require(background[role + "_sha256"] == sha(cohort.artifacts[role]), "installed helper mismatch")


class Image:
    def __init__(self, path, execute=False):
        self.stream = regular_open(path, execute)
        self.execute = execute
        try:
            if execute:
                fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            require(os.fstat(self.stream.fileno()).st_size >= (LOADER + 1920) * SECTOR,
                    "image too short")
        except BaseException:
            self.stream.close()
            raise

    def close(self):
        self.stream.close()

    def read(self, lba, count):
        data = os.pread(self.stream.fileno(), count * SECTOR, lba * SECTOR)
        require(len(data) == count * SECTOR, "short image read")
        return data

    def write(self, label, lba, data):
        require(self.execute, "--execute required before any write")
        require(lba >= 0 and len(data) % SECTOR == 0 and len(data) > 0, "bad write range")
        require(os.pwrite(self.stream.fileno(), data, lba * SECTOR) == len(data), "short write: " + label)
        os.fsync(self.stream.fileno())


def checked_write(image, label, lba, data):
    image.write(label, lba, data)
    require(image.read(lba, len(data) // SECTOR) == data, "readback failed: " + label)


def preserved(cohort, image, recovered=False):
    names = ("pinA.bin", "pinB.bin", "binding.bin", "store.bin", "attempt.bin")
    if not recovered:
        names += ("slot512.bin",)
    for name in names:
        lba, count = REGIONS[name]
        require(image.read(lba, count) == cohort.saved[name], "cohort region changed: " + name)


def admission(cohort, image, status):
    guard(cohort, status)
    preserved(cohort, image)
    require(image.read(16, 128) == cohort.saved["slot16.bin"], "current primary SPL changed")
    header = image.read(LOADER, 1)
    if header != ZERO:
        normal = cohort.artifacts["normal"]
        require(image.read(LOADER, len(normal) // SECTOR) == normal,
                "loader must be OFF or the manifest's verified normal; fatal requires cleanup")


def install_writes(cohort):
    fatal, spl = cohort.artifacts["fatal"], cohort.spl
    return [("pin-a", 16384, cohort.pin), ("pin-b", 16512, cohort.pin),
            ("attempt", 16640, ZERO), ("store", 16768, spl),
            ("binding", 16641, cohort.saved["binding.bin"]),
            ("header-off", LOADER, ZERO), ("loader-body", LOADER + 1, fatal[SECTOR:]),
            ("loader-header", LOADER, fatal[:SECTOR]),
            ("primary-body", 17, spl[SECTOR:]), ("primary-header", 16, spl[:SECTOR])]


def install_fatal(cohort, image, status):
    admission(cohort, image, status)
    for label, lba, data in install_writes(cohort):
        checked_write(image, label, lba, data)
    preserved(cohort, image)
    require(image.read(16, len(cohort.spl) // SECTOR) == cohort.spl, "final primary mismatch")
    fatal = cohort.artifacts["fatal"]
    require(image.read(LOADER, len(fatal) // SECTOR) == fatal, "final fatal image mismatch")


def proof(cohort, image, status):
    guard(cohort, status, recovery=True)
    receipt = status["return"]
    require(receipt["before_boot_id"] != status["boot_id"] and bool(receipt["before_boot_id"]),
            "no new boot")
    elapsed = receipt["elapsed_seconds"]
    require(type(elapsed) in (int, float) and 0 < elapsed <= 180, "return exceeded 180s: STOP, no retry")
    require(register(status, "gp13") == 0x02A8C034,
            "need exactly two SPL starts, LP4 validated/PMIC-ok record, restore crumb 34")
    preserved(cohort, image, recovered=True)
    primary, backup = image.read(16, 128), image.read(512, 128)
    changes = cohort.stock_equivalent(primary)
    cohort.stock_equivalent(backup)
    require(primary == backup, "primary and backup stock differ; backup fallback is not proof")
    header = image.read(LOADER, 1)
    if header != ZERO:
        fatal = cohort.artifacts["fatal"]
        require(image.read(LOADER, len(fatal) // SECTOR) == fatal, "unknown retained loader")
    return {"fatal_gp14": hex(FATAL_MARK), "stock_sha256": sha(primary),
            "training_changes": changes, "header_off": header == ZERO,
            "rearm_allowed": False, "physical_recovery_proven_by_host": False}


def cleanup(cohort, image, status):
    evidence = proof(cohort, image, status)
    before = {name: image.read(*location) for name, location in REGIONS.items()}
    checked_write(image, "cleanup-header-off", LOADER, ZERO)
    for name, data in before.items():
        require(image.read(*REGIONS[name]) == data, "cleanup changed protected region: " + name)
    require(image.read(LOADER, 1) == ZERO, "cleanup header not zero")
    evidence["header_off"] = True
    return evidence


def device_commands(cohort, status, action):
    """Emit only: the owner must review and run these at an attended manual gate."""
    q = shlex.quote
    recovering = action in ("prove", "cleanup")
    guard(cohort, status, recovery=recovering)
    if action == "guarded-reboot":
        require(register(status, "gp13") == 0, "installer RTC reset not verified before reboot")
    lines = ["set -eu", "D=/dev/mmcblk0", "T=/tmp/zero-stage2-recovery",
             "R=/opt/minui-zero/stage2-fatal-once-" + cohort.digest,
             "rd() { dd if=$D bs=512 skip=$1 count=$2 iflag=direct 2>/dev/null; }",
             "hashis() { test \"$(sha256sum | cut -d' ' -f1)\" = \"$1\"; }",
             "regis() { v=$(busybox devmem \"$1\") || return 1; case \"$v\" in "
             "0x[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]) "
             "test \"$((v))\" -eq \"$2\" ;; *) return 1 ;; esac; }",
             "test \"$(cat /mnt/mmc/.system/h700/board)\" = plus",
             "test \"$(cat /sys/block/mmcblk0/device/cid)\" = " + q(cohort.cid),
             "b=$(cat /sys/class/power_supply/axp2202-battery/capacity); test \"$b\" -gt 50; test \"$b\" -le 100",
             "test -e /run/zero-menu-frame; test -z \"$(pidof minarch.elf || :)\"",
             "test ! -e /opt/minui-zero/.spl-sleep-swapped; test ! -e /run/zero-spl-busy",
             "test \"$(cat /opt/minui-zero/spl-state)\" = failed",
             "for p in /proc/[0-9]*/cmdline; do",
             "  c=$(tr '\\000' ' ' < \"$p\" 2>/dev/null || :)",
             "  case \"$c\" in *spl-auto.sh*|*boot0-slot.sh*|*gp-mark-stage2.sh*|*zero-s2-dog*) echo 'STOP: background actor'; exit 1;; esac",
             "done"]
    for role, destination in (("spl_auto", "/opt/minui-zero/spl-auto.sh"),
                              ("boot0_slot", "/opt/minui-zero/boot0-slot.sh")):
        lines.append("hashis " + sha(cohort.artifacts[role]) + " < " + destination)
    for address, name in ((0x07000114, "gp5"), (0x07000134, "gp13"),
                          (0x07000138, "gp14"), (0x0700013C, "gp15"), (0x030090B8, "wdt_mode")):
        expected = register(status, name) if name == "gp13" else 0
        if recovering and name == "gp14":
            expected = FATAL_MARK
        lines.append("regis %s %s" % (hex(address), expected))
    for name, location in REGIONS.items():
        if name in ("slot16.bin", "slot512.bin") and recovering:
            data = cohort.trained if cohort.trained is not None else cohort.pin
        else:
            data = cohort.saved[name]
        lines.append("rd %d %d | hashis %s" % (*location, sha(data)))
    fatal, normal = cohort.artifacts["fatal"], cohort.artifacts["normal"]
    if action in ("prepare", "install-fatal"):
        lines.append("if rd 16896 1 | hashis %s; then :; else rd 16896 %d | hashis %s; fi" %
                     (sha(ZERO), len(normal) // 512, sha(normal)))
    elif action == "guarded-reboot":
        lines.append("rd 16896 %d | hashis %s" % (len(fatal) // 512, sha(fatal)))
    else:
        lines.append("if rd 16896 1 | hashis %s; then :; else rd 16896 %d | hashis %s; fi" %
                     (sha(ZERO), len(fatal) // 512, sha(fatal)))
    if action == "install-fatal":
        lines.append("test ! -e \"$R\"   # a consumed trial never installs again")
        for role in ("installer", "spl", "fatal"):
            lines.append("hashis %s < $T/%s" % (sha(cohort.artifacts[role]), role))
        lines += ["( set -C; : > /run/zero-spl-busy )", "sync",
                  "ZERO_SPL_TRIAL= ZERO_SPL_KEYTEST= ZERO_STAGE2_TRIAL= sh $T/installer $T/spl $T/fatal",
                  "rd 16 %d | hashis %s" % (len(cohort.spl) // 512, sha(cohort.spl)),
                  "rd 16896 %d | hashis %s" % (len(fatal) // 512, sha(fatal))]
        for name in ("slot512.bin", "pinA.bin", "pinB.bin", "attempt.bin", "binding.bin", "store.bin"):
            lines.append("rd %d %d | hashis %s" % (*REGIONS[name], sha(cohort.saved[name])))
        for address in (0x07000134, 0x07000138, 0x0700013C):
            lines.append("regis %s 0" % hex(address))
        lines += ["rm /run/zero-spl-busy", "sync"]
    elif action == "cleanup":
        lines += ["( set -C; : > /run/zero-spl-busy )", "sync",
                  "dd if=/dev/zero of=$D bs=512 seek=16896 count=1 conv=notrunc,fsync",
                  "rd 16896 1 | hashis " + sha(ZERO)]
        for name, location in REGIONS.items():
            data = (cohort.trained if cohort.trained is not None else cohort.pin) if name in (
                "slot16.bin", "slot512.bin") else cohort.saved[name]
            lines.append("rd %d %d | hashis %s" % (*location, sha(data)))
        lines += ["rm /run/zero-spl-busy", "sync"]
    elif action == "guarded-reboot":
        lines += ["# Atomic durable token: never remove it to retry this trial.",
                  "mkdir \"$R\"; sync; test -d \"$R\"",
                  "cat /proc/sys/kernel/random/boot_id > \"$R/boot-id\"",
                  "cat /proc/uptime > \"$R/start-uptime\"; sync",
                  "test \"$(cat \"$R/boot-id\")\" = \"$(cat /proc/sys/kernel/random/boot_id)\"",
                  "# ONE invocation only. Owner must record boot ID/start time externally first.",
                  "# Observe a new boot/menu for at most 180s, then STOP; never resend reboot.", REBOOT_RECIPE]
    lines.append("# STOP. Capture all output, raw regions and RTC; no retries or automatic rearm.")
    return "\n".join(lines) + "\n"


def journal_write(path, value, exclusive=False):
    flags = os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK | (os.O_CREAT | os.O_EXCL if exclusive else 0)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w") as stream:
        require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "journal must be a regular file")
        os.ftruncate(stream.fileno(), 0)
        json.dump(value, stream, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    directory = os.open(Path(path).parent, os.O_RDONLY)
    try:
        os.fsync(directory)
    finally:
        os.close(directory)


def run(args):
    require(args.target is None or not args.execute,
            "STOP: no reviewed remote executor; SSH/reboot is an attended manual gate")
    cohort = Cohort(args.manifest)
    if args.manifest_sha256 is not None:
        require(re.fullmatch(r"[0-9a-f]{64}", args.manifest_sha256)
                and args.manifest_sha256 == cohort.digest, "frozen manifest digest mismatch")
    require(not args.execute or args.manifest_sha256 == cohort.digest,
            "--manifest-sha256 approval required before local execution")
    status = json.loads(read_file(args.status))
    image = Image(args.image, args.execute)
    try:
        if args.action in ("prove", "cleanup"):
            result = proof(cohort, image, status)
        elif args.action == "guarded-reboot":
            guard(cohort, status)
            require(register(status, "gp13") == 0, "installer RTC reset not verified before reboot")
            preserved(cohort, image)
            require(image.read(16, 128) == cohort.saved["slot16.bin"], "primary changed")
            fatal = cohort.artifacts["fatal"]
            require(image.read(LOADER, len(fatal) // 512) == fatal, "fatal not installed")
            result = {"maximum_return_seconds": 180, "retry": False}
        else:
            admission(cohort, image, status)
            result = {"cohort_verified": True}
        result.update(action=args.action, execute=args.execute, local_only=True,
                      manifest_sha256=cohort.digest, rearm_allowed=False,
                      manual_gate="No SSH executed. Fresh attended identity/cohort checks, single-use reboot receipt and <=180s return remain the owner's gate.")
        if args.execute:
            require(args.action in ("prepare", "install-fatal", "cleanup"),
                    "no local reboot or fabricated recovery proof execution")
            cohort.shipping_check()
            if args.action in ("install-fatal", "cleanup"):
                require(args.journal is not None, "--journal required for mutations")
                if args.action == "install-fatal":
                    journal_write(args.journal, {"phase": "install-started", "cohort": cohort.digest}, True)
                else:
                    previous = json.loads(read_file(args.journal))
                    require(previous["cohort"] == cohort.digest, "journal/cohort mismatch")
                    require(previous["phase"] in ("installed", "cleaned", "STOP"), "incomplete install: STOP")
                    journal_write(args.journal, {"phase": "cleanup-started", "cohort": cohort.digest})
                try:
                    if args.action == "install-fatal":
                        install_fatal(cohort, image, status)
                    else:
                        result.update(cleanup(cohort, image, status))
                except BaseException:
                    journal_write(args.journal, {"phase": "STOP", "cohort": cohort.digest})
                    raise
                journal_write(args.journal, {"phase": "installed" if args.action == "install-fatal" else "cleaned",
                                             "cohort": cohort.digest})
        result["device_commands_review_only"] = device_commands(cohort, status, args.action)
        return result
    finally:
        image.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("prepare", "install-fatal", "guarded-reboot", "prove", "cleanup"))
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--manifest-sha256", help="operator-approved frozen manifest digest; required with --execute")
    parser.add_argument("--image", required=True, type=Path, help="saved regular-file disk image; never a device")
    parser.add_argument("--status", required=True, type=Path, help="operator's saved status JSON")
    parser.add_argument("--execute", action="store_true", help="allow local-image writes only")
    parser.add_argument("--journal", type=Path, help="exclusive single-trial local transaction journal")
    parser.add_argument("--target", help="label for manual handoff only; --execute refuses any target")
    args = parser.parse_args(argv)
    try:
        print(json.dumps(run(args), indent=2))
        return 0
    except (Refusal, OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        print("STOP: %s; no retry/rearm. Inspect evidence before any further action." % error)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
