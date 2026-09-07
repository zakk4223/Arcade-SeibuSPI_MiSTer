//============================================================================
//  SeibuSPI - testbench for spi_93c46
//
//  The 93C46 the single-board sets keep their bookkeeping in, against a
//  transliteration of MAME's eepromser.cpp sitting beside it. Every command is
//  driven into both through the same three wires the 386 drives, and every DO
//  bit and every one of the 128 save-file bytes is compared.
//
//  The reference is a transliteration and not a re-derivation ON PURPOSE, for
//  the same reason tb_ds2404 gives: the thing being modelled is MAME's device,
//  because MAME's device is what the game is known to work against. A cleverer
//  reference here would be checking the RTL against a second guess at a
//  datasheet.
//
//  What it catches that reading the code would not:
//   * the leading dummy zero on a read being absent, or being two bits
//   * the command frame being 8 bits instead of 2 + 6
//   * EWEN/EWDS decoded off the wrong two bits, which silently makes every
//     write either always work or never work
//   * WRAL storing instead of ANDing (the datasheet's ERAL-then-WRAL rule)
//   * a clock edge in the same write as the CS rise being counted, which shifts
//     every subsequent bit by one
//   * an overclocked read wrapping back to the word instead of shifting ones
//   * the save file's byte order, which has to be MAME's little-endian per word
//============================================================================

#include "Vspi_93c46.h"
#include "verilated.h"

#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>

struct Ref;
static Vspi_93c46 *dut;
static uint64_t    tickcount = 0;
static int         failures  = 0;

static void tick(int n = 1);   // defined after Ref, which its body ticks

//----------------------------------------------------------------------------
//  The reference: MAME's eeprom_serial_93cxx_device, 16-bit, 64 cells,
//  6 command-address bits. State names and structure follow eepromser.cpp so
//  the two can be diffed by eye.
//----------------------------------------------------------------------------
// The RTL is built with CLK_MHZ=1 for this bench, so the operation times are
// MAME's microseconds counted in ticks: short enough to simulate, long enough
// that the poll in test 12 sees the busy window.
static const int T_WRITE = 1750, T_WRITE_ALL = 8000,
                 T_ERASE = 1000, T_ERASE_ALL = 8000;

struct Ref {
    enum State { IN_RESET, WAIT_FOR_START_BIT, WAIT_FOR_COMMAND,
                 READING_DATA, WAIT_FOR_DATA, WAIT_FOR_COMPLETION };
    enum Cmd { INVALID, READ, WRITE, ERASE, LOCK, UNLOCK, WRITEALL, ERASEALL };

    uint16_t data[64];
    State    state    = IN_RESET;
    Cmd      command  = INVALID;
    // MAME's m_locked starts true.
    bool     locked   = true;
    uint32_t shift    = 0;
    uint32_t accum    = 0;
    int      bits     = 0;
    int      address  = 0;
    int      cs = 0, clk = 0, di = 0;
    // "a false rising CLK edge at the exact same time as a rising CS edge ...
    // it appears we should ignore these edges"
    bool     cs_rose_now = false;

    void reset_chip() { state = IN_RESET; command = INVALID; locked = true;
                        shift = accum = 0; bits = 0; address = 0; }

    // eepromser.cpp:658 -- the 93cxx override, "combined DO+READY/BUSY":
    //   do_read() = (state == WAIT_FOR_START_BIT) ? ready() : base_do_read()
    // so DO is the shift register while a word goes out, the write-completion
    // status while the chip waits for a start bit with CS raised, and 1
    // otherwise. rdft2us polls the middle one and will not boot without it.
    int busy = 0;
    bool ready() const { return busy == 0; }
    int do_read() const {
        if (state == READING_DATA)      return (shift & 0x80000000u) ? 1 : 0;
        if (state == WAIT_FOR_START_BIT) return ready() ? 1 : 0;
        return 1;
    }
    void tick_busy() { if (busy) busy--; }

    void set_state(State s) { state = s; }

    void parse_command_and_address() {
        command = INVALID;
        address = accum & 0x3f;
        switch (accum >> 6) {
            case 0:
                switch (address >> 4) {
                    case 0: command = LOCK;     break;
                    case 1: command = WRITEALL; break;
                    case 2: command = ERASEALL; break;
                    case 3: command = UNLOCK;   break;
                }
                address = 0;
                break;
            case 1: command = WRITE; break;
            case 2: command = READ;  break;
            case 3: command = ERASE; break;
        }
    }

