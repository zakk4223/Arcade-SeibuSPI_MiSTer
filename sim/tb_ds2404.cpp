//============================================================================
//  SeibuSPI - testbench for spi_ds2404
//
//  The DS2404 the games keep their bookkeeping in, against a transliteration of
//  MAME's ds2404.cpp sitting beside it. Every command the RTL accepts is driven
//  into both, and every byte the 386 would read back is compared.
//
//  The reference is a transliteration and not a re-derivation ON PURPOSE. The
//  interface this models is not the chip's -- the real DS2404 speaks 1-Wire and
//  the SEI600 does not -- so MAME's device IS the specification, down to the
//  state stack and to the copy happening on the third address byte rather than
//  on a later write. Anything cleverer here would be checking the RTL against a
//  second guess.
//
//  What it would catch, and what an eyeball would not: the read pointer being
//  set to the address rather than to the address minus one (every byte off by
//  one), the scratchpad's 33rd byte wrapping over the first instead of being
//  dropped, the copy clobbering the RTC bytes, and the two-cycle latency on
//  0x6DC being read before it has settled.
//============================================================================

#include "Vspi_ds2404.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <vector>

static Vspi_ds2404 *dut;
static int errors = 0;

// ======================================================================
//  MAME's ds2404_device, transliterated. Same names, same order, same
//  omissions -- STATE_READ_SCRATCHPAD is unreachable there too, because cmd()
//  decodes 0x0F, 0x55 and 0xF0 and calls anything else a fatal error.
// ======================================================================
namespace ref {

enum STATE {
    STATE_IDLE = 1, STATE_COMMAND, STATE_ADDRESS1, STATE_ADDRESS2, STATE_OFFSET,
    STATE_INIT_COMMAND, STATE_READ_MEMORY, STATE_WRITE_SCRATCHPAD,
    STATE_READ_SCRATCHPAD, STATE_COPY_SCRATCHPAD
};

static uint16_t address, offset, end_offset;
static uint8_t  a1, a2;
static uint8_t  sram[512];
static uint8_t  ram[32];
static uint8_t  rtc[5];
static STATE    state[8];
static int      state_ptr;
static bool     bad_cmd;          // MAME would fatalerror; the RTL ignores it

static void init() {
    memset(sram, 0, sizeof(sram));          // nvram_default()
    memset(ram, 0, sizeof(ram));
    memset(rtc, 0, sizeof(rtc));
    for (auto &e : state) e = STATE_IDLE;
    state_ptr = 0;
    address = offset = end_offset = 0;
    a1 = a2 = 0;
    bad_cmd = false;
}

static uint8_t readmem() {
    if (address < 0x200) return sram[address];
    if (address >= 0x202 && address <= 0x206) return rtc[address - 0x202];
    return 0;
}

static void writemem(uint8_t value) {
    if (address < 0x200) sram[address] = value;
    else if (address >= 0x202 && address <= 0x206) rtc[address - 0x202] = value;
}

static void rom_cmd(uint8_t cmd) {
    if (cmd == 0xcc) { state[0] = STATE_COMMAND; state_ptr = 0; }
    else bad_cmd = true;
}

static void cmd(uint8_t c) {
    switch (c) {
    case 0x0f:
        state[0] = STATE_ADDRESS1; state[1] = STATE_ADDRESS2;
        state[2] = STATE_INIT_COMMAND; state[3] = STATE_WRITE_SCRATCHPAD;
        state_ptr = 0; break;
    case 0x55:
        state[0] = STATE_ADDRESS1; state[1] = STATE_ADDRESS2;
        state[2] = STATE_OFFSET; state[3] = STATE_INIT_COMMAND;
        state[4] = STATE_COPY_SCRATCHPAD; state_ptr = 0; break;
    case 0xf0:
        state[0] = STATE_ADDRESS1; state[1] = STATE_ADDRESS2;
        state[2] = STATE_INIT_COMMAND; state[3] = STATE_READ_MEMORY;
        state_ptr = 0; break;
    default: bad_cmd = true; break;
    }
}

static void _1w_reset_w() { state[0] = STATE_IDLE; state_ptr = 0; }

static uint8_t data_r() {
    switch (state[state_ptr]) {
    case STATE_READ_MEMORY: return readmem();
    case STATE_READ_SCRATCHPAD:
        if (offset < 0x20) return ram[offset++];
        return 0;
    default: return 0;
    }
}

static void data_w(uint8_t data) {
    switch (state[state_ptr]) {
    case STATE_IDLE:    rom_cmd(data); break;
    case STATE_COMMAND: cmd(data); break;
    case STATE_ADDRESS1: a1 = data; state_ptr++; break;
    case STATE_ADDRESS2: a2 = data; state_ptr++; break;
    case STATE_OFFSET:  end_offset = data; state_ptr++; break;
    case STATE_WRITE_SCRATCHPAD:
        if (offset < 0x20) ram[offset++] = data;
        break;
    default: break;
    }

    if (state[state_ptr] == STATE_INIT_COMMAND) {
        switch (state[state_ptr + 1]) {
        case STATE_READ_MEMORY:
            address = (a2 << 8) | a1; address -= 1; break;
        case STATE_WRITE_SCRATCHPAD:
        case STATE_READ_SCRATCHPAD:
            address = (a2 << 8) | a1; offset = address & 0x1f; break;
        case STATE_COPY_SCRATCHPAD:
            address = (a2 << 8) | a1;
            for (int i = 0; i <= (int)end_offset; i++) {
                // MAME indexes a 32-byte array with i; the RTL wraps instead of
                // reading past it, so the reference wraps too and the two agree
                // on a case neither hardware nor game produces.
                uint8_t v = ram[i & 31];
                writemem(v);
                address++;
            }
            break;
        default: break;
        }
        state_ptr++;
    }
}

static void clk_w() {
    if (state[state_ptr] == STATE_READ_MEMORY) address++;
}

} // namespace ref

