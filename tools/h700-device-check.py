#!/usr/bin/env python3
"""Analyze an extracted boot-evidence.sh report. No device access."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import stat
import struct
import sys
from uuid import UUID

PROFILES = Path(__file__).resolve().parents[1] / "workspace/h700/loader/profiles.json"
ZERO = hashlib.sha256(bytes(512)).hexdigest()


def analyze(folder):
    def data(name):
        p = folder / name
        try:
            s = p.lstat()
            if not stat.S_ISREG(s.st_mode) or s.st_size > 65536:
                return None
            return p.read_bytes()
        except OSError:
            return None

    def line(name):
        b = data(name)
        return b.decode("ascii", "replace").strip() if b is not None else None

    def digest(name):
        value = line(name)
        return value.lower() if value and re.fullmatch("[0-9a-fA-F]{64}", value) else None

    statuses = {}
    for row in (line("status.tsv") or "").splitlines():
        key, sep, value = row.partition("\t")
        if sep and key not in statuses:
            statuses[key] = value
        else:
            raise ValueError("malformed/duplicate status: " + key)

    def presence(name):
        v = statuses.get(name)
        return False if v == "absent" else True if v in ("present", "ok", "empty") else None

    board = line("board")
    profiles = {r["board"]: r for r in json.loads(PROFILES.read_text())["profiles"]}
    profile = profiles.get(board)
    chosen = (line("chosen") or "").removeprefix("rg35xx-")
    dram = line("dram-type")
    state = line("state-end")
    off, trial = presence("off-end"), presence("trial-end")
    issues, gaps, pending = [], [], []
    boot = line("boot-id-start")
    stable = line("complete") == line("schema") == "1" and boot == line("boot-id-end")
    try:
        stable = stable and str(UUID(boot or "")) == boot
        stable = stable and float(line("uptime-end").split()[0]) >= float(line("uptime-start").split()[0])
    except (ValueError, AttributeError, IndexError):
        stable = False
    for key in ("state", "off", "trial", "zero-spl-auto", "zero-spl-busy", "zero-spl-sleep",
                "swap", "zero-stage2-provisioned", "zero-stage2-charger", "gp13", "gp14", "gp15"):
        a, b = key + "-start", key + "-end"
        if statuses.get(a) != statuses.get(b) or data(a) != data(b):
            stable = False
    for key in ("zero-spl-auto", "zero-spl-busy", "zero-spl-sleep", "swap"):
        if presence(key + "-end") is not False:
            stable = False
    if not stable:
        gaps.append("Incomplete or changing snapshot; repeat at an idle launcher.")
    if chosen != board or not profile:
        gaps.append("Board selection unknown or inconsistent.")
    if not state or not line("version") or not line("rootfs-level"):
        gaps.append("Missing policy state or release identity.")
    if off is True:
        requested = "off"
    elif off is None or not re.fullmatch(r"[0-9]{1,10}", dram or "") or not profile:
        requested = "unknown"
    elif int(dram) not in profile["dram_types"]:
        requested = "stock"
    elif board in ("h", "plus") and dram == "8":
        requested = "auto"
    else:
        requested = "trial" if trial else "stock" if trial is False else "unknown"

    spl = digest({"7": "zero-spl-lp3.bin.sha256", "8": "zero-spl.bin.sha256"}.get(dram, "unknown"))
    normal = digest("loader.sha256")
    primary, backup = digest("lba16.sha256"), digest("lba512.sha256")
    header = digest("lba16896.sha256")
    stock_head = data("lba512.header") or b""
    if primary and primary == backup and header == ZERO and len(stock_head) == 24 and stock_head[4:12] == b"eGON.BT0" and stock_head[20:23] != b"SPL":
        installed = "stock"
    elif spl and normal and digest("spl-16.sha256") == digest("spl-16768.sha256") == spl and digest("loader-on-card.sha256") == normal:
        installed = "stage2"
    else:
        installed = "unknown/mixed"

    record = data("loader.dt")
    ran, match = "unknown", "unknown"
    if statuses.get("loader.dt") == "absent":
        ran, match = "vendor", "not applicable"
    elif record is not None:
        if len(record) == 64 and struct.unpack(">4sII", record[:12]) == (b"ZHL1", 1, 64):
            ran = "stage2"
            ids = [digest("expected-id"), digest("helper-id")]
            if all(ids) and line("helper-id.exit") == "0":
                match = "yes" if record[32:].hex() == ids[0] == ids[1] else "no"
            if not profile or int.from_bytes(record[12:16], "big") != profile["id"]:
                issues.append("Loader profile differs from reported board.")
            if match == "no" or line("health.exit") not in (None, "0"):
                issues.append("Build ID mismatch or boot-health rejected this boot.")
            if (match == "unknown" or line("health.exit") is None or
                    (line("health.exit") == "0" and line("health.stdout") != "boot-health: accepted")):
                gaps.append("Missing helper/build evidence.")
            frame = re.fullmatch(r"v1 boot=([\w-]+) raw_ns=([1-9]\d*)", line("frame") or "")
            if not frame or frame[1] != boot:
                gaps.append("No completed display receipt for this boot.")
        else:
            issues.append("Malformed live loader record.")

    opt = "not requested" if off is False else "unknown"
    if off:
        clean = (installed == "stock" and digest("lba16640.sha256") == ZERO
                 and line("gp15-end") == "0x00000000" and digest("store-header.sha256") == ZERO)
        opt = "applied for next start" if clean and state in ("off", "failed", "gaveup", "unsupported") else "not confirmed"
    if state in ("failed", "gaveup"):
        issues.append("Policy failure latch: " + state)
    if requested == "unknown" or ran == "unknown" or installed == "unknown/mixed":
        gaps.append("Missing or inconclusive boot evidence.")
    if off and opt == "not confirmed":
        pending.append("Opt-out not yet verified.")
    if requested in ("auto", "trial"):
        if state != f"stage2:{requested}:{board}" or installed != "stage2":
            pending.append("Requested installation not confirmed.")
        elif ran == "vendor":
            if presence("zero-stage2-charger-end"):
                pending.append("Intentional charger handoff; verify next button boot.")
            elif presence("zero-stage2-provisioned-end"):
                pending.append("Provisioned this boot; verify next boot.")
            else:
                gaps.append("Vendor boot with stage 2 installed; inspect pre-ack evidence.")
    if requested == "stock" and installed != "stock":
        pending.append("Stock request not yet confirmed.")
    for expected, actual in (("package", "package-24576"), ("package", "package-32800"), ("kernel", "kernel-on-card")):
        a, b = digest(expected + ".sha256"), digest(actual + ".sha256")
        if not a or not b:
            gaps.append("Missing artifact comparison: " + actual)
        elif a != b:
            issues.append("Card artifact differs: " + actual)
    for name in ("gp13-end", "gp14-end", "gp15-end"):
        if not re.fullmatch(r"0[xX][0-9a-fA-F]{8}", line(name) or ""):
            gaps.append("Missing RTC evidence: " + name)
    snap = line("preack-card")
    preack = ("unavailable" if not snap else "current" if boot and
              "boot_id=" + boot in snap.splitlines() else "stale or invalid")
    verdict = "UNKNOWN" if not stable else "FAIL" if issues else "UNKNOWN" if gaps else "PENDING" if pending else "PASS"
    return dict(board=board, verdict=verdict, requested=requested, installed=installed,
                ran_this_boot=ran, id_match=match, opt_out=opt, policy=state, preack_card=preack,
                notes=issues + gaps + pending)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path)
    args = parser.parse_args()
    try:
        result = analyze(args.folder)
        print(json.dumps(result, indent=2))
        sys.exit({"PASS": 0, "FAIL": 1}.get(result["verdict"], 2))
    except (ValueError, OSError) as error:
        sys.exit("Invalid report: " + str(error))