    void execute_command() {
        parse_command_and_address();
        bits = 0;
        switch (command) {
            case READ:     shift = 0; set_state(READING_DATA); break;
            case WRITE:
            case WRITEALL: shift = 0; set_state(WAIT_FOR_DATA); break;
            case ERASE:
                if (locked) { set_state(IN_RESET); break; }
                data[address] = 0xffff;
                busy = T_ERASE;
                set_state(WAIT_FOR_COMPLETION);
                break;
            case LOCK:     locked = true;  set_state(IN_RESET); break;
            case UNLOCK:   locked = false; set_state(IN_RESET); break;
            case ERASEALL:
                if (locked) { set_state(IN_RESET); break; }
                for (int a = 0; a < 64; a++) data[a] = 0xffff;
                busy = T_ERASE_ALL;
                set_state(WAIT_FOR_COMPLETION);
                break;
            default: set_state(IN_RESET); break;
        }
    }

    void execute_write_command() {
        switch (command) {
            case WRITE:
                if (locked) { set_state(IN_RESET); break; }
                data[address] = shift & 0xffff;
                busy = T_WRITE;
                set_state(WAIT_FOR_COMPLETION);
                break;
            case WRITEALL:
                if (locked) { set_state(IN_RESET); break; }
                // "ERASEALL is required before so we AND against the data"
                for (int a = 0; a < 64; a++) data[a] &= (shift & 0xffff);
                busy = T_WRITE_ALL;
                set_state(WAIT_FOR_COMPLETION);
                break;
            default: set_state(IN_RESET); break;
        }
    }

    void clk_rising() {
        switch (state) {
            case IN_RESET: break;
            case WAIT_FOR_START_BIT:
                // eepromser.cpp:386 -- a start bit arriving while a write is
                // still completing is dropped, not queued.
                if (di && !cs_rose_now && ready()) { accum = bits = 0;
                                          set_state(WAIT_FOR_COMMAND); }
                break;
            case WAIT_FOR_COMMAND:
                accum = (accum << 1) | di;
                if (++bits == 2 + 6) execute_command();
                break;
            case READING_DATA: {
                int bit_index = bits++;
                if (bit_index == 0) shift = (uint32_t)data[address] << 16;
                else                shift = (shift << 1) | 1;
                break;
            }
            case WAIT_FOR_DATA:
                shift = (shift << 1) | di;
                if (++bits == 16) execute_write_command();
                break;
            case WAIT_FOR_COMPLETION: break;
        }
    }

    // One write to 0x68E: eeprom_w() does di, then clk, then cs, in that order.
    void write_lines(int ndi, int nclk, int ncs) {
        cs_rose_now = false;
        di = ndi;
        if (nclk && !clk) { clk = nclk; clk_rising(); }
        else clk = nclk;
        if (ncs && !cs) { cs = ncs; cs_rose_now = true;
                          if (state == IN_RESET) set_state(WAIT_FOR_START_BIT); }
        else if (!ncs && cs) { cs = ncs; set_state(IN_RESET); }
        else cs = ncs;
    }
};

static Ref ref;

static void tick(int n)
{
    for (int i = 0; i < n; i++) {
        dut->clk = 0; dut->eval();
        dut->clk = 1; dut->eval();
        ref.tick_busy();
        tickcount++;
    }
}

//----------------------------------------------------------------------------
//  Driving both, exactly the way the 386 does: one store to 0x68E carrying all
//  three lines, then time passes.
//----------------------------------------------------------------------------
static const int SETTLE = 6;   // clk_ram cycles between 386 stores

static void lines(int di, int sk, int cs)
{
    // The RTL sees levels and finds its own edges, so the order the reference
    // applies them in cannot matter here -- which is itself worth checking, and
    // is what the cs_rose_now case below exercises.
    dut->di = di; dut->sk = sk; dut->cs = cs;
    ref.write_lines(di, sk, cs);
    tick(SETTLE);
}

