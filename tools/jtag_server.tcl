# SeibuSPI - persistent JTAG console.
#
# Run this ONCE, in your own terminal, and leave it up:
#
#     quartus_stp -t tools/jtag_server.tcl
#
# Then, when the scene you care about is on screen, press ENTER. That freezes
# the CPU instantly. Press ENTER again to let it run.
#
# Why this exists: quartus_stp takes about five seconds to start and claim the
# JTAG chain, which is far too slow to catch a scene that lasts a couple of
# seconds. Guessing the delay instead does not work either -- the ROM download
# shifts the whole attract sequence by seconds between runs, and several of the
# measurements taken that way landed on the wrong scene entirely and were
# reported as faults that did not exist. Holding one session open and letting a
# human press a key at the right moment removes that whole class of error.
#
# It also takes commands from a file, so Claude can instrument whatever you
# froze without needing the JTAG for itself:
#
#     echo vitals > /tmp/slop_cmd        (or use tools/slop)
#
# Every command's output is appended to /tmp/slop_out.txt as well as printed
# here, so both of us see the same thing.

package require ::quartus::insystem_source_probe

set CMDFILE /tmp/slop_cmd
set OUTFILE /tmp/slop_out.txt

# ---------------------------------------------------------------- plumbing --

proc find_device {} {
    foreach hw [get_hardware_names] {
        foreach dev [get_device_names -hardware_name $hw] {
            if {[string match "*5CS*" $dev]} { return [list $hw $dev] }
        }
    }
    error "no Cyclone V found on any programming hardware"
}

proc dec2bin {v width} {
    set s ""
    for {set i [expr {$width-1}]} {$i >= 0} {incr i -1} {
        append s [expr {($v >> $i) & 1}]
    }
    return $s
}

proc bin2hex {bits} {
    set out ""
    set n [string length $bits]
    set pad [expr {(4 - ($n % 4)) % 4}]
    set bits [string repeat "0" $pad]$bits
    for {set i 0} {$i < [string length $bits]} {incr i 4} {
        append out [format "%X" [expr 0b[string range $bits $i [expr {$i+3}]]]]
    }
    return $out
}

proc fld {p a w} { return [expr 0b[string range $p $a [expr {$a+$w-1}]]] }

# Everything printed goes to the terminal AND to the log Claude reads.
proc say {msg} {
    global OUTFILE
    puts $msg
    flush stdout
    set f [open $OUTFILE a]
    puts $f $msg
    close $f
}

lassign [find_device] hw dev

