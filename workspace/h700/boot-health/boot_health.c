#include "boot_health.h"
#include "../loader/display_contract.h"

#include <limits.h>
#include <string.h>

static uint32_t be32(const unsigned char *p) {
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | p[3];
}

const char *zero_boot_record(const unsigned char *data, size_t size,
                            struct zero_boot_record *record) {
    struct zero_display_contract display;
    if (size != ZERO_LOADER_RECORD_SIZE) return "record length";
    if (memcmp(data, "ZHL1", 4)) return "record magic";
    if (be32(data + 4) != 1) return "record version";
    if (be32(data + 8) != ZERO_LOADER_RECORD_SIZE) return "record declared length";
    record->profile = be32(data + 12);
    record->panel = be32(data + 16);
    record->width = be32(data + 20);
    record->height = be32(data + 24);
    if (!zero_display_profile(record->profile, &display)) return "record profile";
    if (record->panel > 1) return "record panel";
    if (!zero_display_v1_compatible(&display) ||
        record->width != display.lcd_width || record->height != display.lcd_height)
        return "record geometry";
    if (be32(data + 28)) return "record reserved field";
    memcpy(record->build_id, data + 32, sizeof(record->build_id));
    return NULL;
}

static int hex_digit(unsigned char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

const char *zero_boot_expected(const unsigned char *data, size_t size,
                              const struct zero_boot_record *record) {
    size_t i;
    if (size != 64 && !(size == 65 && data[64] == '\n'))
        return "expected build-id length";
    for (i = 0; i < 32; ++i) {
        int hi = hex_digit(data[i * 2]), lo = hex_digit(data[i * 2 + 1]);
        if (hi < 0 || lo < 0) return "expected build-id encoding";
        if ((unsigned char)((hi << 4) | lo) != record->build_id[i])
            return "build-id mismatch";
    }
    return NULL;
}

static int space(unsigned char c) {
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

static int text_valid(const unsigned char *data, size_t size) {
    size_t i;
    if (!size || size > ZERO_HEALTH_TEXT_MAX) return 0;
    for (i = 0; i < size; ++i)
        if (!space(data[i]) && (data[i] < 32 || data[i] > 126)) return 0;
    return 1;
}

const char *zero_boot_cmdline(const unsigned char *data, size_t size,
                             const struct zero_boot_record *record) {
    size_t pos = 0;
    unsigned count = 0;
    const char *panel = record->panel ? "boe" : "old";
    if (!text_valid(data, size)) return "cmdline encoding/length";
    while (pos < size) {
        size_t start, len;
        while (pos < size && space(data[pos])) ++pos;
        start = pos;
        while (pos < size && !space(data[pos])) ++pos;
        len = pos - start;
        if (len >= 8 && !memcmp(data + start, "lcd_type", 8) &&
            (len == 8 || data[start + 8] == '=')) {
            if (++count != 1) return "duplicate lcd_type";
            if (len != 12 || data[start + 8] != '=' ||
                memcmp(data + start + 9, panel, 3)) return "lcd_type mismatch/invalid";
        }
    }
    return count == 1 ? NULL : "missing lcd_type";
}

static void skip_space(const char **p) {
    while (space((unsigned char)**p)) ++*p;
}

static int number(const char **p, uint32_t *value) {
    uint32_t n = 0;
    const char *s = *p;
    skip_space(&s);
    if (*s < '0' || *s > '9') return 0;
    do {
        unsigned digit = (unsigned)(*s++ - '0');
        if (n > (UINT32_MAX - digit) / 10) return 0;
        n = n * 10 + digit;
    } while (*s >= '0' && *s <= '9');
    *value = n;
    *p = s;
    return 1;
}

static int dimensions(const char **p, uint32_t *w, uint32_t *h) {
    if (!number(p, w)) return 0;
    skip_space(p);
    if (*(*p)++ != 'x') return 0;
    return number(p, h);
}

static int token(const char *line, const char *word) {
    size_t n = strlen(word);
    const char *p = line;
    while ((p = strstr(p, word)) != NULL) {
        if ((p == line || space((unsigned char)p[-1])) &&
            (!p[n] || space((unsigned char)p[n]))) return 1;
        ++p;
    }
    return 0;
}

static int no_errors(const char *line) {
    const char *p = line;
    while ((p = strstr(p, "err")) != NULL) {
        uint32_t n;
        char close;
        p += 3;
        if (*p != '[' && *p != ':') return 0;
        close = *p++ == '[' ? ']' : '\0';
        if (!number(&p, &n) || n) return 0;
        if (close ? *p != close : (*p && !space((unsigned char)*p))) return 0;
    }
    return 1;
}

const char *zero_boot_display(const unsigned char *data, size_t size,
                             const struct zero_boot_record *record) {
    size_t pos = 0;
    unsigned mgr = 0, lcd = 0, lcd_error = 0, frame = 0;
    if (!text_valid(data, size)) return "display encoding/length";
    while (pos < size) {
        char line[2048];
        size_t start = pos, len;
        const char *p;
        uint32_t w, h;
        while (pos < size && data[pos] != '\n') ++pos;
        len = pos - start;
        if (pos < size) ++pos;
        if (len >= sizeof(line)) return "display line too long";
        memcpy(line, data + start, len);
        line[len] = '\0';
        p = line;
        skip_space(&p);
        if (!no_errors(p)) return "display error/malformed error counter";
        if (!strncmp(p, "mgr", 3)) {
            if (strncmp(p, "mgr0:", 5) || ++mgr != 1) return "display manager";
            p += 5;
            if (!dimensions(&p, &w, &h) || !space((unsigned char)*p) ||
                w != record->width || h != record->height)
                return "manager geometry";
            if (!strstr(p, "err[0]") || !token(p, "unblank") || token(p, "blank"))
                return "manager blank/error";
        } else if (!strncmp(p, "lcd output", 10) && space((unsigned char)p[10])) {
            if (++lcd != 1) return "duplicate LCD";
            p = strstr(p + 10, "fps:");
            if (!p) return "LCD fps/geometry missing";
            p += 4;
            while (*p && !space((unsigned char)*p)) ++p;
            if (!dimensions(&p, &w, &h) || w != record->width || h != record->height)
                return "LCD geometry";
            skip_space(&p);
            if (*p) return "LCD geometry suffix";
        } else if (!strncmp(p, "err:", 4)) {
            if (lcd != 1 || ++lcd_error != 1) return "LCD error counter placement";
        } else if (!strncmp(p, "BUF", 3) && space((unsigned char)p[3]) && token(p, "enable")) {
            uint32_t x, y;
            p = strstr(p, "frame[");
            if (!p) return "BUF frame missing";
            p += 6;
            if (!number(&p, &x) || *p++ != ',' || !number(&p, &y) || *p++ != ',' ||
                !number(&p, &w) || *p++ != ',' || !number(&p, &h)) return "BUF frame malformed";
            skip_space(&p);
            if (*p != ']' || x || y || w != record->width || h != record->height)
                return "BUF frame geometry";
            ++frame;
        }
    }
    if (mgr != 1 || lcd != 1 || lcd_error != 1 || !frame) return "inactive/incomplete LCD display";
    return NULL;
}
