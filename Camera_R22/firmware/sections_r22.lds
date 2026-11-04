OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
 DATA (rw) : ORIGIN = 0x00000000, LENGTH = 0x00001800
 CODE (rx) : ORIGIN = 0x00010000, LENGTH = 0x0000e000
}
SECTIONS {
 .text : {
  KEEP(*(.text.start)) *(.text*) *(.rodata*) *(.srodata*)
  . = ALIGN(4); _etext = .;
 } > CODE
 .data : {
  . = ALIGN(4); _sdata = .; __global_pointer$ = . + 0x800;
  *(.data*) *(.sdata*) . = ALIGN(4); _edata = .;
 } > DATA AT> CODE
 _sidata = LOADADDR(.data);
 .bss (NOLOAD) : {
  . = ALIGN(4); _sbss = .; *(.bss*) *(.sbss*) *(COMMON)
  . = ALIGN(4); _ebss = .;
 } > DATA
 /DISCARD/ : { *(.eh_frame*) *(.comment*) }
 ASSERT(_ebss <= 0x1800, "DATA/BSS encroaches on 2 KiB reserved stack")
 ASSERT(LOADADDR(.data) + SIZEOF(.data) <= 0x1e000, "Firmware exceeds 56 KiB code area")
}
