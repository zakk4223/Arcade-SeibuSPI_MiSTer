; ---------------------------------------------------------------------------
; The benchmark suite: one measurable block per (test, length) pair, plus the
; descriptor table the harness walks.
;
; Measurement method is two-length differencing, as used by uops.info
; (arXiv:1810.04610 §3.1) rather than Abrash's empty-loop reference subtraction:
; every test is built twice, at a LO and a HI length, and only the difference is
; reported. Loop overhead, the per-iteration prologue, the vblank ISR and the
; harness all appear identically in both and cancel exactly, so none of their
; costs ever has to be known.
;
;     cycles_per_unit = CPF * W * (1/iters_hi - 1/iters_lo) / delta
;
; where CPF is the platform's CPU clocks per video frame, W the window in
; frames, and `delta` the number of extra UNITS the HI block executes per
; iteration. A unit is usually one instruction; where a body is several
; instructions the descriptor says so and delta counts them all.
;
; ---- rules every block must obey -----------------------------------------
;
;  * EBP is the iteration counter and is reserved. The vblank ISR snapshots it
;    to bound the window, so a body must never touch it.
;  * Blocks are memcpy'd into RAM before they run, so they must be POSITION
;    INDEPENDENT: no absolute code references, no jumps or calls out of the
;    block. Immediates and absolute DATA addresses are fine. Intra-block
;    references use NASM local labels (`.foo`), which are scoped to the block's
;    own label.
;  * A body must leave the stack balanced.
; ---------------------------------------------------------------------------

; --- block emitter --------------------------------------------------------
; %1 repeat count   %2 body macro    %3 init macro (runs once, before the loop)
; %4 body argument  %5 init argument %6 per-iteration prologue macro
%macro BLKBODY 6
    %3 %5
.loop:
    %6
    %rep %1
        %2 %4
    %endrep
    dec ebp
    jnz .loop
    ret
%endmacro

; --- init / prologue helpers ----------------------------------------------
%macro I_NONE 1
%endmacro

%macro P_NONE 0
%endmacro

; Re-establish ZF=1 at the top of every iteration. `dec ebp` at the bottom of
; the loop destroys it, which would silently turn the taken-branch test into a
; not-taken one.
%macro P_ZF 0
    xor eax, eax
%endmacro

%macro I_MEM 1
    mov esi, DATA_BUF
    mov edi, DATA_BUF_B
    xor eax, eax
    xor edx, edx
%endmacro

%macro I_SHIFT 1
    mov ecx, 3
    mov eax, 0x12345678
%endmacro

%macro I_IMM 1
    mov ebx, %1
    mov ecx, %1
%endmacro

; Head of the pointer-chase ring. The small ring lives in the first 4 KB and is
; threaded through dword 1 of each 64-byte node; the large ring spans all 32 KB
; through dword 0. 64 bytes is four of the core's 16-byte cache lines apart, so
; the large ring cannot be prefetched into a 16 KB cache.
%macro I_CHASE 1
    mov esi, DATA_BUF
%endmacro

%macro I_GAME 1
    mov esi, DATA_BUF
    mov edi, DATA_BUF + 0x4000
    xor ecx, ecx
    mov ebx, 0x1234
    mov edx, 0x5678
%endmacro

; A `ret` the CALL test can reach with a block-relative displacement.
%macro I_RETSTUB 1
    jmp .past_stub
.retstub:
    ret
.past_stub:
%endmacro

; --- bodies ---------------------------------------------------------------
; Every body macro takes exactly one argument, ignored unless noted.

%macro B_NULL 1
%endmacro

; Latency: a chain of adds, each consuming the previous result.
%macro B_ADD_DEP 1
    add eax, ebx
%endmacro

; Throughput: four independent accumulators. Identical to the above on a real
; in-order 386; a divergence here is a z386 frontend effect.
%macro B_ADD_IND 1
    add eax, 1
    add ebx, 1
    add ecx, 1
    add edx, 1
%endmacro

%macro B_MOV_RR 1
    mov eax, ebx
%endmacro

%macro B_MOV_RI 1
    mov eax, 0x12345678
%endmacro

%macro B_LEA 1
    lea eax, [ebx + ecx*4 + 16]
%endmacro

%macro B_NOP 1
    nop
%endmacro

%macro B_SHL_I 1
    shl eax, 3
%endmacro

%macro B_SHL_CL 1
    shl eax, cl
%endmacro

; --- memory ---------------------------------------------------------------
%macro B_LOAD 1
    mov eax, [esi]
%endmacro

%macro B_STORE 1
    mov [edi], eax
%endmacro

%macro B_ADD_RM 1
    add eax, [esi]
%endmacro

%macro B_ADD_MR 1
    add [edi], eax
%endmacro

; Deliberately dword-misaligned: on a 386 a split access costs a second bus
; cycle. An FPGA memory interface commonly splits all accesses or none.
%macro B_LOAD_MIS 1
    mov eax, [esi+1]
