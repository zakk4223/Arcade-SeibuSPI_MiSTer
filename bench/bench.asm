; ===========================================================================
; Seibu SPI 386 IPC benchmark ROM
;
; One 2 MB program image that runs unmodified on MAME, on the Verilator model
; of the core, on the MiSTer core, and on a real SXX2C cartridge, and puts its
; results on the game's own text layer.
;
; Why: the core clocks z386 at 28.636364 MHz where the board runs a 386DX at
; 25.000 MHz, and z386x additionally has 16 KB L1 I- and D-caches that the board
; has no equivalent of. How much faster that makes it PER CLOCK has never been
; measured (PLAN.md 16.7, README "Future work" #1). This measures it, per
; instruction class.
;
; Method: two-length differencing over a vblank-bounded window. See tests.inc
; for the full argument; the short version is that every test is built at two
; lengths and only the difference is reported, so loop overhead, the interrupt
; handler and the harness all cancel without ever being measured.
;
; Build:  nasm -f bin -o bench.bin bench.asm
; Split:  python3 build_rom.py bench.bin
; ===========================================================================

bits 32
org 0x00200000                  ; the ROM's own address; also mirrored at
                                ; 0xFFE00000 for the real-mode reset vector

%include "spi.inc"
%include "tests.inc"

ROM_BASE        equ 0x00200000
ROM_SIZE        equ 0x00200000

; A label's offset as the reset-time CS (base 0xFFFF0000) sees it. Only valid
; for labels in the last 64 KB of the ROM.
%define RM(x)   ((x) - 0x003F0000)

; NASM treats a bare label as section-relative even in -f bin, so `label & 0xFFFF`
; is rejected. The difference of two labels IS a scalar, so fold the org back in
; by hand wherever a label has to be taken apart.
%define LIN(x)  (((x) - $$) + ROM_BASE)

; ---------------------------------------------------------------------------
; Configuration block. Sits at ROM offset 0 so build_rom.py can find and patch
; it without knowing anything about the assembly.
; ---------------------------------------------------------------------------
cfg_block:
cfg_magic:      dd 0x47464342           ; 'BCFG'
cfg_window:     dd 8                    ; frames per measurement window
cfg_mask0:      dd 0xFFFFFFFF           ; tests 0-31 enabled
cfg_mask1:      dd 0xFFFFFFFF           ; tests 32-63 enabled
cfg_reserved:   times 4 dd 0

; ---------------------------------------------------------------------------
; Harness variables. All in main RAM; the ROM is not writable.
; ---------------------------------------------------------------------------
frame_count     equ VAR_BASE + 0
frame_start     equ VAR_BASE + 4
frame_end       equ VAR_BASE + 8
ebp_start       equ VAR_BASE + 12
ebp_end         equ VAR_BASE + 16
saved_esp       equ VAR_BASE + 20
invalid         equ VAR_BASE + 24
v_window        equ VAR_BASE + 28
v_test          equ VAR_BASE + 32
v_page          equ VAR_BASE + 36
v_prevpad       equ VAR_BASE + 40
v_blockptr      equ VAR_BASE + 44
v_iters_lo      equ VAR_BASE + 48
v_iters_hi      equ VAR_BASE + 52
v_ndone         equ VAR_BASE + 56
v_npages        equ VAR_BASE + 60
v_running       equ VAR_BASE + 64
; v_tmp holds ONE value and nothing borrows the words after it: v_tmp+4 is
; v_pagebase, and draw_one_row scribbling a result there once truncated the
; table to two rows and looked exactly like a video bug.
v_tmp           equ VAR_BASE + 68
v_pagebase      equ VAR_BASE + 72
v_il            equ VAR_BASE + 76
v_ih            equ VAR_BASE + 80
v_dl            equ VAR_BASE + 84
v_row           equ VAR_BASE + 88
v_cyc           equ VAR_BASE + 92

DISARMED        equ 0x7FFFFFFF
ROWS_PER_PAGE   equ TEXT_LINES - 3

; ===========================================================================
; 32-bit entry. Reached by the far jump in the real-mode bring-up stub.
; ===========================================================================
flat_entry:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov fs, ax
    mov gs, ax
    mov esp, STACK_TOP
    cld
    lidt [idtr]

    ; --- clear the RAM we are about to use --------------------------------
    ; 0x400-0x7FF is the I/O overlay: writing zeroes through it would trigger
    ; DMAs and reprogram the CRTC, so clear around it in two runs.
    xor eax, eax
    mov edi, 0x00000000
    mov ecx, 0x400 / 4
    rep stosd
    mov edi, 0x00000800
    mov ecx, (RAM_SIZE - 0x800) / 4
    rep stosd

    mov dword [frame_count], 0
    mov dword [frame_start], DISARMED
    mov dword [frame_end],   DISARMED
    mov dword [v_page], 0
    mov dword [v_test], 0
    mov dword [v_ndone], 0
    mov dword [v_running], 1
    mov dword [RES_RUNNING], 1
    mov eax, [cfg_window]
    mov [v_window], eax
    mov eax, NTESTS + ROWS_PER_PAGE - 1
    xor edx, edx
    mov ecx, ROWS_PER_PAGE
    div ecx
    mov [v_npages], eax

    call vidinit_replay
    call build_palette
    call prepare_buffers
    call text_clear
    call results_init

    ; Bring the text layer up before anything is measured, so a blank screen
    ; means the ROM died in bring-up and not in a test.
    call draw_screen
    call video_refresh

    ; The vblank ISR is the whole time base. Nothing below works without it.
    sti
    call wait_frames_2

    ; ---------------------------------------------------------------------
    ; Run every enabled test.
    ; ---------------------------------------------------------------------
    mov dword [v_test], 0
.next_test:
    mov eax, [v_test]
    cmp eax, NTESTS
    jae .all_done

    call test_enabled
    test eax, eax
    jz .skip

    call run_one_test
    call results_store
    call doorbell_emit
    call draw_screen
    call video_refresh

.skip:
    inc dword [v_test]
    jmp .next_test

.all_done:
    mov dword [v_running], 0
    mov dword [RES_RUNNING], 0
    call draw_screen
    call video_refresh

    ; Idle: keep servicing vblank and let the operator page through the
    ; results. On MAME and in Verilator the results have already been read out
    ; of the results block and the doorbell stream; this loop is for the two
    ; targets whose only output is a photograph.
.idle:
    call poll_paging
    jmp .idle

; ===========================================================================
; The measurement window
;
; The workload is `<init>; .loop: <prologue> <n copies> dec ebp; jnz .loop`,
; entered with EBP = 0x7FFFFFFF. Nothing inside it is polled. The vblank ISR
; snapshots EBP on the window's first and last frames, and on the last one it
; rewrites the stacked return EIP so the loop is abandoned exactly there. The
; window is therefore an exact whole number of frames and the loop pays nothing
; per iteration for being measured.
;
; in:  eax = address of the block to call
; out: eax = iterations executed inside the window (0 if invalid)
; ===========================================================================
measure:
    mov [v_blockptr], eax
    cli
    mov eax, [frame_count]
    add eax, 2                          ; let the first window frame be a whole
    mov [frame_start], eax              ; one, not the remainder of this one
    add eax, [v_window]
    mov [frame_end], eax
    mov dword [ebp_start], 0
    mov dword [ebp_end], 0
    mov dword [invalid], 1
    mov [saved_esp], esp
    mov ebp, 0x7FFFFFFF
    sti
    call [v_blockptr]

    ; Falling through here means the loop ran out of iterations before the
    ; window closed. That never happens with a 2^31 counter, but a wrong answer
    ; is worse than no answer, so say so rather than report a truncated count.
    mov dword [invalid], 1
    jmp measure_finish

; The ISR's redirect target. It arrives by IRET, so ESP is wherever the loop
; happened to be; restore the value saved before the call and drop the loop's
; return address with it.
bench_exit:
    mov esp, [saved_esp]
    mov dword [invalid], 0

measure_finish:
    cli
    mov dword [frame_start], DISARMED
    mov dword [frame_end],   DISARMED
    sti
    cmp dword [invalid], 0
    jne .bad
    mov eax, [ebp_start]
    sub eax, [ebp_end]
    ret
.bad:
    xor eax, eax
    ret

; ---------------------------------------------------------------------------
; Run both lengths of the test in [v_test], leaving the counts in
; v_iters_lo / v_iters_hi.
; ---------------------------------------------------------------------------
run_one_test:
    ; REP MOVSD writes into the same 32 KB the pointer rings are threaded
    ; through, so rebuild them before each length rather than letting one test
    ; quietly corrupt the next.
    call prepare_buffers
    call test_descriptor            ; -> esi
    mov eax, [esi + TD_FLAGS]
    test eax, TF_FROM_ROM
    jnz .rom_lo

    mov ecx, [esi + TD_LO_LEN]
    mov eax, [esi + TD_LO]
    call copy_block
    mov eax, CODE_ARENA
    jmp .go_lo
.rom_lo:
    mov eax, [esi + TD_LO]
.go_lo:
    call measure
    mov [v_iters_lo], eax

    call prepare_buffers
    call test_descriptor
    mov eax, [esi + TD_FLAGS]
    test eax, TF_FROM_ROM
    jnz .rom_hi

    mov ecx, [esi + TD_HI_LEN]
    mov eax, [esi + TD_HI]
    call copy_block
    mov eax, CODE_ARENA
    jmp .go_hi
.rom_hi:
    mov eax, [esi + TD_HI]
.go_hi:
    call measure
    mov [v_iters_hi], eax
    ret

; in: eax = source, ecx = length. Copies into CODE_ARENA.
copy_block:
    mov esi, eax
    mov edi, CODE_ARENA
    add ecx, 3
    shr ecx, 2
    rep movsd
    ret

; out: esi = descriptor for test [v_test]
test_descriptor:
    mov eax, [v_test]
    mov edx, TD_SIZE
    mul edx
    mov esi, test_table
    add esi, eax
    ret

; out: eax = nonzero if test [v_test] is enabled by the config mask
test_enabled:
    mov ecx, [v_test]
    mov eax, [cfg_mask0]
    cmp ecx, 32
    jb .lo
    mov eax, [cfg_mask1]
    sub ecx, 32
.lo:
    shr eax, cl
    and eax, 1
    ret

wait_frames_2:
    mov eax, [frame_count]
    add eax, 2
.w: cmp [frame_count], eax
    jb .w
    ret

; ===========================================================================
; Interrupt handling
; ===========================================================================
; Vblank, vector 0x20. The only interrupt on the board -- there is no PIC and
; no PIT; the line runs straight into the 386's INTR.
;
; After PUSHAD the stack is, from ESP upward:
;   +0 EDI  +4 ESI  +8 EBP  +12 ESP  +16 EBX  +20 EDX  +24 ECX  +28 EAX
;   +32 EIP +36 CS  +40 EFLAGS
isr_vblank:
    pushad
    inc dword [frame_count]
    mov eax, [frame_count]
    cmp eax, [frame_start]
    jb  .out
    ja  .maybe_end

    mov ecx, [esp + 8]                  ; EBP as the loop left it
    mov [ebp_start], ecx
    jmp .out

.maybe_end:
    cmp eax, [frame_end]
    jb  .out
    mov ecx, [esp + 8]
    mov [ebp_end], ecx
    mov dword [frame_start], DISARMED
    mov dword [frame_end],   DISARMED
    mov dword [esp + 32], bench_exit    ; abandon the loop, exactly here
.out:
    popad
    iret

; Anything else is a fault we did not plan for. Say so on screen rather than
; wedging silently -- a blank screen and a hung screen look the same from the
; other side of a cabinet.
exc_common:
    mov esp, STACK_TOP
    mov dword [RES_EXC], 1
    mov dword [v_running], 2
    mov dword [RES_RUNNING], 2
    call draw_screen
    call video_refresh
.hang:
    jmp .hang

; ===========================================================================
; Video bring-up
; ===========================================================================
; Replay, verbatim and in order, every register write the real rfjet program
; makes between reset and its first tilemap DMA. This is how the benchmark gets
; a real PCB into a working video state without reverse-engineering the RISE
; chip: the block includes the six 16-bit words the game feeds to the tile
; decryption key at 0x414, which MAME only logs (seibuspi_v.cpp:140) and the
; core hardcodes as TKEY*_RFJET. See bench/vidinit_trace.txt.
vidinit_replay:
    mov esi, vidinit_table
    mov ecx, VIDINIT_COUNT
.next:
    mov eax, [esi]                      ; address, bit31 set for a 32-bit store
    mov edx, [esi + 4]
    add esi, 8
    test eax, 0x80000000
    jnz .dword
    mov [eax], dx
    jmp .step
.dword:
    and eax, 0x7FFFFFFF
    mov [eax], edx
.step:
    dec ecx
    jnz .next
    ret

; The palette DMA source. 6144 pens of BGR555, two to a dword, exactly the span
; the game itself transfers. Everything is black except the 32 pens of text
; colour bank 0, which are copied from the values the REAL GAME leaves there.
;
; That matters more than it looks. This is a shaded font: over tiles 0x20-0x5F
; it uses exactly seven pens -- 0, 2, 4, 6, 8, 15 and the transparent 31 -- and
; the letter shape lives in the SHADING, not in the silhouette. Pen 15 is the
; black outline and 0 through 8 are a bright-to-dark grey ramp. Filling the bank
; with white, which is what this did first, turns every glyph into a solid blob
; that cannot be read at all.
build_palette:
    xor eax, eax
    mov edi, PALETTE_SRC
    mov ecx, PALETTE_LEN / 4
    rep stosd

    mov esi, text_pens
    mov edi, PALETTE_SRC + (PAL_BASE_TEXT * 2)
    mov ecx, 16 / 2                     ; pens 0-15; 16-31 stay black
    rep movsd
    ret

; Text colour bank 0 as rfjet's own program sets it up, dumped straight out of
; its palette buffer. Two BGR555 pens to a dword, even pen in the low half.
align 4
text_pens:
    dd 0x6F7B739C                       ; pen  0 (28,28,28)   pen  1 (27,27,27)
    dd 0x63186B5A                       ; pen  2 (26,26,26)   pen  3 (24,24,24)
    dd 0x52945AD6                       ; pen  4 (22,22,22)   pen  5 (20,20,20)
    dd 0x46314E73                       ; pen  6 (19,19,19)   pen  7 (17,17,17)
    dd 0x35AD3DEF                       ; pen  8 (15,15,15)   pen  9 (13,13,13)
    dd 0x25292D6B                       ; pen 10 (11,11,11)   pen 11 ( 9, 9, 9)
    dd 0x7C1F7C1F                       ; pens 12, 13: magenta in the game too,
                                        ; and unreachable from tiles 0x20-0x5F
    dd 0x00007BDE                       ; pen 14 (30,30,30)   pen 15 black

; Push the composed palette and tilemap out to the video hardware. Both DMAs
; take their source from 0x494 and are started by a write whose value is
; ignored; the value used is the one the game writes, on the principle that a
; real PCB is the one target that cannot be asked.
video_refresh:
    mov dword [IO_DMA_ADDRESS], PALETTE_SRC
    mov word  [IO_DMA_LENGTH], (PALETTE_LEN / 2) - 1
    mov dword [IO_PALETTE_DMA], DMA_TRIGGER_VAL

    mov dword [IO_DMA_ADDRESS], TILEMAP_SRC
    mov dword [IO_DMA_ADDR_HI], 0
    mov word  [IO_DMA_LENGTH], (TILEMAP_LEN / 2) - 1
    mov dword [IO_TILEMAP_DMA], DMA_TRIGGER_VAL

    ; Active low: text on, back/midl/fore/sprites off.
    mov dword [IO_LAYER_EN], 0x17
    ret

; ===========================================================================
; Data buffers
; ===========================================================================
; DATA_BUF is 32 KB, twice the core's D-cache. Two pointer rings are threaded
; through it at a 64-byte node pitch -- four of the core's 16-byte cache lines,
; so consecutive hops can never share one:
;   dword 0 of each node: the LARGE ring, all 512 nodes across the full 32 KB
;   dword 1 of each node: the SMALL ring, 64 nodes inside the first 4 KB
; Both strides are coprime with their node count, so each is a single cycle
; that visits every node.
prepare_buffers:
    xor eax, eax
    mov edi, DATA_BUF
    mov ecx, DATA_BUF_SIZE / 4
    rep stosd

    xor ecx, ecx                        ; large ring, 512 nodes, stride 179
.big:
    mov eax, ecx
    add eax, 179
    and eax, 511
    shl eax, 6
    add eax, DATA_BUF
    mov edx, ecx
    shl edx, 6
    mov [DATA_BUF + edx], eax
    inc ecx
    cmp ecx, 512
    jb .big

    xor ecx, ecx                        ; small ring, 64 nodes, stride 29
.small:
    mov eax, ecx
    add eax, 29
    and eax, 63
    shl eax, 6
    add eax, DATA_BUF
    mov edx, ecx
    shl edx, 6
    mov [DATA_BUF + edx + 4], eax
    inc ecx
    cmp ecx, 64
    jb .small
    ret

; ===========================================================================
; Results block and the Verilator doorbell
; ===========================================================================
results_init:
    mov dword [RES_MAGIC], RES_MAGIC_VAL
    mov dword [RES_GEN], 0
    mov dword [RES_NDONE], 0
    mov eax, [v_window]
    mov [RES_WINDOW], eax
    mov dword [RES_NTESTS], NTESTS
    mov dword [RES_EXC], 0
    mov dword [RES_RUNNING], 1
    ret

; Append the finished test to the results block. MAME's Lua polls RES_GEN and
; reads these records straight out of main RAM.
results_store:
    call test_descriptor
    mov eax, [v_test]
    mov edx, RES_REC_SIZE
    mul edx
    lea edi, [RES_RECS + eax]

    push edi
    mov ecx, NAMELEN
    rep movsb                           ; esi is the descriptor: name comes first
    pop edi

    mov eax, [v_iters_lo]
    mov [edi + 12], eax
    mov eax, [v_iters_hi]
    mov [edi + 16], eax
    call test_descriptor
    mov eax, [esi + TD_DELTA]
    mov [edi + 20], eax
    mov eax, [esi + TD_FLAGS]
    mov [edi + 24], eax
    mov dword [edi + 28], 1             ; valid

    inc dword [v_ndone]
    mov eax, [v_ndone]
    mov [RES_NDONE], eax
    inc dword [RES_GEN]
    ret

; Stream the same record to the doorbell address. Nothing decodes it: in MAME
; it is plain RAM and in the core it is dropped, but spi_cpu still raises io_wr
; and tb_boot.cpp records every I/O write -- so this is how the Verilator run
; reports without any RTL change.
doorbell_emit:
    call test_descriptor
    mov eax, [v_test]
    or  eax, 0x5350B000                 ; 'SP' + a record marker
    mov [IO_DOORBELL], eax
    mov eax, [esi + 0]
    mov [IO_DOORBELL], eax
    mov eax, [esi + 4]
    mov [IO_DOORBELL], eax
    mov eax, [esi + 8]
    mov [IO_DOORBELL], eax
    mov eax, [v_iters_lo]
    mov [IO_DOORBELL], eax
    mov eax, [v_iters_hi]
    mov [IO_DOORBELL], eax
    mov eax, [esi + TD_DELTA]
    mov [IO_DOORBELL], eax
    mov eax, [v_window]
    mov [IO_DOORBELL], eax
    ret

; ===========================================================================
; Text output
; ===========================================================================
; The text layer is 64x32 tiles of 8x8 with only 40x30 visible. One 16-bit word
; per tile: code in bits 0-11, colour bank in 12-15. rfjet's fix ROM maps tile
; index directly to ASCII over 0x20-0x5F (uppercase only), which is what makes
; a printf possible at all -- see bench/tools/dump_charset.py.
text_clear:
    mov edi, TEXT_SRC
    mov eax, 0x00200020                 ; two spaces
    mov ecx, (TEXT_COLS * TEXT_ROWS) / 2
    rep stosd
    ret

; Screen position -> tilemap address, through the ROT270 transform documented
; in spi.inc: screen_column = fb_row, screen_line = 39 - fb_col.
;
; in: dl = screen line (0..39), dh = screen column (0..29)
; out: edi = tile address
text_addr:
    movzx eax, dh                       ; fb_row = screen column
    shl eax, 6                          ; * TEXT_COLS
    movzx ecx, dl
    neg ecx
    add ecx, VIS_COLS - 1               ; fb_col = 39 - screen line
    add eax, ecx
    shl eax, 1
    lea edi, [TEXT_SRC + eax]
    ret

; in: esi = NUL-terminated string, edi = tile address
text_puts:
    push eax
.l:
    mov al, [esi]
    inc esi
    test al, al
    jz .e
    mov ah, 0
    mov [edi], ax
    add edi, TEXT_STEP
    jmp .l
.e:
    pop eax
    ret

; in: al = character, edi = tile address
text_putc:
    mov ah, 0
    mov [edi], ax
    add edi, TEXT_STEP
    ret

; Right-aligned unsigned decimal.
; in: eax = value, edi = tile address, ecx = field width
text_putdec:
    push edi
    push ecx
    push ebx
    push eax
    lea eax, [ecx - 1]
    shl eax, 7                          ; (width - 1) * TEXT_STEP
    add edi, eax
    pop eax
    mov ebx, 10
.d:
    xor edx, edx
    div ebx
    add dl, '0'
    mov [edi], dx                       ; dh is 0: the remainder is < 10
    sub edi, TEXT_STEP
    dec ecx
    test eax, eax
    jnz .d
    test ecx, ecx
    jz .done
.pad:
    mov word [edi], 0x0020
    sub edi, TEXT_STEP
    dec ecx
    jnz .pad
.done:
    pop ebx
    pop ecx
    pop edi
    ret

; A value in hundredths, right-aligned as "ddd.dd" in `ecx` columns.
; in: eax = value*100, edi = tile address, ecx = field width (>= 4)
text_putfix:
    push edi
    push ecx
    push ebx
    push eax
    lea eax, [ecx - 1]
    shl eax, 7
    add edi, eax
    pop eax
    mov ebx, 10
    xor edx, edx
    div ebx
    add dl, '0'
    mov [edi], dx
    sub edi, TEXT_STEP
    xor edx, edx
    div ebx
    add dl, '0'
    mov [edi], dx
    sub edi, TEXT_STEP
    mov word [edi], 0x002E              ; '.'
    sub edi, TEXT_STEP
    sub ecx, 3
.d:
    xor edx, edx
    div ebx
    add dl, '0'
    mov [edi], dx
    sub edi, TEXT_STEP
    dec ecx
    test eax, eax
    jnz .d
    test ecx, ecx
    jz .done
.pad:
    mov word [edi], 0x0020
    sub edi, TEXT_STEP
    dec ecx
    jnz .pad
.done:
    pop ebx
    pop ecx
    pop edi
    ret

; ===========================================================================
; The screen
;
; 30 characters by 40 lines, which is what the ROT270 transform leaves of a
; 40x30 tilemap. Two header lines, one line per test, one footer -- 37 tests
; fit exactly, so in practice there is only ever one page.
;
;   col 0-11   test name, exactly as bench/gen_tests.py spells it
;   col 13-20  iterations completed at the HI length inside one window: the
;              raw measurement, the thing actually observed
;   col 22-28  the derived cycles per unit, ASSUMING the board's 25.000 MHz.
;              On the core, which runs 14.5% fast, this reads correspondingly
;              low; bench/analyze.py redoes it with the right clock.
; ===========================================================================
COL_ITERS       equ 13
W_ITERS         equ 8
COL_CYC         equ 22
W_CYC           equ 7

draw_screen:
    call text_clear

    xor edx, edx                        ; line 0, column 0
    call text_addr
    mov esi, s_title
    call text_puts

    mov dx, 0x1000                      ; column 16
    call text_addr
    mov esi, s_w
    call text_puts
    mov dx, 0x1200                      ; column 18
    call text_addr
    mov eax, [v_window]
    mov ecx, 3
    call text_putdec

    ; The page indicator only earns its space when there is more than one.
    cmp dword [v_npages], 1
    jbe .hdr
    mov dx, 0x1700
    call text_addr
    mov esi, s_p
    call text_puts
    mov dx, 0x1800
    call text_addr
    mov eax, [v_page]
    inc eax
    mov ecx, 1
    call text_putdec
    mov dx, 0x1900
    call text_addr
    mov al, '/'
    call text_putc
    mov dx, 0x1A00
    call text_addr
    mov eax, [v_npages]
    mov ecx, 1
    call text_putdec

.hdr:
    mov dx, 0x0001                      ; line 1, column 0
    call text_addr
    mov esi, s_hdr
    call text_puts

    mov eax, [v_page]
    mov edx, ROWS_PER_PAGE
    mul edx
    mov [v_pagebase], eax
    mov dword [v_row], 0
.row:
    mov eax, [v_row]
    cmp eax, ROWS_PER_PAGE
    jae .footer
    add eax, [v_pagebase]
    cmp eax, NTESTS
    jae .footer
    mov [v_tmp], eax
    call draw_one_row
    inc dword [v_row]
    jmp .row

.footer:
    mov dx, 0x0027                      ; line 39
    call text_addr
    cmp dword [v_running], 2
    je .exc
    cmp dword [v_running], 0
    jne .ret
    mov esi, s_done
    cmp dword [v_npages], 1
    jbe .say
    mov esi, s_done_pages
    jmp .say
.exc:
    mov esi, s_exc
.say:
    call text_puts
.ret:
    ret

; Draws test [v_tmp] on screen line [v_row]+2. Takes and returns nothing in
; registers -- the callers have no register state worth protecting and every
; helper below clobbers something.
draw_one_row:
    mov eax, [v_tmp]
    mov edx, TD_SIZE
    mul edx
    mov esi, test_table
    add esi, eax                        ; descriptor: name is at offset 0

    mov eax, [v_row]
    add eax, 2
    mov dl, al
    mov dh, 0
    call text_addr
    mov ecx, NAMELEN
.name:
    mov al, [esi]
    inc esi
    mov ah, 0
    mov [edi], ax
    add edi, TEXT_STEP
    dec ecx
    jnz .name

    mov eax, [v_tmp]
    mov edx, RES_REC_SIZE
    mul edx
    lea esi, [RES_RECS + eax]
    cmp dword [esi + 28], 0
    je .out                             ; not measured yet, leave the line blank

    mov eax, [esi + 12]
    mov [v_il], eax
    mov eax, [esi + 16]
    mov [v_ih], eax
    mov eax, [esi + 20]
    mov [v_dl], eax

    mov eax, [v_row]
    add eax, 2
    mov dl, al
    mov dh, COL_ITERS
    call text_addr
    mov eax, [v_ih]
    mov ecx, W_ITERS
    call text_putdec

    call cycles_x100
    mov [v_cyc], eax
    mov eax, [v_row]
    add eax, 2
    mov dl, al
    mov dh, COL_CYC
    call text_addr
    mov eax, [v_cyc]
    mov ecx, W_CYC
    call text_putfix
.out:
    ret

; cycles-per-unit * 100, from v_il / v_ih / v_dl.
;
;   N = CPF * window * 100        (below 2^32 for any window up to 64)
;   result = (N/iters_hi - N/iters_lo) / delta
;
; Both quotients are tens of thousands, so truncation costs at most one part in
; ten thousand -- far below the measurement's own noise.
cycles_x100:
    mov eax, [v_ih]
    test eax, eax
    jz .zero
    mov eax, [v_il]
    test eax, eax
    jz .zero
    mov eax, [v_dl]
    test eax, eax
    jz .zero

    mov eax, CPU_CLOCKS_PER_FRAME
    mov edx, [v_window]
    mul edx
    mov ecx, 100
    mul ecx                             ; edx:eax = N
    mov ebx, eax
    mov ecx, edx

    mov eax, ebx
    mov edx, ecx
    div dword [v_ih]
    mov esi, eax

    mov eax, ebx
    mov edx, ecx
    div dword [v_il]
    sub esi, eax
    jc .zero                            ; HI came out faster than LO: nonsense

    mov eax, esi
    xor edx, edx
    div dword [v_dl]
    ret
.zero:
    xor eax, eax
    ret

; P1 left/right pages the table. With 37 tests there is only one page and this
; does nothing; it is here so that adding tests past the 38th does not silently
; drop them off the bottom of the screen.
poll_paging:
    cmp dword [v_npages], 1
    jbe .none
    mov eax, [IO_INPUTS]
    not eax                             ; inputs are active low
    and eax, IN_P1_LEFT | IN_P1_RIGHT
    mov edx, [v_prevpad]
    mov [v_prevpad], eax
    xor edx, eax
    and eax, edx                        ; rising edges only
    jz .none

    test eax, IN_P1_RIGHT
    jz .left
    mov eax, [v_page]
    inc eax
    cmp eax, [v_npages]
    jb .set
    xor eax, eax
    jmp .set
.left:
    mov eax, [v_page]
    test eax, eax
    jnz .dec
    mov eax, [v_npages]
.dec:
    dec eax
.set:
    mov [v_page], eax
    call draw_screen
    call video_refresh
.none:
    ret

; ===========================================================================
; Strings
; ===========================================================================
; Every one of these has to fit in TEXT_CHARS (30).
s_title:      db 'SPI 386 BENCH', 0
s_w:          db 'W=', 0
s_p:          db 'P', 0
s_hdr:        db 'TEST            ITERS     CYC', 0
s_done:       db 'COMPLETE', 0
s_done_pages: db 'COMPLETE  P1 L/R PAGES', 0
s_exc:        db 'UNEXPECTED EXCEPTION', 0

; ===========================================================================
; The video-init replay table, generated from a MAME capture of the real game
; ===========================================================================
%include "vidinit.inc"

; ===========================================================================
; The measurable blocks
; ===========================================================================
%include "blocks.inc"

; ===========================================================================
; Descriptor table
; ===========================================================================
align 4
test_table:
%include "table.inc"
test_table_end:

NTESTS equ (test_table_end - test_table) / TD_SIZE

; ===========================================================================
; Descriptor tables the CPU loads
; ===========================================================================
align 8
idt:
%rep 32
    dw LIN(exc_common) & 0xFFFF
    dw 0x0008
    dw 0x8E00
    dw (LIN(exc_common) >> 16) & 0xFFFF
%endrep
    dw LIN(isr_vblank) & 0xFFFF         ; vector 0x20
    dw 0x0008
    dw 0x8E00
    dw (LIN(isr_vblank) >> 16) & 0xFFFF
idt_end:

align 4
idtr:
    dw idt_end - idt - 1
    dd idt

; ===========================================================================
; Real-mode bring-up, in the last 64 KB where the reset-time CS can reach it
; ===========================================================================
    times (0x1FF000 - ($ - $$)) db 0xFF

bits 16
rm_start:
    cli
    cld
    o32 lgdt [cs:RM(gdtr)]
    mov eax, cr0
    or  al, 1
    mov cr0, eax
    jmp dword 0x08:flat_entry

align 8
gdt:
    dd 0x00000000, 0x00000000           ; null
    dd 0x0000FFFF, 0x00CF9A00           ; 0x08 flat 32-bit code, base 0
    dd 0x0000FFFF, 0x00CF9200           ; 0x10 flat 32-bit data, base 0
gdt_end:

gdtr:
    dw gdt_end - gdt - 1
    dd gdt

; ===========================================================================
; Reset vector. CS base is 0xFFFF0000 and EIP is 0xFFF0, so this is the first
; instruction the 386 executes. A NEAR jump keeps that CS base; a far one would
; drop us into low memory. The displacement is org-independent, so NASM's
; 32-bit view of both labels produces exactly the right rel16.
; ===========================================================================
    times (0x1FFFF0 - ($ - $$)) db 0xFF
reset_vector:
    jmp rm_start

    times (0x1FFFFC - ($ - $$)) db 0xFF
region_byte:
    db 0x80, 0xFF, 0xFF, 0xFF           ; 0x80 = Germany, as rfjet ships

    times (ROM_SIZE - ($ - $$)) db 0xFF
