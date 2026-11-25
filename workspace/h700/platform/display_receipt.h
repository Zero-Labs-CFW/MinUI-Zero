#ifndef H700_DISPLAY_RECEIPT_H
#define H700_DISPLAY_RECEIPT_H

#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static int h700_receipt_uuid_valid(const char* id) {
	if (!id || strlen(id) != 36) return 0;
	for (int i = 0; i < 36; i++) {
		if (i == 8 || i == 13 || i == 18 || i == 23) {
			if (id[i] != '-') return 0;
		} else if (!((id[i] >= '0' && id[i] <= '9') || (id[i] >= 'a' && id[i] <= 'f'))) return 0;
	}
	return 1;
}

// Existence acknowledges a completed flip even if optional timing metadata fails.
// Never replace another process's first receipt or follow a symlink.
// First publisher wins; a delayed earlier sample must not replace its receipt.
static int h700_write_display_receipt(const char* path, const char* id, uint64_t raw_ns) {
	int fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0644);
	if (fd < 0) return errno == EEXIST ? 0 : -1;
	int result = 0;
	if (raw_ns && h700_receipt_uuid_valid(id)) {
		char line[112];
		int n = snprintf(line, sizeof(line), "v1 boot=%s raw_ns=%" PRIu64 "\n", id, raw_ns);
		int off = 0;
		while (off < n) {
			ssize_t count = write(fd, line + off, (size_t)(n - off));
			if (count < 0 && errno == EINTR) continue;
			if (count <= 0) { result = -1; break; }
			off += (int)count;
		}
	}
	if (close(fd) < 0) result = -1;
	return result;
}

#endif