%endmacro

%macro B_STORE_MIS 1
    mov [edi+1], eax
%endmacro

; Pointer chase. Each load's address depends on the previous load's data, so
; nothing can be overlapped and the number is pure load-to-use latency.
%macro B_CHASE_SMALL 1
    mov esi, [esi+4]
%endmacro

%macro B_CHASE_BIG 1
    mov esi, [esi]
%endmacro

; --- stack ----------------------------------------------------------------
; Three balanced pairs that between them isolate PUSH from POP:
;   PUSH+POP     = 2 + 4 = 6   -> 3.00 per unit
;   PUSH+ADDESP  = 2 + 2 = 4   -> 2.00 per unit
;   SUBESP+POP   = 2 + 4 = 6   -> 3.00 per unit
%macro B_PUSHPOP 1
    push eax
    pop eax
%endmacro

%macro B_PUSHADD 1
    push eax
    add esp, 4
%endmacro

%macro B_SUBPOP 1
    sub esp, 4
    pop eax
%endmacro

; --- control flow ---------------------------------------------------------
; ZF is 1 on entry (P_ZF), so `jz` is taken and skips eight bytes that never
; execute; those bytes also keep the 16-byte prefetch queue under realistic
; pressure. `jnz` falls straight through.
%macro B_JCC_TAKEN 1
    jz %%a
    times 8 db 0x90
%%a:
%endmacro

%macro B_JCC_NOT 1
    jnz %%a
%%a:
%endmacro

; A two-trip loop, expressed both ways. LOOP is documented at 11+m against
; 2 + 7+m for dec/jnz, so on a real 386 LOOP is the SLOWER of the two. The unit
; here is one whole two-trip loop, not one instruction.
%macro B_LOOP 1
    mov ecx, 2
%%l:
    loop %%l
%endmacro

%macro B_DECJNZ 1
    mov ecx, 2
%%l:
    dec ecx
    jnz %%l
%endmacro

; call + ret. `.retstub` comes from I_RETSTUB and is block-local, so the
; displacement survives the copy into RAM.
%macro B_CALLRET 1
    call .retstub
%endmacro

; --- multiply and divide --------------------------------------------------
; The 386 uses an early-out multiply: clocks = max(ceil(log2 m), 3) + 6, or 9
; when m = 0. Sweeping m turns this into a closed-form pass/fail rather than a
; "close enough". MAME charges a flat 41 (cycles.h:98) and so must come out
; level across the sweep; a real 386 must come out as a staircase.
; The unit is one MOV+MUL pair, so subtract the MOV's own cost before comparing.
%macro B_MUL 1
    mov eax, %1
    mul ebx
%endmacro

; Divide has no early-out (non-restoring, one quotient bit per cycle) and must
; be flat at 38 regardless of operand. The unit is XOR+MOV+DIV.
%macro B_DIV 1
    xor edx, edx
    mov eax, %1
    div ebx
%endmacro

; --- string moves ---------------------------------------------------------
; Here the two lengths differ in the ELEMENT COUNT, not the copy count: LO
; moves 16 dwords and HI 116, so delta is 100 elements and the three setup MOVs
; cancel along with everything else.
%macro B_REPMOVSD 1
    mov esi, DATA_BUF
    mov edi, DATA_BUF_B
    mov ecx, %1
    rep movsd
%endmacro

%macro B_REPSTOSD 1
    mov edi, DATA_BUF_B
    mov ecx, %1
    rep stosd
%endmacro

; --- instruction fetch ----------------------------------------------------
; Five bytes each (81 C0 imm32). LO is 10 KB and fits inside the core's 16 KB
; I-cache; HI is 40 KB and cannot. On a real 386, which has no cache at all,
; both are the same code fetched the same way and the two must agree.
%macro B_FETCH 1
    add eax, 0x01010101
%endmacro

; --- a game-shaped composite ----------------------------------------------
; Eight instructions in the shape of a sprite-list build: an indexed load, some
; arithmetic, two indexed stores, and a masked index bump that keeps both
; cursors inside their buffers. This is the number that predicts whether the
; core does more work per frame than the board did.
%macro B_GAME 1
    mov  eax, [esi + ecx*4]
    imul eax, 3
    shr  eax, 8
    add  eax, ebx
    mov  [edi + ecx*8], eax
    mov  [edi + ecx*8 + 4], edx
    inc  ecx
    and  ecx, 0x3FF
%endmacro

; --- descriptor table entry -----------------------------------------------
; %1 name  %2 lo  %3 lo_end  %4 hi  %5 hi_end  %6 delta  %7 flags
%macro TESTREC 7
%%n:
    db %1
    times NAMELEN - ($ - %%n) db ' '
    dd %2
    dd %3 - %2
    dd %4
    dd %5 - %4
    dd %6
    dd %7
%endmacro