set INSTANCES [dict create]
set raw [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
foreach inst $raw {
    lassign $inst idx swidth pwidth id
    dict set INSTANCES $id $idx
}

proc idx_of {want} {
    global INSTANCES
    if {[dict exists $INSTANCES $want]} { return [dict get $INSTANCES $want] }
    error "instance '$want' not found -- wrong bitstream? saw: $INSTANCES"
}

start_insystem_source_probe -hardware_name $hw -device_name $dev

set VITL [idx_of "VITL"]
set SNDV [idx_of "SNDV"]
set CTRL [idx_of "CTRL"]
set PEEK [idx_of "PEEK"]
set SUMS [idx_of "SUMS"]
set SDRM [idx_of "SDRM"]

# Soft lookup, unlike the others: a bitstream built before the EIP profiler has
# no PROF instance, and idx_of throws. The server has to keep working against
# whatever is currently on the board, so `prof` reports the absence instead.
set PROF -1
if {[dict exists $INSTANCES "PROF"]} { set PROF [dict get $INSTANCES "PROF"] }

set prof_lo   0
set prof_hi   0
set prof_p_in 0
set prof_p_to 0

# CTRL bits: [4:0] force a layer off (back, midl, fore, text, sprites),
#            [5] freeze the CPU, [6] force the vital signs panel on,
#            [7] clear the telemetry high-water marks (level, so pulse it).
set ctrl_val 0

proc write_ctrl {} {
    global CTRL ctrl_val
    write_source_data -instance_index $CTRL -value [dec2bin $ctrl_val 8]
    after 30
}

# ---------------------------------------------------------------- commands --

# VITL probe layout, MSB first. Keep in step with rtl/spi_jtag_peek.sv: new
# fields are appended on the LSB side so these offsets never move.
proc show_vitals {} {
    global VITL
    set p [read_probe_data -instance_index $VITL]
    say "--- vitals ---"
    # bit 366 is the effective freeze, so a freeze taken with a CONTROLLER
    # BUTTON shows up here too -- the CTRL source register alone would not.
    say [format "  state       %s" \
         [expr {[string index $p 366] eq "1" ? "FROZEN" : "running"}]]
    say [format "  CS:EIP      %s:%s" \
         [bin2hex [string range $p 122 137]] [bin2hex [string range $p 138 169]]]
    say [format "  layer_en    %s   (active low, 0 = shown)" [string range $p 44 48]]
    say [format "  vbl frames  %d" [fld $p 174 16]]
    say [format "  layer ovrun %d      sprite starved %d" [fld $p 105 16] [fld $p 0 16]]
    say [format "  sprite list codes!=0 %d   sprRAM OR %s" \
         [fld $p 270 16] [bin2hex [string range $p 286 317]]]
    say [format "  sprDMA src  %s (dword idx; x4 = byte addr)   trigs %d" \
         [bin2hex [string range $p 318 333]] [fld $p 254 16]]
    say [format "  CPU writes  sprite buf %d   tilemap buf %d" \
         [fld $p 334 16] [fld $p 350 16]]
    say [format "  spr scanned %d  y-hit %d  emitted %d  tiles %d" \
         [fld $p 81 16] [fld $p 65 16] [fld $p 49 16] [fld $p 16 16]]
    say [format "  text DMA dw %d (expect 1024)" [fld $p 32 12]]
    # 4096 = this side thinks rowscroll is ON, 2560 = OFF. The tilemap source
    # stream is laid out differently in each case, so disagreeing with the game
    # here puts every layer's data in the wrong region.
    say [format "  rowscroll   %s   fore_d13 %s   tilemap DMA dwords %d (4096=rs on, 2560=off)" \
         [string index $p 367] [string index $p 368] [fld $p 369 13]]
    say [format "  scroll  back(%d,%d)  midl(%d,%d)  fore(%d,%d)" \
         [fld $p 462 16] [fld $p 446 16] \
         [fld $p 430 16] [fld $p 414 16] \
         [fld $p 398 16] [fld $p 382 16]]
}

# SNDV is its own probe rather than more bits on VITL: altsource_probe caps a
# probe at 511 bits and VITL is already at 478.
#   0..15 z80 pc, 16..31 fifo reads, 32..47 ymf writes, 48..63 rom stalls,
#   64..79 synth overruns, 80..95 slots sounding (PCM voices + FM operators),
#   96..111 fifo2 pushes (Z80 -> 386), 112..127 fifo2 pops (386 reads 0x680),
#   128..143 longest FIFO-full run, 144..152 peak FIFO fill,
#   153..168 longest sprite-DMA gap, 169..184 longest single Z80 fetch wait,
#   185..216 stall EIP, 217..232 stall CS.
#
# Everything up to 127 is a free-running counter that wraps between samples --
# 13b and 14.9 both record being lied to by one. Everything from 128 up is a
# HIGH-WATER MARK and means the same thing at any sampling interval.
proc show_sound {} {
    global SNDV
    set p [read_probe_data -instance_index $SNDV]
    say "--- sound ---"
    say [format "  Z80 PC      %s   (stuck = the sound CPU is not running)" \
         [bin2hex [string range $p 0 15]]]
    say [format "  fifo reads  %d   ymf writes %d" [fld $p 16 16] [fld $p 32 16]]
    say [format "  rom stalls  %d   (SDRAM fetches the line buffer missed)" [fld $p 48 16]]
    say [format "  voices      %d   overruns %d (samples the engine could not finish)" \
         [fld $p 80 16] [fld $p 64 16]]
    say [format "  fifo2 push  %d   pop %d   (Z80 -> 386; SXX2C only)" \
         [fld $p 96 16] [fld $p 112 16]]
    # High-water marks. 1 unit = 1024 clk_sys = 17.87 us; one frame at 53.99 Hz
    # is 1036 units, and a quarter-second block is about 13,974.
    set pk [fld $p 144 9]
    set fm [fld $p 128 16]
    set gp [fld $p 153 16]
    set wm [fld $p 169 16]
    say [format "  fifo peak   %d of 511   full for up to %d = %.3f s   (386 blocked in the handshake)" \
         $pk $fm [expr {$fm * 1024.0 / 57272727.0}]]
    say [format "  frame gap   %d = %.3f s   (worst sprite-DMA interval; 1 frame = 1036)" \
         $gp [expr {$gp * 1024.0 / 57272727.0}]]
    say [format "  fetch wait  %d clk = %.1f us   (worst single Z80 ROM fetch; ch3 is bottom priority)" \
         $wm [expr {$wm / 57.272727}]]
    # Latched the first time the frame gap passed two frames since the last
    # clear. 00000000 means no hitch that big has happened.
    set se [bin2hex [string range $p 185 216]]
    set sc [bin2hex [string range $p 217 232]]
    if {$se eq "00000000"} {
        say "  stall at    -- (no gap past two frames since the last clear)"
    } else {
        say [format "  stall at    CS %s EIP %s   (386 here when the frame gap passed 2 frames)" $sc $se]
    }
}

# SDRM: sdr_trans[94:0], MSB first. Channel i is bits [i*19+18:i*19], so in
# MSB-first string coordinates it starts at 76-i*19, width 19.
#
# The window is a fixed 2^21 clk_ram cycles and the controller spends exactly
# eight of them on a transaction (IDLE, WAIT, RW1, IDLE_5..IDLE_1), so
# occupancy is trans*8/2^21. See rtl/spi_sdr_stats.sv, which also says why
# there is no per-channel latency figure here.
# EIP profiler. The core counts clk_cpu cycles with `eip` inside a window and
# clk_cpu cycles in total, both free-running from reset. Point the window at the
# game's wait-for-vblank spin and the ratio is the 386's idle fraction, measured
# continuously rather than by sampling `vitals` a few hundred times.
#
# Known windows (PLAN.md section 16):
#   rdft   prof 0x203F00 0x203F3A
#   rfjet  prof 0x20607C 0x2060B8
#
# Reads print the delta since the previous read, which is what makes this a
# rate: the counters are never cleared, so two reads bracket an interval. The
# 40-bit counters wrap in about 10.7 hours, and the mask below makes a wrap
# across a single interval come out right anyway.
proc set_prof_window {lo hi} {
    global PROF prof_lo prof_hi
    if {$PROF < 0} { return }
    set prof_lo $lo
    set prof_hi $hi
    write_source_data -instance_index $PROF \
        -value "[dec2bin $hi 32][dec2bin $lo 32]"
    after 30
    say [format ">>> eip window = %08X .. %08X" $lo $hi]
}

proc show_prof {} {
    global PROF prof_lo prof_hi prof_p_in prof_p_to
    if {$PROF < 0} {
        say "--- eip profiler ---"
        say "  NOT IN THIS BITSTREAM. The core on the board predates the"
        say "  profiler; rebuild and reflash to use it."
        return
    }
    set p [read_probe_data -instance_index $PROF]
    set tot [fld $p 0 40]
    set inw [fld $p 40 40]
    set mask 0xFFFFFFFFFF
    set d_to [expr {($tot - $prof_p_to) & $mask}]
    set d_in [expr {($inw - $prof_p_in) & $mask}]
    set prof_p_to $tot
    set prof_p_in $inw
    say "--- eip profiler ---"
    if {$prof_lo == 0 && $prof_hi == 0} {
        say "  window     NOT SET -- `prof <lo> <hi>` first, e.g. prof 0x20607C 0x2060B8"
    } else {
        say [format "  window     %08X .. %08X" $prof_lo $prof_hi]
    }
    say [format "  cycles     in %d of %d total (since reset)" $inw $tot]
    if {$d_to > 0} {
        say [format "  interval   %d cycles = %.3f s" $d_to [expr {$d_to / 28636364.0}]]
        say [format "  IN WINDOW  %.1f%%   -> the 386 is busy %.1f%% of the time" \
             [expr {100.0 * $d_in / $d_to}] [expr {100.0 * (1.0 - double($d_in)/$d_to)}]]
    } else {
        say "  interval   first read, nothing to compare against yet -- read again"
    }
}

proc show_sdram {} {
    global SDRM
    set p [read_probe_data -instance_index $SDRM]
    set WINDOW [expr {1 << 21}]
    set names {ch1-386prg ch2-tiles ch3-z80 ch4-sprites ch5-pcm}
    say "--- sdram, per 18.31 ms window (one frame) ---"
    say "  channel        trans   occupancy    MB/s"
    set tot 0
    for {set i 0} {$i < 5} {incr i} {
        set tr [fld $p [expr {76 - $i*19}] 19]
        set tot [expr {$tot + $tr}]
        say [format "  %-11s %8d   %6.2f%%   %6.1f" [lindex $names $i] $tr \
             [expr {100.0 * $tr * 8 / $WINDOW}] \
             [expr {$tr * 8.0 / 0.018311 / 1048576}]]
    }
    say [format "  TOTAL       %8d   %6.2f%%   %6.1f   (refresh is on top, ~2%%)" \
         $tot [expr {100.0 * $tot * 8 / $WINDOW}] \
         [expr {$tot * 8.0 / 0.018311 / 1048576}]]
}

# SUMS is 221 bits, MSB first, matching spi_jtag_peek.sv's concatenation:
#   0..15    fails       16..31   passes      32..36   part_end[4:0]
#   37..62   bytes_in[25:0]       63..88   bytes_out[25:0]
#   89..92   ok          93..124  sum_sprites 125..156 sum_tiles
#   157..188 sum_chars   189..220 sum_prg
#
# THESE WERE STALE AND IT COST A WHOLE DIAGNOSIS. `bytes_out` was added to the
# probe and only tools/jtag_peek.tcl was updated, so everything here from
# bytes_in onward was read 27 bits early: bytes_in came back 22,626,304 against
# a true 23,396,352 and the four checksums looked nibble-shifted. It read as a
# short download on a brand new fast-load path, and the giveaway was the panel
# contradicting itself -- the hardware's own `passes 1 fails 0` said PRG matched
# while the PRG value printed next to it did not.
#
# A shifted field is still a plausible number, which is why the width is checked
# and printed rather than assumed. If it does not say 221, nothing below it
# means anything. Keep this in step with jtag_peek.tcl's `sums`, which reads the
# same probe and is the other place this drifts.
proc show_sums {} {
    global SUMS
    set p [read_probe_data -instance_index $SUMS]
    set n [string length $p]
    say "--- rom checksums ---"
    if {$n != 221} {
        say "  WIDTH MISMATCH: probe is $n bits, expected 221."
        say "  Every field below is shifted and meaningless. Fix the offsets."
    }
    say [format "  bytes_in %d  bytes_out %d   ok bits %s   passes %d fails %d" \
         [fld $p 37 26] [fld $p 63 26] [string range $p 89 92] \
         [fld $p 16 16] [fld $p 0 16]]
    say [format "  part_end %d   (rdfts expects bytes_in 23396352)" [fld $p 32 5]]
    say [format "  PRG %s  CHARS %s  TILES %s  SPRITES %s" \
         [bin2hex [string range $p 189 220]] [bin2hex [string range $p 157 188]] \
         [bin2hex [string range $p 125 156]] [bin2hex [string range $p 93 124]]]
}

proc peek64 {addr} {
    global PEEK
    set prev [read_probe_data -instance_index $PEEK]
    set go [expr {[string index $prev 0] eq "1" ? 0 : 1}]
    write_source_data -instance_index $PEEK -value "${go}[dec2bin $addr 25]"
    for {set i 0} {$i < 400} {incr i} {
        set p [read_probe_data -instance_index $PEEK]
        if {[string index $p 0] eq $go} { return [string range $p 1 end] }
        after 2
    }
    error [format "no ack for address 0x%07X" $addr]
}

proc do_dump {addr count} {
    say [format "--- sdram dump from 0x%07X ---" $addr]
    for {set i 0} {$i < $count} {incr i} {
        set a [expr {$addr + $i*8}]
        say [format "  %07X %s" $a [bin2hex [peek64 $a]]]
    }
}

proc handle {line} {
    global ctrl_val OUTFILE
    set line [string trim $line]
    set cmd  [lindex $line 0]

    # A bare ENTER is the whole point of this thing: toggle the freeze.
    if {$line eq ""} { set cmd "toggle" }

    switch -- $cmd {
        toggle {
            set ctrl_val [expr {$ctrl_val ^ 32}]
            write_ctrl
            if {$ctrl_val & 32} {
                say ">>> FROZEN  (press ENTER again to resume)"
                show_vitals
            } else {
                say ">>> running"
            }
        }
        freeze { set ctrl_val [expr {$ctrl_val | 32}];  write_ctrl; say ">>> FROZEN" ; show_vitals }
        thaw   { set ctrl_val [expr {$ctrl_val & ~32}]; write_ctrl; say ">>> running" }
        vitals { show_vitals }
        sound  { show_sound }
        sums   { show_sums }
        sdram  { show_sdram }
        clear {
            # Zero the telemetry high-water marks and the latched stall
            # address. Boot is not a stall, and its 0.373 s sprite-DMA gap
            # otherwise saturates `frame gap` before the game has drawn
            # anything -- so clear at the moment you want to start watching.
            #
            # NOTE for anyone extending this switch: a comment BETWEEN
            # pattern/body pairs is not a comment. The body of `switch` is a
            # list, so `#` becomes a pattern and the words after it become
            # bodies and patterns in turn -- which is how this one first went
            # in and killed the server with `invalid command name "the"`.
            # Comments belong inside a body, like this one.
            set ctrl_val [expr {$ctrl_val | 128}];  write_ctrl
            after 50
            set ctrl_val [expr {$ctrl_val & ~128}]; write_ctrl
            say ">>> telemetry high-water marks cleared"
            show_sound
        }
        mask {
            # keep the freeze bit, replace the layer bits
            set v [lindex $line 1]
            set ctrl_val [expr {($ctrl_val & 32) | ($v & 0xDF)}]
            write_ctrl
            say [format ">>> ctrl = 0x%02X (layers %05b, frozen %d)" \
                 $ctrl_val [expr {$ctrl_val & 31}] [expr {($ctrl_val >> 5) & 1}]]
        }
        dump {
            set a [lindex $line 1]
            set n [lindex $line 2]
            if {$n eq ""} { set n 8 }
            do_dump [expr $a] $n
        }
        mark { say ">>> MARK [lindex $line 1]" }
        prof {
            # `prof` alone reads; `prof <lo> <hi>` sets the window first. The
            # window is inclusive and in linear addresses, the same numbers the
            # vitals CS:EIP field prints. Comments live inside a body here --
            # see the note in `clear`.
            #
            # No $PROF here on purpose: `handle` only declares ctrl_val and
            # OUTFILE global, so reading any other global from this body throws
            # "no such variable". The two procs below declare their own.
            set a [lindex $line 1]
            set b [lindex $line 2]
            if {$a ne "" && $b ne ""} { set_prof_window [expr $a] [expr $b] }
            show_prof
        }
        help {
            say "ENTER = freeze/resume   freeze | thaw | vitals | sound | sums"
            say "sdram (per-channel bus occupancy) | clear | mask <n>"
            say "prof [<lo> <hi>] (eip profiler; read twice for a rate)"
            say "dump <addr> <count> | mark <text> | quit"
        }
        quit - exit {
            say ">>> releasing JTAG"
            end_insystem_source_probe
            exit 0
        }
        default { say "?? unknown command: $line   (try 'help')" }
    }
}

# ------------------------------------------------------------------- main ---

file delete -force $OUTFILE
say "SeibuSPI JTAG console"
say "hardware: $hw"
say "device:   $dev"
say "instances: $INSTANCES"
say ""
say "Press ENTER to freeze the core at the moment you care about."
say "Press ENTER again to resume. Type 'help' for more, 'quit' to exit."
say ""

fconfigure stdin -blocking 0
set watch_stdin 1

while {1} {
    # stdin: -1 means no complete line is waiting, which is not the same as an
    # empty line (a bare ENTER), and that distinction is what makes ENTER usable
    # as the freeze key.
    if {$watch_stdin} {
        if {[gets stdin line] >= 0} {
            handle $line
        } elseif {[eof stdin]} {
            # Started without a terminal (or the terminal went away). Stop
            # reading stdin altogether and serve the command file only.
            # Switching the channel back to blocking here instead would wedge
            # the next gets forever and take the command file down with it.
            set watch_stdin 0
            say ">>> stdin closed; serving $CMDFILE only"
        }
    }

    if {[file exists $CMDFILE]} {
        set f [open $CMDFILE r]
        set cmds [read $f]
        close $f
        file delete -force $CMDFILE
        foreach c [split $cmds "\n"] {
            if {[string trim $c] ne ""} { handle $c }
        }
        # tell the shell helper the batch is finished
        set f [open $OUTFILE a]
        puts $f "<<<DONE>>>"
        close $f
    }

    after 40
}
