/* Independent assembler oracle for verify-monitor.md D1, not the loader's word array. */
.syntax unified
.arch armv7-a
.arch_extension sec
.arm
.text
.global test_stub
test_stub:
	ldr r0, box_fid
	ldr r1, fdt_addr
	mov r2, #0
	mov r3, #0
	dsb sy
	isb sy
	smc #0
	ldr r0, kernel_fid
	ldr r1, kernel_addr
	ldr r2, fdt_addr
	mov r3, #1
	dsb sy
	isb sy
	smc #0
returned:
	wfi
	b returned
box_fid: .word 0x8000ff14
kernel_fid: .word 0x8000ff04
kernel_addr: .word 0x40080000
fdt_addr: .word 0x4a200000
