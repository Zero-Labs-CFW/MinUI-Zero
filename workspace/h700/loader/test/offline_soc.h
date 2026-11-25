#ifndef OFFLINE_SOC_H
#define OFFLINE_SOC_H
#include <stdint.h>
struct mock_write { unsigned long addr; uint32_t value; uint64_t ticks; };
extern struct mock_write mock_writes[128];
extern unsigned mock_count;
void mock_reset(void);
void mock_set(unsigned long addr, uint32_t value);
void mock_reset_escape(int enabled);
void mock_clock(uint64_t now, uint64_t step);
void mock_forbid_read(unsigned long addr);
#include <setjmp.h>
extern jmp_buf mock_jmp;
#endif
