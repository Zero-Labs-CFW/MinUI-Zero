#!/usr/bin/env python3
"""Offline parser/build/test driver. Never opens devices or raw disks."""
import argparse
import hashlib
import json
import difflib
import os
from pathlib import Path
import shlex
import shutil
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]
SESSION = None


def run(args, **kwargs):
    print("+ " + shlex.join(map(str, args)), flush=True)
    return subprocess.run(list(map(str, args)), check=True, **kwargs)


def sha(path):
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    print(f"SHA256 {path.name} {digest}", flush=True)
    return digest


def extract_bootimg(path, out):
    data = path.read_bytes()
    if len(data) < 2048 or data[:8] != b"ANDROID!":
        raise ValueError("not an Android boot image")
    kernel_size, kernel_addr, rd_size, rd_addr, second_size, _, _, page = struct.unpack_from("<8I", data, 8)
    if page != 2048 or kernel_addr != 0x40080000 or rd_addr != 0x42000000 or second_size:
        raise ValueError("boot image does not match the qualified Plus layout")
    rd_offset = page + ((kernel_size + page - 1) // page) * page
    if not 18 <= kernel_size <= 32 * 1024 * 1024 or rd_offset + rd_size > len(data):
        raise ValueError("truncated or oversized boot image")
    gz = out / "kernel.gz"
    gz.write_bytes(data[page:page + kernel_size])
    image = out / "kernel.gunzip"
    with image.open("wb") as f:
        run(["gunzip", "-c", gz], stdout=f)
    print(f"BOOTIMG page={page} kernel_size={kernel_size} kernel_addr={kernel_addr:#x} "
          f"ramdisk_size={rd_size} ramdisk_addr={rd_addr:#x}", flush=True)
    for p in (path, gz, image):
        sha(p)
    return gz, image


def compile_host(output, sources, sanitize):
    cc = shlex.split(os.environ.get("CC", "cc"))
    flags = ["-std=gnu11", "-O1", "-g", "-D__UBOOT__", "-DFREESTANDING", "-DZL_HOST_TEST", "-fno-strict-aliasing",
             "-I" + str(ROOT), "-I" + str(ROOT / "include"), "-I" + str(ROOT / "libfdt")]
    if sanitize:
        flags += ["-fsanitize=address,undefined", "-fno-omit-frame-pointer"]
    run(cc + flags + [str(ROOT / p) for p in sources] + ["-o", str(output)])


def parse_fdt(path):
    """Independent FDT token parser, comparing every node and raw property byte."""
    data = path.read_bytes()
    magic, total, off, strings, rsv, _, _, _, strings_len, structure_len = struct.unpack_from(">10I", data)
    assert magic == 0xD00DFEED and total <= len(data)
    assert strings + strings_len <= total and off + structure_len <= total
    reserves = []
    while True:
        addr, size = struct.unpack_from(">QQ", data, rsv)
        rsv += 16
        if not (addr or size):
            break
        reserves.append((addr, size))
    nodes, stack = {}, []
    end = off + structure_len
    while off < end:
        token, = struct.unpack_from(">I", data, off)
        off += 4
        if token == 1:
            stop = data.index(0, off, end)
            stack.append(data[off:stop].decode("ascii"))
            off = (stop + 4) & ~3
            path = "/" + "/".join(stack[1:])
            assert path not in nodes
            nodes[path] = {}
        elif token == 2:
            stack.pop()
        elif token == 3:
            size, nameoff = struct.unpack_from(">II", data, off)
            off += 8
            assert 0 <= nameoff < strings_len and off + size <= end
            name_end = data.index(0, strings + nameoff, strings + strings_len)
            name = data[strings + nameoff:name_end].decode("ascii")
            props = nodes["/" + "/".join(stack[1:])]
            assert name not in props
            props[name] = data[off:off + size]
            off = (off + size + 3) & ~3
        elif token == 4:
            pass
        elif token == 9:
            assert not stack
            return nodes, reserves
        else:
            raise ValueError(f"invalid FDT token {token}")
    raise ValueError("missing FDT_END")


def canonical_expected(nodes, reserves, path):
    lines = ["/dts-v1/;"] + [f"/memreserve/ {addr:#x} {size:#x};" for addr, size in reserves]

    def emit(node, depth):
        name = "/" if node == "/" else node.rsplit("/", 1)[1]
        lines.append("\t" * depth + name + " {")
        for key, value in sorted(nodes[node].items()):
            lines.append("\t" * (depth + 1) + key + " = [" + value.hex(" ") + "];")
        for child in sorted(nodes):
            if child != "/" and child.rsplit("/", 1)[0] == ("" if node == "/" else node):
                emit(child, depth + 1)
        lines.append("\t" * depth + "};")
    emit("/", 0)
    path.write_text("\n".join(lines) + "\n")


def check_fdt(out):
    live = out / "live.dtb"
    run(["dtc", "-q", "-I", "dts", "-O", "dtb", "-o", live, SESSION / "live-dt-plus.dts"])
    actual, reserves = parse_fdt(out / "actual.dtb")
    expected, live_reserves = parse_fdt(live)
    package, package_reserves = parse_fdt(SESSION / "pkg/dtb.bin")
    assert not live_reserves and package_reserves == [(0x48000000, 0x1000000)]
    assert actual.keys() == expected.keys() == package.keys(), "unexpected node addition/removal"
    pin_words = struct.unpack_from("<32I", (SESSION / "pin-plus.bin").read_bytes(), 0x38)
    names = ["dram_clk", "dram_type", "dram_zq", "dram_odt_en", "dram_para1", "dram_para2", "dram_mr0",
             "dram_mr1", "dram_mr2", "dram_mr3"] + [f"dram_tpr{i}" for i in range(14)]
    for i, name in enumerate(names):
        assert actual["/dram"][name] == struct.pack(">I", pin_words[i] | (0x80000000 if i == 23 else 0))
    cmd = (SESSION / "cmdline-plus.txt").read_text().strip().encode() + b"\0"
    assert expected["/chosen"]["bootargs"] == cmd
    token = b" disp_reserve=1228800,0x7bf23800"
    assert cmd.count(token) == 1
    expected["/chosen"]["bootargs"] = cmd.replace(token, b"")
    build_id = bytes.fromhex((ROOT / 'obj/build-id').read_text().strip())
    expected['/chosen']['zero,loader'] = b'ZHL1' + struct.pack('>7I', 1, 64, 1, 0, 640, 480, 0) + build_id
    disp = ["/soc@03000000/disp@01000000"]
    assert package[disp[0]]["boot_disp"] == struct.pack(">I", 0)
    for key in ["boot_disp", "boot_disp1", "boot_disp2", "boot_fb0"]:
        if key in package[disp[0]]:
            expected[disp[0]][key] = package[disp[0]][key]
        else:
            del expected[disp[0]][key]
    late = []
    for node, props in package.items():
        if props.get("status") == b"late\0":
            assert expected[node]["status"] == b"okay\0"
            expected[node]["status"] = b"late\0"
            late.append(node)
    assert len(late) == 7
    known = {("/chosen", "bootargs"), ('/chosen', 'zero,loader')}
    known |= {(disp[0], key) for key in ["boot_disp", "boot_disp1", "boot_disp2", "boot_fb0"]}
    known |= {(node, "status") for node in late}
    live_nodes, _ = parse_fdt(live)
    delta = {(node, key) for node in actual for key in actual[node].keys() | live_nodes[node].keys()
             if actual[node].get(key) != live_nodes[node].get(key)}
    assert delta == known, f"unaccounted/missing differences: {delta ^ known}"
    assert actual == expected, "unexpected FDT value outside explicit normalizations"
    expected_reserves = [(0x48000000, 0x1000000), (0x42000000, 0x200)]
    assert reserves == expected_reserves
    summary = {"property_differences_from_live": sorted([list(item) for item in delta]),
               "reservation_map": reserves, "unknown_differences": 0}
    (out / "fdt-differences.json").write_text(json.dumps(summary, indent=2) + "\n")
    canonical_expected(expected, expected_reserves, out / "expected.input.dts")
    run(["dtc", "-q", "-I", "dts", "-O", "dtb", "-o", out / "expected.dtb", out / "expected.input.dts"])
    for name in ("actual", "expected"):
        run(["dtc", "-q", "-s", "-I", "dtb", "-O", "dts", "-o", out / f"{name}.sorted.dts", out / f"{name}.dtb"])
    a = (out / "actual.sorted.dts").read_text().splitlines(keepends=True)
    b = (out / "expected.sorted.dts").read_text().splitlines(keepends=True)
    diff = "".join(difflib.unified_diff(b, a, fromfile="expected", tofile="actual"))
    (out / "fdt.diff").write_text(diff)
    assert not diff, "dtc -s diff is not empty"
    sha(out / "actual.dtb")
    sha(out / "actual.sorted.dts")
    print(f"PASS exhaustive FDT: {len(actual)} nodes, {sum(map(len, actual.values()))} properties; "
          f"{len(delta)} explained live differences; unknown=0; dtc -s diff=empty", flush=True)


def source_hashes():
    return {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in ROOT.rglob("*") if p.is_file() and not {"build", "obj"}.intersection(p.relative_to(ROOT).parts)
            and (p.suffix in {".c", ".h", ".S", ".ld", ".py"} or p.name == "Makefile")}


def check_stub_assembly(out):
    clang = shutil.which("clang")
    if not clang:
        print("A32 assembler oracle: skipped (clang absent); exact word fixture still checked", flush=True)
        return
    obj = out / "stub32.o"
    run([clang, "--target=armv7a-none-eabi", "-c", ROOT / "test/stub32.S", "-o", obj])
    data = obj.read_bytes()
    header = struct.unpack_from("<16sHHIIIIIHHHHHH", data)
    assert header[0][:6] == b"\x7fELF\x01\x01" and header[2] == 40
    shoff, shsize, count, names_index = header[6], header[11], header[12], header[13]
    sections = [struct.unpack_from("<10I", data, shoff + i * shsize) for i in range(count)]
    names = sections[names_index]
    strings = data[names[4]:names[4] + names[5]]
    code = [s for s in sections if strings[s[0]:].split(b"\0", 1)[0] == b".text"]
    assert len(code) == 1
    section = code[0]
    assembled = data[section[4]:section[4] + section[5]]
    assert assembled == (out / "stub.bin").read_bytes(), "A32 assembler differs from produced stub"
    print("PASS A32 stub: 80 bytes match independent assembly; box-start then all kernel arguments reloaded", flush=True)


def main():
    global SESSION
    ap = argparse.ArgumentParser()
    ap.add_argument('--fixtures', type=Path, required=True)
    ap.add_argument("--bootimg", type=Path, required=True)
    ap.add_argument("--output", type=Path, required=True)
    ap.add_argument("--no-sanitize", action="store_true")
    args = ap.parse_args()
    SESSION = args.fixtures.resolve()
    out = args.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    before = source_hashes()
    gz, image = extract_bootimg(args.bootimg.resolve(), out)
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=" + ("0" if sys.platform == "darwin" else "1"),
               UBSAN_OPTIONS="halt_on_error=1:print_stacktrace=1")
    exe = out / "test-gunzip"
    compile_host(exe, ["test/offline_gunzip.c", "gunzip.c", "lib/crc32.c", "libdeflate/lib/utils.c",
                       "libdeflate/lib/deflate_decompress.c", "libdeflate/lib/gzip_decompress.c",
                       "libdeflate/lib/x86/cpu_features.c"], not args.no_sanitize)
    run([exe, gz, image], env=env)
    exe = out / "test-fdt"
    libfdt = [str(p.relative_to(ROOT)) for p in sorted((ROOT / "libfdt").glob("*.c"))]
    compile_host(exe, ["test/offline_fdt.c", "test/offline_soc.c", "fixup.c", "rtc.c"] + libfdt,
                 not args.no_sanitize)
    run([exe, SESSION / "pkg/dtb.bin", SESSION / "bootimg-hdr-plus.bin", SESSION / "pin-plus.bin",
         SESSION / "pkg/dtbo.bin", out / "actual.dtb"], env=env)
    check_fdt(out)
    exe = out / "test-state"
    compile_host(exe, ["test/offline_state.c", "test/offline_soc.c", "main.c", "monitor.c", "rtc.c", "wdt.c"],
                 not args.no_sanitize)
    run([exe, SESSION / "pkg/monitor.bin", image, out / "stub.bin"], env=env)
    check_stub_assembly(out)
    exe = out / "test-panel"
    compile_host(exe, ["test/offline_panel.c", "test/offline_soc.c", "rtc.c"], not args.no_sanitize)
    run([exe], env=env)
    after = source_hashes()
    if before != after:
        raise RuntimeError("loader source files changed during test execution; rerun after writers stop")
    (out / "sources.sha256.json").write_text(json.dumps(after, indent=2, sort_keys=True) + "\n")
    print("QEMU host: " + (shutil.which("qemu-system-aarch64") or "not installed"), flush=True)


if __name__ == "__main__":
    main()