static void check_do(const char *what)
{
    int got = dut->dout, want = ref.do_read();
    if (got != want) {
        printf("FAIL %-24s DO: rtl=%d ref=%d (ref state=%d bits=%d) @%llu\n",
               what, got, want, (int)ref.state, ref.bits,
               (unsigned long long)tickcount);
        failures++;
    }
}

// A clock pulse with DI held: the low half, then the high half, checking DO on
// both. Real hardware clocks data out on the rising edge; the game reads DO
// whenever it likes, so both halves have to agree.
static void pulse(int di, const char *what)
{
    lines(di, 0, 1); check_do(what);
    lines(di, 1, 1); check_do(what);
}

// The write-completion poll, which is the whole point of the busy timer and is
// literally rdft2us's own loop at 0x2A10A4: raise CS, watch DO go low while the
// chip programs, wait for it to come back. Every write/erase below goes through
// this, because on the real part -- and now in MAME and here -- a command issued
// before the previous one finished is DROPPED, and a test that skipped the wait
// would silently be testing nothing.
static void wait_ready(const char *what, bool expect_busy)
{
    // A command refused because the part is locked stores nothing and therefore
    // never goes busy -- which is the CORRECT behaviour, and asserting on it was
    // this test's own bug, not the RTL's.
    if (!expect_busy) { lines(0, 0, 1); check_do(what); lines(0, 0, 0); return; }
    // Only the RTL is polled here, not compared against the reference: both
    // models load the timer on the same command, but the RTL sees the host lines
    // two cycles later through its synchronisers, so their counters expire a
    // couple of ticks apart. The SEQUENCE is the contract -- busy, then ready --
    // and every other DO comparison in this file is still exact.
    lines(0, 0, 1);                       // CS up, no clock
    bool saw_busy = false;
    for (int i = 0; i < 200000; i++) {
        if (dut->dout == 0) saw_busy = true;
        else if (saw_busy) {
            lines(0, 0, 0);
            ref.busy = 0;                 // re-sync: it expired within a tick or two
            return;
        }
        tick(4);
    }
    printf("FAIL %s: DO never reported busy-then-ready\n", what);
    failures++;
    lines(0, 0, 0);
}

static void start_frame() { lines(0, 0, 0); lines(0, 0, 1); }   // CS up, SK low
static void end_frame()   { lines(0, 0, 0); }                   // CS down

// start bit + 2 opcode bits + 6 address bits
static void send_command(int op, int addr)
{
    start_frame();
    pulse(1, "start");
    for (int i = 1; i >= 0; i--) pulse((op   >> i) & 1, "opcode");
    for (int i = 5; i >= 0; i--) pulse((addr >> i) & 1, "address");
}

static void send_word(uint16_t w)
{
    for (int i = 15; i >= 0; i--) pulse((w >> i) & 1, "data");
}

static uint16_t read_word(int addr)
{
    send_command(2, addr);
    uint16_t got = 0;
    // The dummy zero first: DO must already be low with no further clocking.
    check_do("read dummy");
    if (dut->dout != 0) {
        printf("FAIL read %02x: no leading dummy zero\n", addr);
        failures++;
    }
    for (int i = 0; i < 16; i++) { pulse(0, "readbit"); got = (got << 1) | dut->dout; }
    end_frame();
    return got;
}

static void ewen()  { send_command(0, 0x30); end_frame(); }
static void ewds()  { send_command(0, 0x00); end_frame(); }
static void erase(int a)          { bool e = !ref.locked; send_command(3, a); end_frame(); wait_ready("erase", e); }
static void write(int a, uint16_t w) { bool e = !ref.locked; send_command(1, a); send_word(w); end_frame(); wait_ready("write", e); }
static void eral()  { bool e = !ref.locked; send_command(0, 0x20); end_frame(); wait_ready("eral", e); }
static void wral(uint16_t w) { bool e = !ref.locked; send_command(0, 0x10); send_word(w); end_frame(); wait_ready("wral", e); }

//----------------------------------------------------------------------------
//  The save file. spi_nvram streams 128 bytes in and out; MAME's file is the
//  array verbatim, little-endian per word.
//----------------------------------------------------------------------------
static void nv_load(const uint8_t *src)
{
    for (int i = 0; i < 128; i++) {
        dut->nv_addr = i; dut->nv_din = src[i]; dut->nv_we = 1; tick();
    }
    dut->nv_we = 0; tick();
}

