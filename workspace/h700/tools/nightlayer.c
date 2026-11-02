// nightlayer — night brightness for programs that draw through fb0 instead of our DE layer: Tools > Files
// (DinguxCommander's SDL/Mali path) and platform.c's fbdev fallback. fb0 scans out as DE channel 1 layer 0,
// configured by the fbdev driver with buffer addresses that SET_CONFIG2 cannot take back (it wants an ION fd;
// writing a read-back config disabled the layer, 2026-11-02). So fb0's layer is left alone and a translucent
// black COLOR layer goes ABOVE it: black at (255 - a) over the picture equals the picture at a over black,
// the night alpha disp_commit gives our own layer (platform.c).
//   nightlayer <alpha>   1..254 shows the shade for that night alpha, 255 removes it
//   nightlayer           reads the night step from .userdata/h700/night (the libmsettings file) and applies it
// Raw 220-byte config ABI per MyMinUI's h700 finding (platform.c disp_pack).
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <unistd.h>
#define DISP_LAYER_SET_CONFIG2 0x49
#define NIGHT_FILE "/mnt/mmc/.userdata/h700/night"
static const int night_alpha[4] = { 190, 160, 133, 107 }; // keep in step with msettings.c

int main(int argc, char* argv[]) {
	int alpha = 255;
	if (argc > 1) alpha = atoi(argv[1]);
	else {
		FILE* f = fopen(NIGHT_FILE, "r"); int n = 0;
		if (f) { if (fscanf(f, "%d", &n) != 1) n = 0; fclose(f); }
		if (n >= 1 && n <= 4) alpha = night_alpha[n - 1];
	}
	if (alpha < 1 || alpha > 255) alpha = 255;
	int w = 640, h = 480; // the panel; read it from fb0 so the RG34XX's 720 wide is covered
	FILE* vs = fopen("/sys/class/graphics/fb0/virtual_size", "r");
	if (vs) { int vw, vh; if (fscanf(vs, "%d,%d", &vw, &vh) == 2 && vw > 0) w = vw; fclose(vs); }
	FILE* m = fopen("/sys/class/disp/disp/attr/sys", "r"); // "lcd output ... 640x 480": the real panel height
	if (m) { char line[256]; while (fgets(line, sizeof(line), m)) { char* p = strstr(line, "lcd output");
		if (p) { char* x = strrchr(line, 'x'); int lw = 0, lh = 0;
			if (x && sscanf(x - 5, "%d", &lw) == 1 && sscanf(x + 1, "%d", &lh) == 1 && lw > 0 && lh > 0) { w = lw; h = lh; }
			break; } } fclose(m); }

	int fd = open("/dev/disp", O_RDWR);
	if (fd < 0) { perror("nightlayer: /dev/disp"); return 1; }
	uint32_t raw[55];
	memset(raw, 0, sizeof(raw));
	raw[0] = 1;                                         // LAYER_MODE_COLOR
	raw[1] = ((uint32_t)(255 - alpha) << 16) | (1u << 8) | 16u; // shade opacity, global alpha, zorder 16 (above fb0)
	raw[4] = w; raw[5] = h;
	raw[8] = 0xFF000000u;                               // black
	raw[52] = alpha < 255;
	raw[53] = 0; raw[54] = 0;                           // channel 0 layer 0, the slot disp_backdrop uses
	unsigned long args[4] = { 0, (unsigned long)(uintptr_t)raw, 1, 0 };
	int ret = ioctl(fd, DISP_LAYER_SET_CONFIG2, &args);
	close(fd);
	printf("nightlayer: alpha %d %dx%d (%d)\n", alpha, w, h, ret);
	return 0;
}
