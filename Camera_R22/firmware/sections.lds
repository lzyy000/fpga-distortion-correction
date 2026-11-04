OUTPUT_ARCH(riscv)
ENTRY(_start)
MEMORY {
 DATA (rw) : ORIGIN = 0x00000000, LENGTH = 0x00000c00
 CODE (rx) : ORIGIN = 0x00001000, LENGTH = 0x00007000
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
 ASSERT(_ebss <= 0xc00, "DATA/BSS encroaches on 1 KiB reserved stack")
 ASSERT(LOADADDR(.data) + SIZEOF(.data) <= 0x8000, "Firmware exceeds 28 KiB code area")
}
