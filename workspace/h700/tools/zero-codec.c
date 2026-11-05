// zero-codec: save and restore the H700 mixer state without alsa-lib (boot speed, 2026-11-05).
//
// alsactl restore costs ~2.6 MB of cold card reads at boot (alsa-lib, its config tree, glibc), on the menu's critical
// path. This tool talks to /dev/snd/controlC* directly and links nothing (raw syscalls), so it is a few KB:
//   zero-codec save FILE     every readable+writable control of every card, by numid with its name
//   zero-codec restore FILE [SKIP...]  writes them back, except the controls named SKIP; a control whose name no
//                            longer matches its numid aborts with exit 2
//                            (driver or kernel changed: the caller falls back to alsactl and saves again)
// The saved file is taken right after a real alsactl restore, so it holds exactly the state alsactl would set.
#include <linux/ioctl.h>
#include <sound/asound.h>

#define MAX_CARDS 4
#define MAX_ELEMS 128

static long sc(long n, long a, long b, long c, long d) {
	register long x8 asm("x8") = n, x0 asm("x0") = a, x1 asm("x1") = b, x2 asm("x2") = c, x3 asm("x3") = d;
	asm volatile("svc 0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2), "r"(x3) : "memory");
	return x0;
}
#define SYS_openat 56
#define SYS_close 57
#define SYS_read 63
#define SYS_write 64
#define SYS_ioctl 29
#define SYS_exit 93
#define O_RDONLY 0
#define O_RDWR 2
#define O_WRONLY_CREAT_TRUNC (1 | 0100 | 01000)

struct rec {				// one saved control
	unsigned int card;
	struct snd_ctl_elem_value v;	// v.id carries numid and name
};

// the file: this header, then exactly count records; restore accepts nothing shorter or longer (Codex review 2026-11-05:
// a truncated snapshot must fall back to alsactl, not restore half the mixer and report success)
struct head {
	char magic[8];			// "ZCODEC1"
	unsigned int count, recsize;
};
static const char MAGIC[8] = "ZCODEC1";

static struct snd_ctl_elem_id ids[MAX_ELEMS];
static struct {
	struct head h;
	struct rec recs[MAX_CARDS * MAX_ELEMS];
	char spare[1];			// one byte past the largest valid file: a longer file reads into it and is rejected
} snap;
#define recs snap.recs

static void *mset(void *d, int c, unsigned long n) { unsigned char *p = d; while (n--) *p++ = c; return d; }
static int scmp(const unsigned char *a, const unsigned char *b, int n) {
	for (int i = 0; i < n; i++) { if (a[i] != b[i]) return 1; if (!a[i]) return 0; }
	return 0;
}
static __attribute__((noreturn)) void die(int code) { sc(SYS_exit, code, 0, 0, 0); for (;;) ; }

static long open_card(unsigned int card, int flags) {
	char path[] = "/dev/snd/controlC0";
	path[sizeof(path) - 2] = '0' + card;
	return sc(SYS_openat, -100, (long)path, flags, 0);
}

static int do_save(const char *file) {
	int n = 0;
	for (unsigned int card = 0; card < MAX_CARDS; card++) {
		long fd = open_card(card, O_RDONLY);
		if (fd < 0) continue;
		struct snd_ctl_elem_list list;
		mset(&list, 0, sizeof(list));
		list.space = MAX_ELEMS;
		list.pids = ids;
		if (sc(SYS_ioctl, fd, SNDRV_CTL_IOCTL_ELEM_LIST, (long)&list, 0) < 0) { sc(SYS_close, fd, 0, 0, 0); continue; }
		for (unsigned int i = 0; i < list.used && n < MAX_CARDS * MAX_ELEMS; i++) {
			struct snd_ctl_elem_info info;
			mset(&info, 0, sizeof(info));
			info.id = ids[i];
			if (sc(SYS_ioctl, fd, SNDRV_CTL_IOCTL_ELEM_INFO, (long)&info, 0) < 0) continue;
			if (!(info.access & SNDRV_CTL_ELEM_ACCESS_READ) || !(info.access & SNDRV_CTL_ELEM_ACCESS_WRITE) ||
			    (info.access & SNDRV_CTL_ELEM_ACCESS_INACTIVE))
				continue;
			struct rec *r = &recs[n];
			mset(r, 0, sizeof(*r));
			r->card = card;
			r->v.id = ids[i];
			if (sc(SYS_ioctl, fd, SNDRV_CTL_IOCTL_ELEM_READ, (long)&r->v, 0) < 0) continue;
			n++;
		}
		sc(SYS_close, fd, 0, 0, 0);
	}
	if (!n) return 1;
	long out = sc(SYS_openat, -100, (long)file, O_WRONLY_CREAT_TRUNC, 0644);
	if (out < 0) return 1;
	for (int i = 0; i < 8; i++) snap.h.magic[i] = MAGIC[i];
	snap.h.count = n;
	snap.h.recsize = sizeof(struct rec);
	long want = sizeof(struct head) + (long)n * sizeof(struct rec), put = 0;
	while (put < want) {
		long w = sc(SYS_write, out, (long)&snap + put, want - put, 0);
		if (w <= 0) break;
		put += w;
	}
	sc(SYS_close, out, 0, 0, 0);
	return put == want ? 0 : 1;
}

static int do_restore(const char *file, char **skip, int nskip) {
	long in = sc(SYS_openat, -100, (long)file, O_RDONLY, 0);
	if (in < 0) return 1;
	long got = 0;
	while (got < (long)sizeof(snap)) {
		long r = sc(SYS_read, in, (long)&snap + got, sizeof(snap) - got, 0);
		if (r < 0) { got = -1; break; }
		if (r == 0) break;
		got += r;
	}
	sc(SYS_close, in, 0, 0, 0);
	if (got < (long)sizeof(struct head) || scmp((const unsigned char *)snap.h.magic, (const unsigned char *)MAGIC, 8) ||
	    snap.h.recsize != sizeof(struct rec) || snap.h.count == 0 || snap.h.count > MAX_CARDS * MAX_ELEMS ||
	    got != (long)sizeof(struct head) + (long)snap.h.count * (long)sizeof(struct rec))
		return 1;
	int n = snap.h.count, rc = 0;
	long fds[MAX_CARDS];
	for (int c = 0; c < MAX_CARDS; c++) fds[c] = -1;
	for (int i = 0; i < n; i++) {
		struct rec *r = &recs[i];
		if (r->card >= MAX_CARDS) return 1;
		if (fds[r->card] < 0 && (fds[r->card] = open_card(r->card, O_RDWR)) < 0) return 2;
		long fd = fds[r->card];
		struct snd_ctl_elem_info info;			// the numid must still name the same control
		mset(&info, 0, sizeof(info));
		info.id.numid = r->v.id.numid;
		if (sc(SYS_ioctl, fd, SNDRV_CTL_IOCTL_ELEM_INFO, (long)&info, 0) < 0 ||
		    scmp(info.id.name, r->v.id.name, sizeof(info.id.name)) || info.id.index != r->v.id.index)
			{ rc = 2; break; }
		int skipped = 0;
		for (int k = 0; k < nskip; k++)
			if (!scmp(r->v.id.name, (const unsigned char *)skip[k], sizeof(r->v.id.name))) skipped = 1;
		if (skipped) continue;
		if (sc(SYS_ioctl, fd, SNDRV_CTL_IOCTL_ELEM_WRITE, (long)&r->v, 0) < 0) rc = 1;
	}
	for (int c = 0; c < MAX_CARDS; c++) if (fds[c] >= 0) sc(SYS_close, fds[c], 0, 0, 0);
	return rc;
}

/* set CARD NAME VALUE: an integer or switch control, every channel (the frontend's apply_volume: "digital volume" on
 * card 0; the speaker path switches at boot, see minui-frontend.sh codec_restore) */
static int do_set(const char *card_s, const char *name, const char *val_s) {
	unsigned int card = card_s[0] - '0';
	long val = 0;
	for (const char *p = val_s; *p; p++) { if (*p < '0' || *p > '9') return 64; val = val * 10 + (*p - '0'); }
	if (card >= MAX_CARDS || card_s[1]) return 64;
	long fd = open_card(card, O_RDWR);
	if (fd < 0) return 1;
	struct snd_ctl_elem_info info;
	mset(&info, 0, sizeof(info));
	info.id.iface = SNDRV_CTL_ELEM_IFACE_MIXER;
	for (int i = 0; name[i] && i < (int)sizeof(info.id.name) - 1; i++) info.id.name[i] = name[i];
	int rc = 1;
	if (sc(SYS_ioctl, fd, SNDRV_CTL_IOCTL_ELEM_INFO, (long)&info, 0) >= 0 &&
	    (info.type == SNDRV_CTL_ELEM_TYPE_INTEGER || info.type == SNDRV_CTL_ELEM_TYPE_BOOLEAN ||
	     info.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED)) {
		struct snd_ctl_elem_value v;
		mset(&v, 0, sizeof(v));
		v.id = info.id;
		if (info.type == SNDRV_CTL_ELEM_TYPE_ENUMERATED) {	// VALUE is the item index ("tx hub mode" 0 = Off)
			if (info.value.enumerated.items == 0) { sc(SYS_close, fd, 0, 0, 0); return 1; }
			if (val >= info.value.enumerated.items) val = info.value.enumerated.items - 1;
			for (unsigned int c = 0; c < info.count && c < 128; c++) v.value.enumerated.item[c] = val;
		} else {
			if (info.type == SNDRV_CTL_ELEM_TYPE_BOOLEAN) {
				if (val > 1) val = 1;
			} else {
				if (val < info.value.integer.min) val = info.value.integer.min;
				if (val > info.value.integer.max) val = info.value.integer.max;
			}
			for (unsigned int c = 0; c < info.count && c < 128; c++) v.value.integer.value[c] = val;
		}
		rc = sc(SYS_ioctl, fd, SNDRV_CTL_IOCTL_ELEM_WRITE, (long)&v, 0) < 0 ? 1 : 0;
	}
	sc(SYS_close, fd, 0, 0, 0);
	return rc;
}

void _start_c(long *sp) {
	int argc = (int)sp[0];
	char **argv = (char **)(sp + 1);
	if (argc == 5 && !scmp((const unsigned char *)argv[1], (const unsigned char *)"set", 4))
		die(do_set(argv[2], argv[3], argv[4]));
	if (argc >= 3 && !scmp((const unsigned char *)argv[1], (const unsigned char *)"restore", 8))
		die(do_restore(argv[2], argv + 3, argc - 3));
	if (argc != 3) die(64);
	if (!scmp((const unsigned char *)argv[1], (const unsigned char *)"save", 5)) die(do_save(argv[2]));
	die(64);
}

asm(".global _start\n_start:\n\tmov x0, sp\n\tb _start_c\n");