// ======================================================================
//  The DUT's side
// ======================================================================
static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}
static void run(int n) { while (n--) tick(); }

// One access, through the request toggle, waiting for the ack the way spi_io
// stalls the 386 on it.
static void port_write(int port, uint8_t data) {
    dut->port = port;
    dut->din  = data;
    dut->req  = !dut->req;
    int guard = 0;
    while (dut->ack != dut->req) {
        tick();
        if (++guard > 200) { printf("FAIL: no ack for port %d\n", port); errors++; return; }
    }
    // The 386 cannot come back sooner than this, and 0x6DC needs two cycles to
    // follow the pointer.
    run(4);
}

static void w_reset()          { port_write(0, 0); ref::_1w_reset_w(); }
static void w_data(uint8_t d)  { port_write(1, d); ref::data_w(d); }
static void w_clk()            { port_write(2, 0); ref::clk_w(); }

static void r_data(const char *what) {
    uint8_t got  = dut->dout;
    uint8_t want = ref::data_r();
    if (got != want) {
        if (errors < 20)
            printf("FAIL: %s: read %02X, MAME's device says %02X\n", what, got, want);
        errors++;
    }
}

// ---- the sequences a game uses ----
static void read_memory(uint16_t addr, int n, const char *what) {
    w_reset();
    w_data(0xCC);
    w_data(0xF0);
    w_data(addr & 0xFF);
    w_data(addr >> 8);
    for (int i = 0; i < n; i++) { w_clk(); r_data(what); }
}

static void write_memory(uint16_t addr, const uint8_t *src, int n) {
    w_reset();
    w_data(0xCC);
    w_data(0x0F);                 // write scratchpad
    w_data(addr & 0xFF);
    w_data(addr >> 8);
    for (int i = 0; i < n; i++) w_data(src[i]);
    w_reset();
    w_data(0xCC);
    w_data(0x55);                 // copy scratchpad
    w_data(addr & 0xFF);
    w_data(addr >> 8);
    w_data(n - 1);                // end offset, inclusive
}

// The whole SRAM as the save file's tail sees it.
static std::vector<uint8_t> nv_read_all() {
    std::vector<uint8_t> out;
    for (int i = 0; i < 512; i++) {
        dut->nv_addr = i;
        tick();                    // the read port is registered
        tick();
        out.push_back(dut->nv_dout);
    }
    return out;
}

