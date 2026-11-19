#include "display_receipt.h"
#include <assert.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/wait.h>

static const char* uuid = "42248cd7-52eb-4dd9-88cc-a261d8037b59";

static void check(const char* path, const char* expected) {
	char buf[256] = {0};
	int fd = open(path, O_RDONLY);
	assert(fd >= 0);
	ssize_t n = read(fd, buf, sizeof(buf) - 1);
	assert(n >= 0);
	assert(close(fd) == 0);
	assert(strcmp(buf, expected) == 0);
}

int main(int argc, char** argv) {
	assert(argc == 2 && chdir(argv[1]) == 0);
	assert(h700_write_display_receipt("first", uuid, 123456789) == 0);
	check("first", "v1 boot=42248cd7-52eb-4dd9-88cc-a261d8037b59 raw_ns=123456789\n");
	assert(h700_write_display_receipt("first", uuid, 9) == 0);
	check("first", "v1 boot=42248cd7-52eb-4dd9-88cc-a261d8037b59 raw_ns=123456789\n");
	assert(h700_write_display_receipt("invalid", "bad", 123) == 0);
	check("invalid", "");
	assert(h700_write_display_receipt("zero", uuid, 0) == 0);
	check("zero", "");
	assert(h700_write_display_receipt("null", NULL, 123) == 0);
	check("null", "");
	assert(h700_write_display_receipt("missing/marker", uuid, 123) == -1);
	assert(symlink("invalid", "link") == 0);
	assert(h700_write_display_receipt("link", uuid, 123) == 0);
	check("invalid", "");
	assert(!h700_receipt_uuid_valid("42248cd7-52eb-4dd9-88cc-a261d8037b5g"));
	for (int i = 0; i < 2; i++) {
		pid_t pid = fork();
		assert(pid >= 0);
		if (!pid) _exit(h700_write_display_receipt("race", uuid, 987654321) != 0);
	}
	for (int i = 0; i < 2; i++) {
		int status;
		assert(wait(&status) > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0);
	}
	check("race", "v1 boot=42248cd7-52eb-4dd9-88cc-a261d8037b59 raw_ns=987654321\n");
	int gate[2];
	assert(pipe(gate) == 0);
	pid_t delayed = fork();
	assert(delayed >= 0);
	if (!delayed) {
		char token;
		close(gate[1]);
		assert(read(gate[0], &token, 1) == 1);
		close(gate[0]);
		_exit(h700_write_display_receipt("delayed", uuid, 10) != 0);
	}
	close(gate[0]);
	assert(h700_write_display_receipt("delayed", uuid, 20) == 0);
	assert(write(gate[1], "x", 1) == 1);
	close(gate[1]);
	int status;
	assert(waitpid(delayed, &status, 0) == delayed && WIFEXITED(status) && WEXITSTATUS(status) == 0);
	check("delayed", "v1 boot=42248cd7-52eb-4dd9-88cc-a261d8037b59 raw_ns=20\n");
	puts("display receipt: PASS");
	return 0;
}