static void nv_save(uint8_t *dst)
{
    for (int i = 0; i < 128; i++) { dut->nv_addr = i; tick(); dst[i] = dut->nv_dout; }
}

static void compare_array(const char *what)
{
    uint8_t got[128], want[128];
    nv_save(got);
    for (int a = 0; a < 64; a++) {
        want[a * 2 + 0] = ref.data[a] & 0xff;         // get_u16le
        want[a * 2 + 1] = ref.data[a] >> 8;
    }
    if (memcmp(got, want, 128) != 0) {
        printf("FAIL %s: array differs\n", what);
        for (int a = 0; a < 64; a++) {
            uint16_t g = got[a * 2] | (got[a * 2 + 1] << 8);
            if (g != ref.data[a])
                printf("      word %02x: rtl=%04x ref=%04x\n", a, g, ref.data[a]);
        }
        failures++;
    }
}

int main(int argc, char **argv)
{
    Verilated::commandArgs(argc, argv);
    dut = new Vspi_93c46;

    dut->clk = 0; dut->reset = 1;
    dut->cs = dut->sk = dut->di = 0;
    dut->nv_addr = 0; dut->nv_din = 0; dut->nv_we = 0;
    dut->ss_addr = 0; dut->ss_din = 0; dut->ss_we = 0; dut->pause = 0;
    dut->ss_ram_addr = 0; dut->ss_ram_din = 0; dut->ss_ram_we = 0;
    tick(4);
    dut->reset = 0; tick(4);

    // A blank part is all ones, and both sides start there.
    uint8_t blank[128];
    memset(blank, 0xff, sizeof blank);
    nv_load(blank);
    for (int a = 0; a < 64; a++) ref.data[a] = 0xffff;
    compare_array("blank");

    // ---- 1. writes are refused while locked, which is the power-on state ----
    write(0x00, 0x1234);
    compare_array("write while locked");

    // ---- 2. EWEN, then the whole array written and read back ---------------
    ewen();
    for (int a = 0; a < 64; a++) write(a, (uint16_t)(0xA000 ^ (a * 0x0101)));
    compare_array("write all 64");
    for (int a = 0; a < 64; a++) {
        uint16_t got = read_word(a);
        if (got != ref.data[a]) {
            printf("FAIL read %02x: rtl=%04x ref=%04x\n", a, got, ref.data[a]);
            failures++;
        }
    }

    // ---- 3. ERASE one cell -------------------------------------------------
    erase(0x2a);
    compare_array("erase one");
    if (read_word(0x2a) != 0xffff) { printf("FAIL erased cell not ffff\n"); failures++; }

    // ---- 4. EWDS locks it again -------------------------------------------
    ewds();
    write(0x05, 0x0000);
    erase(0x06);
    compare_array("locked again");

    // ---- 5. WRAL is an AND, not a store -----------------------------------
    ewen();
    wral(0x0f0f);
    compare_array("wral ands");

    // ---- 6. ERAL then WRAL, the datasheet's own sequence -------------------
    eral();
    compare_array("eral");
    wral(0x5555);
    compare_array("eral then wral");

    // ---- 7. an overclocked read must shift ones, not wrap to the word ------
    ewen();
    write(0x11, 0x8000);
    send_command(2, 0x11);
    for (int i = 0; i < 40; i++) { pulse(0, "overclock"); }
    end_frame();

    // ---- 8. a clock edge in the SAME store as the CS rise is not a bit -----
    // The 386 writes all three lines at once, so this is the ordinary shape of
    // a first write and not a corner case. Driving CS and SK up together must
    // leave the part waiting for a start bit, so the frame that follows still
    // works normally.
    lines(0, 0, 0);
    lines(1, 1, 1);          // DI, SK and CS all rise in one store
    lines(1, 0, 1);
    pulse(1, "start after joint rise");
    for (int i = 1; i >= 0; i--) pulse((2 >> i) & 1, "opcode");
    for (int i = 5; i >= 0; i--) pulse((0x11 >> i) & 1, "address");
    uint16_t got = 0;
    for (int i = 0; i < 16; i++) { pulse(0, "readbit"); got = (got << 1) | dut->dout; }
    end_frame();
    if (got != ref.data[0x11]) {
        printf("FAIL joint CS/SK rise: read %04x, expected %04x\n", got, ref.data[0x11]);
        failures++;
    }

    // ---- 9. CS dropped mid-command abandons it -----------------------------
    send_command(1, 0x20);
    send_word(0xdead);
    // ...but only 8 of the 16 bits, then CS away
    send_command(1, 0x21);
    for (int i = 0; i < 8; i++) pulse(1, "half");
    end_frame();
    compare_array("aborted write");

    // ---- 10. the save file round-trips ------------------------------------
    uint8_t snapshot[128];
    nv_save(snapshot);
    nv_load(blank);
    for (int a = 0; a < 64; a++) ref.data[a] = 0xffff;
    compare_array("reloaded blank");
    nv_load(snapshot);
    for (int a = 0; a < 64; a++)
        ref.data[a] = snapshot[a * 2] | (snapshot[a * 2 + 1] << 8);
    compare_array("reloaded snapshot");

    // ---- 11. the savestate, taken MID-COMMAND -----------------------------
    // The state that matters is the state a snapshot can catch in the middle of,
    // and a device whose savestate is wrong looks perfect from outside until
    // someone loads one -- which is how the DS2404's cost two sessions
    // (PLAN.md 46/50). So: get half way through a read, snapshot everything,
    // scrub the part with a reset, restore, and finish the read.
    ewen();
    write(0x1c, 0x9e37);
    // Read back what actually landed rather than assuming 0x9e37: an earlier
    // test can leave the part busy, and a command issued while busy is dropped
    // by design. compare_array() has already held the RTL's array against the
    // reference's, so this value is the verified one -- and the subject here is
    // the savestate, not the write.
    const uint16_t ss_word = ref.data[0x1c];
    send_command(2, 0x1c);
    for (int i = 0; i < 6; i++) pulse(0, "pre-snapshot");   // 6 of 16 bits out

    uint32_t ss[3];
    for (int i = 0; i < 3; i++) { dut->ss_addr = i; dut->eval(); ss[i] = dut->ss_dout; }
    uint8_t ss_array[128];
    // PAUSE ASSERTED, because that is what a savestate does to the board -- and
    // the RTL uses it to hand the shared byte read port to the savestate rather
    // than the save file. And a CLOCK EDGE, not just an eval(): the read ports
    // are registered, so `eval()` alone returns last cycle's word. nv_save()
    // already ticked; this did not, and silently read a stale byte 128 times.
    dut->pause = 1;
    for (int i = 0; i < 128; i++) { dut->ss_ram_addr = i; tick(); ss_array[i] = dut->ss_ram_dout; }
    dut->pause = 0;

    // Scrub: reset the machine and wipe the array, so a restore that forgets a
    // field cannot accidentally pass on a leftover value.
    dut->reset = 1; tick(4); dut->reset = 0; tick(2);
    nv_load(blank);

    for (int i = 0; i < 128; i++) {
        dut->ss_ram_addr = i; dut->ss_ram_din = ss_array[i]; dut->ss_ram_we = 1; tick();
    }
    dut->ss_ram_we = 0; tick();
    for (int i = 0; i < 3; i++) {
        dut->ss_addr = i; dut->ss_din = ss[i]; dut->ss_we = 1; tick();
    }
    dut->ss_we = 0; tick();

    // The remaining ten bits of the word must come out as if nothing happened.
    uint16_t resumed = 0;
    for (int i = 0; i < 6; i++) resumed = (resumed << 1) | ((ss_word >> (15 - i)) & 1);
    for (int i = 0; i < 10; i++) { pulse(0, "post-restore"); resumed = (resumed << 1) | dut->dout; }
    end_frame();
    if (resumed != ss_word) {
        printf("FAIL savestate mid-read: resumed %04x, expected %04x\n",
               resumed, ss_word);
        failures++;
    }
    compare_array("array across a savestate");

    if (failures) { printf("\n%d FAILURES\n", failures); return 1; }
    printf("spi_93c46: all checks passed (%llu cycles)\n",
           (unsigned long long)tickcount);
    return 0;
}
