# darkhttpd 1.16 for tg5040

Static aarch64 build of darkhttpd (https://github.com/emikulic/darkhttpd, v1.16, BSD licence), shipped as
`skeleton/SYSTEM/tg5040/bin/darkhttpd` for Device Sync. busybox httpd on the Brick (1.27.2) does not honour
HTTP Range, so a stopped or cut game download restarted from zero whenever a TrimUI was the sender; darkhttpd
answers 206 and `wget -c` resumes. The muOS binary we ship for h700 needs glibc 2.38 and the Brick has 2.33,
hence our own build.

Rebuild (inside the tg5040 toolchain container, `make shell PLATFORM=tg5040`):

    cd /root/workspace/tg5040/other/darkhttpd
    /opt/aarch64-linux-gnu/bin/aarch64-linux-gnu-gcc -O2 -static -o darkhttpd darkhttpd.c
    /opt/aarch64-linux-gnu/bin/aarch64-linux-gnu-strip darkhttpd
    cp darkhttpd ../../../../skeleton/SYSTEM/tg5040/bin/

The getpwnam/getgrnam static-link warnings are harmless: `--uid`/`--chroot` are never used.