static void nv_write_all(const std::vector<uint8_t> &v) {
    for (int i = 0; i < 512; i++) {
        dut->nv_addr = i;
        dut->nv_din  = v[i];
        dut->nv_we   = 1;
        tick();
        dut->nv_we   = 0;
        tick();
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vspi_ds2404;
    ref::init();

    dut->reset = 1; dut->req = 0; dut->port = 0; dut->din = 0;
    dut->nv_addr = 0; dut->nv_din = 0; dut->nv_we = 0;
    run(8);
    dut->reset = 0;
    run(8);

    // ---- a blank chip reads as zero, not as erased -----------------------
    read_memory(0x0000, 16, "blank sram");
    printf("blank: 16 bytes of a fresh chip read back as MAME's zeroed default\n");

    // ---- one page written and read back ---------------------------------
    uint8_t page[32];
    for (int i = 0; i < 32; i++) page[i] = 0x40 + i;
    write_memory(0x0000, page, 32);
    read_memory(0x0000, 40, "page 0");            // past the end, into untouched 0
    printf("page: 32 bytes written through the scratchpad and read back, "
           "and the 8 bytes past them are still zero\n");

    // ---- the bookkeeping page rdft actually leaves behind ----------------
    // Taken from MAME's own ~/.mame/nvram/rdft/ds2404: the game ID with the
    // region byte cleared, then counters.
    static const uint8_t book[16] = {
        0x00, 0x4A, 0x4A, 0x36, 0x20, 0x01, 0x01, 0x01,
        0x01, 0x01, 0x02, 0x01, 0x0F, 0x00, 0x00, 0x00
    };
    write_memory(0x0000, book, 16);
    read_memory(0x0000, 16, "bookkeeping");
    printf("bookkeeping: rdft's own 16-byte header survives a write/read round trip\n");

    // ---- a write that is not 32-aligned, and a partial copy --------------
    uint8_t four[4] = { 0xDE, 0xAD, 0xBE, 0xEF };
    write_memory(0x0107, four, 4);
    read_memory(0x0104, 12, "unaligned");
    printf("unaligned: a 4-byte store at 0x107 lands there and nowhere else\n");

    // ---- the scratchpad's 33rd byte is dropped, not wrapped --------------
    // MAME's m_offset walks past 0x1f and the guard drops everything after it.
    // A five-bit counter in the RTL would have overwritten byte 0 instead.
    {
        uint8_t big[40];
        for (int i = 0; i < 40; i++) big[i] = 0x80 + i;
        w_reset(); w_data(0xCC); w_data(0x0F);
        w_data(0x00); w_data(0x02);            // 0x200: the hole above the SRAM
        for (int i = 0; i < 40; i++) w_data(big[i]);
        // copy the scratchpad somewhere real and see which 32 bytes it holds
        w_reset(); w_data(0xCC); w_data(0x55);
        w_data(0x80); w_data(0x00);            // 0x080
        w_data(31);
        read_memory(0x0080, 32, "overflow");
        printf("overflow: the 33rd scratchpad byte is dropped, and byte 0 still "
               "holds %02X\n", ref::sram[0x80]);
    }

    // ---- the RTC, and the hole either side of it ------------------------
    // 0x200 and 0x201 read zero and swallow writes; 0x202-0x206 are the
    // counter, low byte first.
    read_memory(0x0200, 2, "the hole at 0x200");
    printf("hole: 0x200 and 0x201 read zero, as MAME's readmem() returns for them\n");

    // The copy path reaches the RTC too, which is how a game would set it.
    //
    // Note where the scratchpad is filled from. The chip's write-scratchpad
    // command sets the offset from the ADDRESS's low five bits (MAME:
    // `m_offset = m_address & 0x1f`), and the copy always reads the scratchpad
    // from 0, so a fill and a copy only line up when the address is 32-aligned.
    // Filling at 0x200 and copying to 0x202 is what a game has to do, and
    // writing this the obvious way instead -- fill at 0x202, copy to 0x202 --
    // silently copies five bytes nobody wrote. Both models agree either way;
    // the first version of this test compared against its own expectation and
    // caught only itself.
    {
        uint8_t t[5] = { 0x11, 0x22, 0x33, 0x44, 0x55 };
        w_reset(); w_data(0xCC); w_data(0x0F);
        w_data(0x00); w_data(0x02);            // 0x200: offset 0
        for (int i = 0; i < 5; i++) w_data(t[i]);
        w_reset(); w_data(0xCC); w_data(0x55);
        w_data(0x02); w_data(0x02);            // copy to 0x202, five bytes
        w_data(4);
        w_reset(); w_data(0xCC); w_data(0xF0);
        w_data(0x03); w_data(0x02);            // read from 0x203 up
        int bad = 0;
        for (int i = 1; i < 5; i++) {
            w_clk();
            // The reference's counter does not tick, so only the four bytes
            // above the one the tick lands on can be compared -- and 239 ticks
            // have to pass before a carry can reach them, which is far longer
            // than this read.
            if (dut->dout != ref::rtc[i]) bad++;
            if (ref::rtc[i] != t[i]) bad++;    // and MAME's device took them
        }
        if (bad) { printf("FAIL: %d checks failed on the four high RTC bytes\n", bad); errors++; }
        else     printf("rtc: five bytes copied into the counter, and the four "
                        "above the tick read back exactly\n");
    }

    // ---- the RTC ticks, and only it -------------------------------------
    {
        // TICK_DIV is turned down for the testbench, so a few hundred cycles is
        // several ticks.
        w_reset(); w_data(0xCC); w_data(0xF0); w_data(0x02); w_data(0x02);
        w_clk();
        uint8_t first = dut->dout;
        run(4000);
        w_reset(); w_data(0xCC); w_data(0xF0); w_data(0x02); w_data(0x02);
        w_clk();
        uint8_t later = dut->dout;
        if (first == later) { printf("FAIL: the RTC is not counting (%02X twice)\n", first); errors++; }
        else printf("rtc: the counter is running -- low byte %02X then %02X\n", first, later);
        // and the SRAM is untouched by it
        uint8_t keep = ref::sram[0x00];
        read_memory(0x0000, 4, "sram after ticks");
        printf("rtc: %d ticks later the SRAM still starts %02X\n", 4000, keep);
    }

    // ---- the save file's tail is the SRAM, in order ----------------------
    {
        std::vector<uint8_t> got = nv_read_all();
        int bad = 0;
        for (int i = 0; i < 512; i++) if (got[i] != ref::sram[i]) bad++;
        if (bad) { printf("FAIL: %d of 512 tail bytes differ from the device's SRAM\n", bad); errors++; }
        else printf("tail: all 512 bytes of the save file match the SRAM the game sees\n");
    }

    // ---- a load lands where the game reads, and does not ask to be saved --
    {
        std::vector<uint8_t> file(512);
        for (int i = 0; i < 512; i++) file[i] = (uint8_t)(0xC3 ^ i);
        bool dirty_before = dut->nv_dirty;
        nv_write_all(file);
        if (dut->nv_dirty != dirty_before) {
            printf("FAIL: loading the save file asked for it to be saved back\n");
            errors++;
        }
        memcpy(ref::sram, file.data(), 512);
        read_memory(0x0000, 32, "after load");
        read_memory(0x01E0, 32, "after load, high end");
        printf("load: 512 bytes written through the nvram port read back through "
               "the game's own path, and no save was requested\n");
    }

    // ---- a store by the GAME does ask ------------------------------------
    {
        bool before = dut->nv_dirty;
        uint8_t one[1] = { 0x5A };
        write_memory(0x0040, one, 1);
        if (dut->nv_dirty == before) {
            printf("FAIL: a store into the SRAM did not toggle nv_dirty\n");
            errors++;
        } else printf("dirty: a store by the game toggles nv_dirty, which is what "
                      "asks Main for a save\n");
        // a store into the RTC hole must not
        before = dut->nv_dirty;
        w_reset(); w_data(0xCC); w_data(0x0F); w_data(0x00); w_data(0x02);
        w_data(0x99);
        w_reset(); w_data(0xCC); w_data(0x55); w_data(0x00); w_data(0x02);
        w_data(0);
        if (dut->nv_dirty != before) {
            printf("FAIL: a store into the hole at 0x200 asked for a save\n");
            errors++;
        } else printf("dirty: a store into the hole above the SRAM does not\n");
        // keep the reference's view of that write
        ref::state[0] = ref::STATE_IDLE; ref::state_ptr = 0;
    }

    // ---- reset clears the machine and keeps the memory -------------------
    {
        std::vector<uint8_t> before = nv_read_all();
        dut->reset = 1; run(8); dut->reset = 0; run(8);
        std::vector<uint8_t> after = nv_read_all();
        int bad = 0;
        for (int i = 0; i < 512; i++) if (before[i] != after[i]) bad++;
        if (bad) { printf("FAIL: reset lost %d bytes of the SRAM\n", bad); errors++; }
        else printf("reset: the state machine restarts and all 512 SRAM bytes "
                    "survive -- it is battery-backed, and the save file loads "
                    "while the core is still held down\n");
        // and the machine really is back at IDLE: a data byte that is not 0xCC
        // must do nothing at all
        ref::_1w_reset_w();
        w_data(0x12);
        read_memory(0x0000, 4, "after reset");
    }

    // ---- an unknown command is ignored rather than fatal -----------------
    {
        w_reset(); w_data(0xCC);
        w_data(0x3C);                          // MAME: fatalerror
        // the RTL stays in COMMAND, so a real command still works next
        w_data(0xF0); w_data(0x00); w_data(0x00);
        w_clk();
        if (dut->dout != ref::sram[0]) {
            printf("FAIL: an unknown command left the machine unusable "
                   "(read %02X, want %02X)\n", dut->dout, ref::sram[0]);
            errors++;
        } else printf("unknown: a command MAME calls fatal is ignored, and the "
                      "next real one still works\n");
    }

    if (errors) { printf("\n%d ds2404 checks FAILED\n", errors); return 1; }
    printf("\nall ds2404 checks passed\n");
    return 0;
}
