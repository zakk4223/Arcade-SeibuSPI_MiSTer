; ---------------------------------------------------------------------------
; Seibu SPI hardware constants, as seen by the 386.
;
; Sources: MAME src/mame/seibu/seibuspi.cpp base_map/rise_map/rdft2_map
; (lines 1004-1075), seibu_crtc.cpp:236-243, and rtl/spi_cpu.sv's header map.
; Everything here is verified against BOTH, because the benchmark has to agree
; with MAME, the core and a real PCB or it is measuring three different things.
; ---------------------------------------------------------------------------

; --- main RAM -------------------------------------------------------------
RAM_BASE        equ 0x00000000
RAM_SIZE        equ 0x00040000          ; 256 KB, two TC551664BJ-15

; --- the I/O overlay, 0x400-0x7FF, which shadows main RAM ------------------
IO_CRTC         equ 0x00000400          ; 0x400-0x44F, register file
IO_DECRYPT_KEY  equ 0x00000414          ; tile decryption key (16-bit)
IO_LAYER_BANK   equ 0x0000041A          ; reg_1a: b15 rowscroll, b0 flip
IO_LAYER_EN     equ 0x0000041C          ; ACTIVE LOW: b0 back b1 midl b2 fore
                                        ;             b3 text b4 sprites
IO_SCROLL       equ 0x00000420          ; 6 words: back/midl/fore X,Y
IO_TILEMAP_DMA  equ 0x00000480          ; W: start tilemap DMA (value ignored)
IO_PALETTE_DMA  equ 0x00000484          ; W: start palette DMA
IO_DMA_LENGTH   equ 0x00000490          ; W: (n+1)*2 = bytes
IO_DMA_ADDRESS  equ 0x00000494          ; W: source, byte address in main RAM
IO_DMA_ADDR_HI  equ 0x00000498          ; W: always 0
IO_STATUS       equ 0x00000600          ; R: d0 = video/dma ready (always 1)
IO_INPUTS       equ 0x00000604          ; R: P1/P2 sticks + buttons, ACTIVE LOW
IO_EXCH         equ 0x00000608          ; R: all ones
IO_SYSTEM       equ 0x0000060C          ; R: start/service, ACTIVE LOW
IO_SPRITE_DMA   equ 0x00000560          ; W: start sprite DMA
IO_SOUND_FIFO   equ 0x00000680
IO_SOUND_STAT   equ 0x00000684
IO_Z80_XFER     equ 0x00000688
IO_Z80_ENABLE   equ 0x0000068C
IO_LAYER_BANK2  equ 0x0000068E          ; rf2_layer_bank
IO_DS_RESET     equ 0x000006D0          ; DS2404 1-wire reset / 3-wire RST
IO_DS_DATA_W    equ 0x000006D4          ; DS2404 DQ out
IO_DS_CLK       equ 0x000006D8          ; DS2404 CLK
IO_DS_DATA_R    equ 0x000006DC          ; R: DS2404 DQ in

; The benchmark's own doorbell. Nothing decodes it: in MAME it is plain main
; RAM (harmless, we never read it back), in the core it lands in the I/O window
; and is dropped -- but spi_cpu still raises io_wr, which tb_boot_top exports as
; p_io_wr/p_io_addr/p_io_wdata and tb_boot.cpp already records. That is how the
; Verilator leg gets its results out without touching any RTL.
IO_DOORBELL     equ 0x000004F0

; --- inputs, active low ---------------------------------------------------
IN_P1_UP        equ 0x0001
IN_P1_DOWN      equ 0x0002
IN_P1_LEFT      equ 0x0004
IN_P1_RIGHT     equ 0x0008
IN_P1_B1        equ 0x0010
IN_P1_B2        equ 0x0020
SYS_START1      equ 0x01
SYS_START2      equ 0x02
SYS_SERVICE     equ 0x04

; --- video ----------------------------------------------------------------
; PIXEL_CLOCK 28.636363/4 = 7.159091 MHz, HTOTAL 448, VTOTAL 296
; (seibuspi.cpp:898-906) -> 132,608 pixel clocks = 18.5229 ms = 53.986 Hz.
; At the board's 25.000 MHz (50 MHz XTAL / 2) that is 463,072 CPU clocks.
CPU_CLOCKS_PER_FRAME equ 463072

TEXT_COLS       equ 64                  ; tilemap is 64x32 of 8x8...
TEXT_ROWS       equ 32
VIS_COLS        equ 40                  ; ...and only 320x240 of it is visible
VIS_ROWS        equ 30

