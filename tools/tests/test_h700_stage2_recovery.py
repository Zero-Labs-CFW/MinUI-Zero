"""Host-only decisions AND real regular-file I/O; no SSH/device dependencies."""

import argparse
import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile
import unittest
from unittest.mock import patch


TOOL = Path(__file__).resolve().parents[1] / "h700-stage2-recovery.py"
spec = importlib.util.spec_from_file_location("h700_recovery", TOOL)
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


def egon_image(stock=False):
    data = bytearray(65536 if stock else 1024)
    data[4:12] = b"eGON.BT0"
    struct.pack_into("<I", data, 16, len(data))
    if stock:
        words = [672, 8, 134744072, 235802126, 3598, 2022161339, 12538, 67108864,
                 0, 52, 27, 51, 3, 0, 0, 4, 114, 0, 9, 0, 0, 36,
                 0, 0, 1, 0, 1015054464, 1076848179, 454958618, 101123846, 33590368, 0]
        struct.pack_into("<32I", data, 56, *words)
    else:
        data[20:23] = b"SPL"
        marker = b"zero: vendor hand-off\0zero: dram lp4\0"
        data[256:256 + len(marker)] = marker
    struct.pack_into("<I", data, 12, r.checksum(data, 12))
    return bytes(data)


def loader_image(fatal=False):
    data = bytearray(1024)
    data[:8] = b"ZEROLDR1"
    struct.pack_into("<5I", data, 8, len(data), 64, 0, 2, 64)
    data[512] = 78 if fatal else 65
    struct.pack_into("<I", data, 16, r.checksum(data, 16))
    return bytes(data)


