#!/usr/bin/env python3
"""Feed the production FDT output to the real Linux acceptance CLI, offline."""
import argparse
import importlib.util
from pathlib import Path
import struct
import subprocess
import tempfile

spec = importlib.util.spec_from_file_location('loader_offline', Path(__file__).with_name('offline.py'))
offline = importlib.util.module_from_spec(spec)
spec.loader.exec_module(offline)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dtb', type=Path, required=True)
    parser.add_argument('--expected', type=Path, required=True)
    parser.add_argument('--helper', type=Path, required=True)
    args = parser.parse_args()
    nodes, _ = offline.parse_fdt(args.dtb)
    record = nodes['/chosen']['zero,loader']
    cmdline = nodes['/chosen']['bootargs'].rstrip(b'\0') + b'\n'
    _, _, profile, panel, width, height, _ = struct.unpack('>7I', record[4:32])
    assert profile in (1, 2) and panel in (0, 1)
    display = (f'screen 0:\n mgr0: {width}x{height} err[0] unblank\n'
               f' lcd output backlight(88) fps:60.0 {width}x {height}\n'
               ' err:0\n'
               f' BUF enable frame[0,0,{width},{height}]\n').encode()
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        paths = {name: root / name for name in ('record', 'expected', 'cmdline', 'display', 'menu')}
        values = dict(record=record, expected=args.expected.read_bytes(), cmdline=cmdline,
                      display=display, menu=b'1\n')
        command = [str(args.helper.resolve())]
        for name, path in paths.items():
            command += ['--' + name, str(path)]

        def check(changes, accepted):
            for name, value in (values | changes).items():
                paths[name].unlink(missing_ok=True)
                if value is not None:
                    paths[name].write_bytes(value)
            result = subprocess.run(command, capture_output=True, text=True)
            assert (result.returncode == 0) == accepted, result.stderr

        check({}, True)
        for offset, value in ((0, b'BAD!'), (12, struct.pack('>I', 3)),
                              (16, struct.pack('>I', 1 - panel)),
                              (20, struct.pack('>I', width + 1)),
                              (32, bytes([record[32] ^ 1]))):
            changed = record[:offset] + value + record[offset + len(value):]
            check({'record': changed}, False)
        check({'menu': None}, False)
        check({'cmdline': cmdline + b' lcd_type=old'}, False)
        check({'display': display.replace(b'err[0]', b'err[1]')}, False)
    print('PASS production FDT -> boot-health: accept + 8 rejection cases')


if __name__ == '__main__':
    main()