; ROTATION. rfjet is ROT270 (seibuspi.cpp:4353), which MAME defines as
; ORIENTATION_SWAP_XY | ORIENTATION_FLIP_Y: a framebuffer pixel (x,y) is shown
; at (y, 319-x). In 8x8 tiles that is
;
;     screen_column = fb_row          screen_line = 39 - fb_col
;
; so a framebuffer ROW appears on screen as a vertical strip -- which is exactly
; how the first version of this ROM came out, a legible table laid out along the
; wrong axis. Text has to run DOWN a framebuffer column instead, with successive
; lines advancing leftwards along the framebuffer's X axis.
;
; The glyphs need no such help: rfjet's fix ROM stores them already rotated, so
; they come out upright under the same transform. That is why the game's own
; "XTF PROJECT" reads correctly in MAME's default view.
;
; The upshot is a 30-character by 40-line screen, and 2 header lines plus 37
; tests plus 1 footer is exactly 40.
TEXT_CHARS      equ 30                  ; characters per readable line
TEXT_LINES      equ 40                  ; readable lines
TEXT_STEP       equ 128                 ; bytes between adjacent characters on a
                                        ; line (one framebuffer row = 64 tiles)

; The DMA source layout the game itself uses, captured in bench/vidinit_trace.txt:
; layer_bank settles at 0x8028, so bit15 (rowscroll) is SET and the tilemap DMA
; is the 0x4000-byte form -- back, back-rs, fore, fore-rs, midl, midl-rs, text.
; Text is therefore the last 0x1000 bytes.
TILEMAP_SRC     equ 0x00038000
TILEMAP_LEN     equ 0x00004000
TEXT_SRC        equ TILEMAP_SRC + 0x3000
PALETTE_SRC     equ 0x0003C000
PALETTE_LEN     equ 0x00003000          ; 6144 pens, matching the game
PAL_BASE_TEXT   equ 5632                ; pen = 5632 + colour*32 + pixel

; The value the game writes to the two DMA triggers. Both MAME and the core
; ignore it; a real PCB is not known to, so write what the game writes.
DMA_TRIGGER_VAL equ 0x00374AEC

; --- our own RAM layout ---------------------------------------------------
; 0x400-0x7FF is the I/O overlay and must stay clear. 0x28000-0x2FFFF is left
; unused on purpose: MAME installs rfjet's idle-loop speedup read handler over
; 0x2894C (seibuspi.cpp:2063), and while it only spins at one specific PC there
; is no reason to have data traffic in that window.
VAR_BASE        equ 0x00000300          ; harness variables
RESULTS_BASE    equ 0x00000800          ; results block, read by MAME's Lua
STACK_TOP       equ 0x00002000
CODE_ARENA      equ 0x00002000          ; timed code is copied here, 128 KB
CODE_ARENA_END  equ 0x00022000
DATA_BUF        equ 0x00030000          ; 32 KB, twice the core's 16 KB D-cache
DATA_BUF_SIZE   equ 0x00008000
DATA_BUF_B      equ DATA_BUF + 0x4000

; --- results block --------------------------------------------------------
; MAME's Lua reads this directly out of main RAM; the same records are streamed
; to IO_DOORBELL for Verilator. Keep the two in step.
RES_MAGIC       equ RESULTS_BASE + 0    ; 'SPIB'
RES_GEN         equ RESULTS_BASE + 4    ; bumped after every completed test
RES_NDONE       equ RESULTS_BASE + 8
RES_WINDOW      equ RESULTS_BASE + 12   ; frames per measurement window
RES_NTESTS      equ RESULTS_BASE + 16
RES_EXC         equ RESULTS_BASE + 20   ; nonzero after an unexpected fault
RES_RUNNING     equ RESULTS_BASE + 24   ; 1 running, 0 finished, 2 faulted
RES_RECS        equ RESULTS_BASE + 32
RES_REC_SIZE    equ 32                  ; name[12], iters_lo, iters_hi, delta, flags
RES_MAGIC_VAL   equ 0x42495053          ; 'SPIB' little-endian

; --- test descriptor ------------------------------------------------------
NAMELEN         equ 12
TD_NAME         equ 0
TD_LO           equ 12
TD_LO_LEN       equ 16
TD_HI           equ 20
TD_HI_LEN       equ 24
TD_DELTA        equ 28
TD_FLAGS        equ 32
TD_SIZE         equ 36

TF_FROM_ROM     equ 0x0001              ; run in place, do not copy to RAM