class FaultImage(r.Image):
    def __init__(self, path, fail_write=None, bad_readback=None, fail_read=None, partial=False):
        super().__init__(path, execute=True)
        self.fail_write = fail_write
        self.bad_readback = bad_readback
        self.fail_read = fail_read
        self.partial = partial
        self.labels = []
        self.pending = None
        self.read_count = 0

    def write(self, label, lba, data):
        self.labels.append(label)
        if label == self.fail_write:
            if self.partial:
                os.pwrite(self.stream.fileno(), data[:len(data) // 2], lba * 512)
                os.fsync(self.stream.fileno())
            raise OSError("injected write failure: " + label)
        super().write(label, lba, data)
        self.pending = label

    def read(self, lba, count):
        self.read_count += 1
        if self.read_count == self.fail_read:
            raise OSError("injected read failure")
        data = super().read(lba, count)
        pending, self.pending = self.pending, None
        if pending == self.bad_readback and pending is not None:
            return bytes([data[0] ^ 1]) + data[1:]
        return data


class RecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="h700-recovery-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.image_path = self.root / "card.img"
        self.manifest_path = self.root / "manifest.json"
        self.status_path = self.root / "status.json"
        self.journal = self.root / "trial.json"
        self.pin = egon_image(stock=True)
        self.spl = egon_image()
        self.fatal = loader_image(True)
        self.normal = loader_image()
        self.cid = "1234567890abcdef1234567890abcdef"
        self.serial = "1234567890abcdef123"
        self.binding = (b"ZERO-BIND-V1" + bytes(4)
                        + struct.pack("<4I", int(self.serial[:3], 16), int(self.serial[3:11], 16),
                                      int(self.serial[11:], 16), 0) + self.pin[56:184] + bytes(352))
        self.saved = {"slot16.bin": self.spl + bytes(65536 - len(self.spl)),
                      "slot512.bin": self.pin, "pinA.bin": self.pin, "pinB.bin": self.pin,
                      "attempt.bin": r.ZERO, "binding.bin": self.binding,
                      "store.bin": self.spl + bytes(49152 - len(self.spl)),
                      "card.txt": (self.cid + "\n").encode(),
                      "cmdline.txt": ("console=ttyS0 androidboot.serialno=" + self.serial + "\n").encode()}
        self.artifacts = {"spl": self.spl, "fatal": self.fatal, "normal": self.normal,
                          **{role: (r.REPO / path).read_bytes() for role, path in r.SHIPPING.items()}}
        self.manifest = {"board": "plus", "files": {}, "recovery": {"artifacts": {}}}
        for name, data in self.saved.items():
            self.manifest["files"][name] = self.seal(name, data)
        for name, data in self.artifacts.items():
            self.manifest["recovery"]["artifacts"][name] = self.seal("artifact-" + name, data)
        self.save_manifest()
        self.cohort = r.Cohort(self.manifest_path)
        self.status = {"board": "plus", "card": self.cid, "capacity": 75,
                       "menu": True, "emu": "", "boot_id": "before-boot",
                       "gp5": 0, "gp13": 0x01A8C040, "gp14": 0, "gp15": 0, "wdt_mode": 0,
                       "background": {"spl_state": "failed", "busy": False, "sleep_swap": False,
                                      "actors": [], **{role + "_sha256": r.sha(self.artifacts[role])
                                                       for role in ("spl_auto", "boot0_slot")}}}
        self.reset_image()

    def seal(self, name, data):
        (self.root / name).write_bytes(data)
        return {"path": name, "bytes": len(data), "sha256": r.sha(data)}

    def save_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest))

    def reset_image(self):
        with self.image_path.open("wb") as stream:
            stream.truncate(20000 * 512)
            for name, (lba, _) in r.REGIONS.items():
                stream.seek(lba * 512)
                stream.write(self.saved[name])
            stream.seek(19000 * 512)
            stream.write(b"USER ROM AND SAVE SENTINEL" * 200)

    @contextlib.contextmanager
    def image(self, **kwargs):
        image = FaultImage(self.image_path, **kwargs)
        try:
            yield image
        finally:
            image.close()

    def recovered(self, header=None, stock=None):
        # Test fixture ONLY: represents externally captured autonomous restoration;
        # production has no method that manufactures this evidence or edits GP14.
        with self.image() as image:
            image.write("test-restore-primary", 16, stock or self.pin)
            image.write("test-restore-backup", 512, stock or self.pin)
            image.write("test-retained-loader", r.LOADER, self.fatal if header is None else header)
        status = copy.deepcopy(self.status)
        status.update(boot_id="returned-boot", gp13=0x02A8C034, gp14=r.FATAL_MARK,
                      return_ignored=False)
        status["return"] = {"before_boot_id": "before-boot", "elapsed_seconds": 12.5}
        return status

    def args(self, action, execute=False):
        self.status_path.write_text(json.dumps(self.status))
        return argparse.Namespace(action=action, execute=execute, target=None,
                                  manifest=self.manifest_path, manifest_sha256=self.cohort.digest if execute else None,
                                  image=self.image_path,
                                  status=self.status_path, journal=self.journal)

    def test_real_shipping_installer_host_branch(self):
        self.cohort.shipping_check()
        bad = bytearray(self.cohort.pin)
        struct.pack_into("<I", bad, 56, 999)
        self.cohort.pin = bytes(bad)
        with self.assertRaisesRegex(r.Refusal, "shipping installer --check refused"):
            self.cohort.shipping_check()

    def test_manifest_and_current_shipping_identity(self):
        for role in r.ROLES:
            with self.subTest(role=role):
                path = self.root / ("artifact-" + role)
                old = path.read_bytes()
                path.write_bytes(old + b"x")
                with self.assertRaisesRegex(r.Refusal, "sealed file mismatch"):
                    r.Cohort(self.manifest_path)
                path.write_bytes(old)
        old = self.manifest["recovery"]["artifacts"]["installer"]
        self.manifest["recovery"]["artifacts"]["installer"] = self.seal("wrong-installer", b"exit 0\n")
        self.save_manifest()
        with self.assertRaisesRegex(r.Refusal, "shipping helper moved"):
            r.Cohort(self.manifest_path)
        self.manifest["recovery"]["artifacts"]["installer"] = old

    def test_identity_idle_battery_rtc_and_background_refusals(self):
        cases = [("board", "h"), ("card", "0" * 32), ("capacity", 50), ("capacity", 101),
                 ("capacity", "75"), ("menu", False), ("emu", "1234"), ("boot_id", ""),
                 ("gp5", 1), ("gp14", r.FATAL_MARK), ("gp15", 1), ("wdt_mode", 0x71)]
        for key, value in cases:
            with self.subTest(key=key, value=value), self.image() as image:
                state = copy.deepcopy(self.status)
                state[key] = value
                with self.assertRaises(r.Refusal):
                    r.install_fatal(self.cohort, image, state)
                self.assertEqual(image.labels, [])
        for key, value in [("spl_state", "installed"), ("busy", True), ("sleep_swap", True),
                           ("actors", ["spl-auto.sh"]), ("spl_auto_sha256", "unknown"),
                           ("boot0_slot_sha256", "unknown")]:
            with self.subTest(background=key), self.image() as image:
                state = copy.deepcopy(self.status)
                state["background"][key] = value
                with self.assertRaises(r.Refusal):
                    r.install_fatal(self.cohort, image, state)
                self.assertEqual(image.labels, [])

    def test_each_cohort_region_and_unknown_or_fatal_header_refuses(self):
        for name, (lba, _) in r.REGIONS.items():
            with self.subTest(name=name):
                self.reset_image()
                with self.image() as image:
                    os.pwrite(image.stream.fileno(), b"?", lba * 512)
                    with self.assertRaises(r.Refusal):
                        r.install_fatal(self.cohort, image, self.status)
                    self.assertEqual(image.labels, [])
        for header in (self.fatal, b"?" * 512, loader_image()[:-1] + b"?"):
            self.reset_image()
            with self.image() as image:
                os.pwrite(image.stream.fileno(), header, r.LOADER * 512)
                with self.assertRaisesRegex(r.Refusal, "OFF or"):
                    r.install_fatal(self.cohort, image, self.status)
                self.assertEqual(image.labels, [])

    def test_install_regular_image_exact_effects_and_normal_header(self):
        with self.image() as image:
            image.write("seed-normal", r.LOADER, self.normal)
            before = self.image_path.read_bytes()
            r.install_fatal(self.cohort, image, self.status)
            expected = bytearray(before)
            for _, lba, data in r.install_writes(self.cohort):
                expected[lba * 512:lba * 512 + len(data)] = data
            self.assertEqual(self.image_path.read_bytes(), expected)
            self.assertEqual(image.read(r.LOADER, len(self.fatal) // 512), self.fatal)

    def test_every_target_write_and_readback_failure_stops_without_next_write(self):
        writes = r.install_writes(self.cohort)
        for index, (label, _, _) in enumerate(writes):
            for mode in ("write", "partial-write", "readback"):
                with self.subTest(label=label, mode=mode):
                    self.reset_image()
                    kwargs = {"bad_readback": label} if mode == "readback" else {
                        "fail_write": label, "partial": mode == "partial-write"}
                    with self.image(**kwargs) as image:
                        with self.assertRaises((r.Refusal, OSError)):
                            r.install_fatal(self.cohort, image, self.status)
                        self.assertEqual(image.labels, [w[0] for w in writes[:index + 1]])

    def test_every_install_read_error_stops(self):
        with self.image() as image:
            r.install_fatal(self.cohort, image, self.status)
            count = image.read_count
        for index in range(1, count + 1):
            with self.subTest(read=index):
                self.reset_image()
                with self.image(fail_read=index) as image:
                    with self.assertRaises(OSError):
                        r.install_fatal(self.cohort, image, self.status)

    def test_recovery_proves_both_stock_slots_not_fallback(self):
        status = self.recovered()
        with self.image() as image:
            result = r.proof(self.cohort, image, status)
            self.assertFalse(result["header_off"])
            self.assertFalse(result["rearm_allowed"])
            self.assertEqual(image.labels, [])
        for key, value in [("gp14", 0), ("gp15", 1), ("gp5", 1), ("wdt_mode", 1),
                           ("gp13", 0x02A7C034), ("gp13", 0x03A8C034), ("gp13", 0x02A8C033),
                           ("boot_id", "before-boot")]:
            with self.subTest(key=key), self.image() as image:
                bad = copy.deepcopy(status)
                bad[key] = value
                with self.assertRaises(r.Refusal):
                    r.cleanup(self.cohort, image, bad)
                self.assertEqual(image.labels, [])
        for elapsed in (0, 180.001, float("nan")):
            with self.subTest(elapsed=elapsed), self.image() as image:
                bad = copy.deepcopy(status)
                bad["return"]["elapsed_seconds"] = elapsed
                with self.assertRaises(r.Refusal):
                    r.proof(self.cohort, image, bad)
        for lba in (16, 512):
            status = self.recovered()
            with self.image() as image:
                os.pwrite(image.stream.fileno(), self.spl, lba * 512)
                with self.assertRaises(r.Refusal):
                    r.cleanup(self.cohort, image, status)
                self.assertEqual(image.labels, [])

    def test_training_is_explicit_sealed_word_changes_not_blanket_mask(self):
        trained = bytearray(self.pin)
        before = r.u32(trained, 160)
        struct.pack_into("<I", trained, 160, before + 1)
        struct.pack_into("<I", trained, 12, r.checksum(trained, 12))
        status = self.recovered(stock=bytes(trained))
        with self.image() as image:
            with self.assertRaisesRegex(r.Refusal, "unaccounted"):
                r.proof(self.cohort, image, status)
        self.manifest["recovery"]["trained_stock"] = {
            "file": self.seal("trained.bin", bytes(trained)), "evidence": "independently decoded saved vendor writeback",
            "changes": [{"offset": 160, "before": before, "after": before + 1}]}
        self.save_manifest()
        cohort = r.Cohort(self.manifest_path)
        with self.image() as image:
            self.assertEqual(len(r.proof(cohort, image, status)["training_changes"]), 1)
            os.pwrite(image.stream.fileno(), self.pin, 512 * 512)
            with self.assertRaisesRegex(r.Refusal, "stock differ"):
                r.proof(cohort, image, status)
        for offset in (160, 300):
            invalid = bytearray(trained)
            struct.pack_into("<I", invalid, offset, r.u32(invalid, offset) ^ 2)
            struct.pack_into("<I", invalid, 12, r.checksum(invalid, 12))
            with self.assertRaises(r.Refusal):
                cohort.stock_equivalent(bytes(invalid))

    def test_cleanup_only_zeroes_header_preserving_every_other_byte(self):
        status = self.recovered()
        before = self.image_path.read_bytes()
        with self.image() as image:
            result = r.cleanup(self.cohort, image, status)
            self.assertTrue(result["header_off"])
            self.assertFalse(result["rearm_allowed"])
            self.assertEqual(image.labels, ["cleanup-header-off"])
            # Retried cleanup after successful zero/readback is safe, never a rearm.
            r.cleanup(self.cohort, image, status)
        expected = bytearray(before)
        expected[r.LOADER * 512:(r.LOADER + 1) * 512] = r.ZERO
        self.assertEqual(self.image_path.read_bytes(), expected)
        self.assertEqual(status["gp14"], r.FATAL_MARK)

    def test_cleanup_all_write_and_read_failure_states_fail_closed(self):
        for mode in ("write", "partial-write", "readback"):
            with self.subTest(mode=mode):
                status = self.recovered()
                kwargs = {"bad_readback": "cleanup-header-off"} if mode == "readback" else {
                    "fail_write": "cleanup-header-off", "partial": mode == "partial-write"}
                with self.image(**kwargs) as image:
                    with self.assertRaises((OSError, r.Refusal)):
                        r.cleanup(self.cohort, image, status)
                    self.assertEqual(image.labels, ["cleanup-header-off"])
        status = self.recovered()
        with self.image() as image:
            r.cleanup(self.cohort, image, status)
            count = image.read_count
        for index in range(1, count + 1):
            with self.subTest(read=index):
                status = self.recovered()
                with self.image(fail_read=index) as image:
                    with self.assertRaises(OSError):
                        r.cleanup(self.cohort, image, status)
        status = self.recovered(header=b"?" * 512)
        with self.image() as image:
            with self.assertRaisesRegex(r.Refusal, "unknown retained"):
                r.cleanup(self.cohort, image, status)
            self.assertEqual(image.labels, [])

    def test_cli_plan_never_spawns_or_writes_and_remote_execute_always_refuses(self):
        before = self.image_path.read_bytes()
        with patch.object(r.subprocess, "run", side_effect=AssertionError("no process in plan")):
            result = r.run(self.args("install-fatal"))
        self.assertFalse(result["execute"])
        self.assertFalse(self.journal.exists())
        self.assertEqual(before, self.image_path.read_bytes())
        args = self.args("install-fatal", execute=True)
        args.target = "operator-specified-host"
        with patch.object(r.subprocess, "run", side_effect=AssertionError("no SSH")):
            with self.assertRaisesRegex(r.Refusal, "no reviewed remote executor"):
                r.run(args)
        self.assertEqual(before, self.image_path.read_bytes())

    def test_cli_execute_real_image_and_single_trial_journal(self):
        args = self.args("install-fatal", execute=True)
        result = r.run(args)
        self.assertTrue(result["execute"])
        self.assertEqual(json.loads(self.journal.read_text())["phase"], "installed")
        with self.assertRaises(r.Refusal):
            r.run(args)
        self.status = self.recovered()
        result = r.run(self.args("cleanup", execute=True))
        self.assertTrue(result["header_off"])
        self.assertEqual(json.loads(self.journal.read_text())["phase"], "cleaned")
        # Header OFF is necessary but never permission to reinstall the fixture.
        self.reset_image()
        self.status.update(gp14=0, gp13=0)
        with self.assertRaises(FileExistsError):
            r.run(self.args("install-fatal", execute=True))

    def test_frozen_manifest_approval_is_required_and_not_reusable_after_reseal(self):
        args = self.args("prepare", execute=True)
        args.manifest_sha256 = None
        with self.assertRaisesRegex(r.Refusal, "approval required"):
            r.run(args)
        args.manifest_sha256 = self.cohort.digest
        newer = bytearray(self.normal)
        newer[513] = 99
        struct.pack_into("<I", newer, 16, r.checksum(newer, 16))
        self.manifest["recovery"]["artifacts"]["normal"] = self.seal("new-normal", bytes(newer))
        self.save_manifest()
        # A new manifest role is explicit, not an arbitrary current on-card loader.
        self.assertEqual(r.Cohort(self.manifest_path).artifacts["normal"], bytes(newer))
        with self.assertRaisesRegex(r.Refusal, "frozen manifest digest mismatch"):
            r.run(args)

    def test_cli_write_failure_records_stop_and_cannot_retry(self):
        args = self.args("install-fatal", execute=True)
        with self.image(fail_write="loader-body") as image:
            with patch.object(r, "Image", return_value=image):
                with self.assertRaises(OSError):
                    r.run(args)
        self.assertEqual(json.loads(self.journal.read_text())["phase"], "STOP")
        self.reset_image()
        with self.assertRaises(FileExistsError):
            r.run(args)

    def test_regular_files_only_and_readonly_image_cannot_mutate(self):
        link = self.root / "symlink.img"
        link.symlink_to(self.image_path)
        with self.assertRaises(OSError):
            r.Image(link, execute=True)
        with self.assertRaises(r.Refusal):
            r.Image("/dev/null")
        image = r.Image(self.image_path)
        try:
            with self.assertRaisesRegex(r.Refusal, "--execute"):
                image.write("not-allowed", r.LOADER, r.ZERO)
        finally:
            image.close()
        with self.image():
            with self.assertRaises(BlockingIOError):
                r.Image(self.image_path, execute=True)

    def test_rendered_commands_parse_and_reboot_recipe_is_exact(self):
        for action in ("prepare", "install-fatal", "guarded-reboot", "prove", "cleanup"):
            state = self.recovered() if action in ("prove", "cleanup") else copy.deepcopy(self.status)
            if action == "guarded-reboot":
                state["gp13"] = 0
            command = r.device_commands(self.cohort, state, action)
            result = subprocess.run(["sh", "-n"], input=command.encode(), capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr.decode())
            self.assertNotIn("0x7000104", command)  # GP1 is not touched/read.
            if action == "guarded-reboot":
                self.assertEqual(command.count("reboot -f"), 1)
                self.assertIn(r.REBOOT_RECIPE, command)
                self.assertIn("180s", command)
                self.assertIn('mkdir "$R"; sync; test -d "$R"', command)
                self.assertNotIn('rm "$R"', command)
            if action == "cleanup":
                self.assertIn("seek=16896 count=1 conv=notrunc,fsync", command)
                self.assertNotIn("sh $T/installer", command)

    def test_rendered_register_guards_fail_closed(self):
        state = copy.deepcopy(self.status)
        state['gp13'] = 0
        command = r.device_commands(self.cohort, state, 'guarded-reboot')
        function = next(line for line in command.splitlines() if line.startswith('regis()'))
        guards = [line for line in command.splitlines() if line.startswith('regis ')]
        self.assertEqual(len(guards), 5)
        for guard in guards:
            expected = int(guard.split()[-1])
            for value, code, accept in (('', 1, False), ('0x00000000', 1, False),
                                        ('', 0, False), ('0x0', 0, False), ('garbage', 0, False),
                                        ('0x%08x' % (expected ^ 1), 0, False),
                                        ('0x%08x' % expected, 0, True)):
                stub = 'busybox() { printf "%s\\n" "' + value + '"; return ' + str(code) + '; }\n'
                result = subprocess.run(['sh', '-ec', stub + function + '\n' + guard], capture_output=True)
                self.assertEqual(result.returncode == 0, accept, (guard, value, code))

    def test_main_entrypoint_plan_and_prepare_use_real_tool(self):
        self.status_path.write_text(json.dumps(self.status))
        arguments = ["prepare", "--manifest", str(self.manifest_path), "--image", str(self.image_path),
                     "--status", str(self.status_path)]
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(r.main(arguments), 0)
        self.assertTrue(json.loads(out.getvalue())["cohort_verified"])
        with contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(r.main(arguments + ["--execute", "--manifest-sha256", self.cohort.digest]), 0)
        self.assertTrue(json.loads(out.getvalue())["execute"])

    def test_saved_reviewed_fatal_artifact_when_available(self):
        path = r.REPO.parent / "2026-11-07-stage2-offline/fatal-fixture/loader/zero-loader.bin"
        if not path.exists():
            self.skipTest("saved offline fatal fixture is not part of the shipping repository")
        data = path.read_bytes()
        r.loader(data)
        self.assertEqual(r.sha(data), "4b6fa34ee98408b51481901d1ca968aa7418ee2022926eaf5a3bf4ecc031f11b")

    def test_production_cli_with_saved_pins_and_explicit_frozen_real_artifacts(self):
        source = os.environ.get("H700_RECOVERY_TEST_COHORT")
        if source is None:
            self.skipTest("opt-in saved-cohort integration; synthetic image tests still always run")
        source = Path(source).resolve()
        manifest = json.loads(source.read_text())
        frozen = {"board": manifest["board"], "files": {}, "recovery": {"artifacts": {}}}
        for name in (*r.REGIONS, "card.txt", "cmdline.txt"):
            entry = dict(manifest["files"][name])
            entry["path"] = str(source.parent / name)
            frozen["files"][name] = entry
        for role in ("spl", "normal", "fatal"):
            path = Path(os.environ["H700_RECOVERY_TEST_" + role.upper()]).resolve()
            data = path.read_bytes()
            frozen["recovery"]["artifacts"][role] = {
                "path": str(path), "bytes": len(data), "sha256": r.sha(data)}
        for role, relative in r.SHIPPING.items():
            path = r.REPO / relative
            data = path.read_bytes()
            frozen["recovery"]["artifacts"][role] = {
                "path": str(path), "bytes": len(data), "sha256": r.sha(data)}
        # Deliberately assemble a HOST fixture, not a claimed current device
        # cohort: old saved primary/store may predate the selected real SPL.
        # First preserve the real stale-cohort refusal, then explicitly seal the
        # two simulated regions containing the operator-selected SPL bytes.
        self.manifest_path.write_text(json.dumps(frozen))
        try:
            r.Cohort(self.manifest_path)
        except r.Refusal as error:
            self.assertIn("exact approved SPL", str(error))
        spl = Path(os.environ["H700_RECOVERY_TEST_SPL"]).read_bytes()
        for name in ("slot16.bin", "store.bin"):
            old = (source.parent / name).read_bytes()
            data = spl + old[len(spl):]
            frozen["files"][name] = self.seal("simulated-" + name, data)
        self.manifest_path.write_text(json.dumps(frozen))
        cohort = r.Cohort(self.manifest_path)
        with self.image_path.open("wb") as stream:
            stream.truncate(20000 * 512)
            for name, (lba, _) in r.REGIONS.items():
                stream.seek(lba * 512)
                stream.write(cohort.saved[name])
        self.status["card"] = cohort.cid
        self.status_path.write_text(json.dumps(self.status))
        before = self.image_path.read_bytes()
        base = [os.sys.executable, "-B", str(TOOL)]
        flags = ["--manifest", str(self.manifest_path), "--status", str(self.status_path),
                 "--image", str(self.image_path)]
        result = subprocess.run(base + ["prepare"] + flags, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout.decode())
        self.assertEqual(before, self.image_path.read_bytes())
        result = subprocess.run(base + ["install-fatal"] + flags + [
            "--execute", "--manifest-sha256", cohort.digest, "--journal", str(self.journal)],
            capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout.decode())
        expected = bytearray(before)
        for _, lba, data in r.install_writes(cohort):
            expected[lba * 512:lba * 512 + len(data)] = data
        self.assertEqual(self.image_path.read_bytes(), expected)
        self.assertEqual(json.loads(self.journal.read_text())["phase"], "installed")
        self.assertTrue(json.loads(result.stdout)["local_only"])


if __name__ == "__main__":
    unittest.main()
