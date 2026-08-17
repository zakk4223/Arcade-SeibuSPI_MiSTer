# Read SDRAM out of a running SlopperPI over JTAG.
#
#   quartus_stp -t tools/jtag_peek.tcl sums
#   quartus_stp -t tools/jtag_peek.tcl dump <addr> <count>
#   quartus_stp -t tools/jtag_peek.tcl list
#
# Talks to the two In-System Sources & Probes instances in rtl/spi_jtag_peek.sv:
# PEEK does one 64-bit read per request, SUMS reports what spi_romcheck computed.
#
# Every failure so far has been ambiguous between the hardware being wrong and
# the instrument being wrong. This reads the actual bytes, so it settles that.

package require ::quartus::insystem_source_probe

proc find_device {} {
    foreach hw [get_hardware_names] {
        foreach dev [get_device_names -hardware_name $hw] {
            if {[string match "*5CS*" $dev]} {
                return [list $hw $dev]
            }
        }
    }
    error "no Cyclone V found on any programming hardware"
}

# instance_id from the RTL -> instance_index used by the Tcl API. This query
# opens its own JTAG session, so it has to run before start_insystem_source_probe.
proc index_of {want} {
    global INSTANCES
    if {[dict exists $INSTANCES $want]} { return [dict get $INSTANCES $want] }
    error "instance '$want' not found -- is this the build with spi_jtag_peek?\n\
           saw: $INSTANCES"
}

proc bin2hex {bits} {
    set out ""
    set n [string length $bits]
    # pad on the left so the string is a whole number of nibbles
    set pad [expr {(4 - ($n % 4)) % 4}]
    set bits [string repeat "0" $pad]$bits
    for {set i 0} {$i < [string length $bits]} {incr i 4} {
        append out [format "%X" [expr 0b[string range $bits $i [expr {$i+3}]]]]
    }
    return $out
}

proc peek64 {idx addr} {
    set prev [read_probe_data -instance_index $idx]
    set ack_prev [string index $prev 0]
    set go [expr {$ack_prev eq "1" ? 0 : 1}]

    # source = {go, addr[25:0]}, MSB first -- 27 bits. `go` is its own bit above
    # the address; it used to overlap addr[25], which read 32 MB high.
    #
    # TWO writes, and the first one is not redundant. `go` and the address share
    # one ISSP source word and the RTL does not see all 27 bits change in the
    # same cycle, so a single write can fire the request on a HALF-UPDATED
    # address -- the read then lands on a neighbouring word and returns data
    # that looks entirely plausible. Measured on hardware: 17 of 120 sequential
    # reads wrong that way, every wrong value being another word within +-64
    # bytes. Writing the address first with `go` HELD, then re-writing the same
    # word with only `go` flipped, makes the address bits identical across both
    # writes, so no intermediate state can address anything else: 120 of 120.
    set hold [expr {$go ? 0 : 1}]
    write_source_data -instance_index $idx -value "${hold}[dec2bin $addr 26]"
    write_source_data -instance_index $idx -value "${go}[dec2bin $addr 26]"

    for {set i 0} {$i < 400} {incr i} {
        set p [read_probe_data -instance_index $idx]
        if {[string index $p 0] eq $go} { return [string range $p 1 end] }
        after 2
    }
    error [format "no ack for address 0x%07X" $addr]
}

proc dec2bin {v width} {
    set s ""
    for {set i [expr {$width-1}]} {$i >= 0} {incr i -1} {
        append s [expr {($v >> $i) & 1}]
    }
    return $s
}

set args $quartus(args)
set mode [lindex $args 0]

lassign [find_device] hw dev
puts "hardware: $hw"
puts "device:   $dev"

set INSTANCES [dict create]
set raw [get_insystem_source_probe_instance_info -hardware_name $hw -device_name $dev]
foreach inst $raw {
    # {index source_width probe_width instance_id}
    lassign $inst idx swidth pwidth id
    dict set INSTANCES $id $idx
}

start_insystem_source_probe -hardware_name $hw -device_name $dev

if {$mode eq "list"} {
    foreach inst $raw { puts "instance: $inst" }
} elseif {$mode eq "sums"} {
    set p [read_probe_data -instance_index [index_of "SUMS"]]
    # 221 bits, MSB first, matching spi_jtag_peek.sv's concatenation:
    #   0..15    fails       16..31   passes      32..36   part_end[4:0]
    #   37..62   bytes_in[25:0]       63..88   bytes_out[25:0]
    #   89..92   ok          93..124  sum_sprites 125..156 sum_tiles
    #   157..188 sum_chars   189..220 sum_prg
    #
    # These offsets were stale twice over before this: bytes_in was read as 25
    # bits after the address map went to 26, and part_end as 4 after the part
    # tables grew past sixteen. Every field after a widened one moves, so
    # re-derive the whole list rather than patching one entry.
    #
    # And the RTL's own probe_width had been left at 193 while the
    # concatenation reached 195, which truncated the top two bits of `fails`
    # and shifted EVERY field read here -- silently, since a shifted field is
    # still a number. That is what the width line below is for: if it does not
    # say 221, nothing under it means anything. spi_jtag_peek.sv now builds the
    # width by adding up its fields so the two cannot drift apart again.
    set n [string length $p]
    puts "raw width   = $n  (expected 221)"
    if {$n != 221} {
        puts "WIDTH MISMATCH -- the fields below are shifted and meaningless."
    }
    puts "check fails = [expr 0b[string range $p 0 15]]"
    puts "check passes= [expr 0b[string range $p 16 31]]"
    puts "part_end    = [bin2hex [string range $p 32 36]]"
    set bi [string range $p 37 62]
    puts "bytes_in    = [expr 0b$bi]  (expected 23396352 for rdfts)"
    # For a set with no decoded part these must be EQUAL. A shortfall means the
    # loader is still working (or stuck); an excess means it emitted more than
    # it took, which for a straight copy means bytes are being repeated.
    puts "bytes_out   = [expr 0b[string range $p 63 88]]"
    puts "ok bits     = [string range $p 89 92]"
    puts "sum SPRITES = [bin2hex [string range $p 93 124]]"
    puts "sum TILES   = [bin2hex [string range $p 125 156]]"
    puts "sum CHARS   = [bin2hex [string range $p 157 188]]"
    puts "sum PRG     = [bin2hex [string range $p 189 220]]"
} elseif {$mode eq "vitals"} {
    set p [read_probe_data -instance_index [index_of "VITL"]]
    # 254 bits, MSB first: 0..15 spr_starved, 16..31 spr_tiles,
    # 32..43 text_dma_dw, 44..48 layer_en, 49..64 spr_emitted,
    # 65..80 spr_yhit, 81..96 spr_scanned, 97..102 text_col, 103..104 ovr_layer,
    # 105..120 overruns, 121 irq, 122..137 cs, 138..169 eip, 170..173 why,
    # 174..189 vbl, 190..205 dma_pal, 206..221 dma_tm, 222..237 iowr,
    # 238..253 prg
    proc fld {p a n} { return [expr 0b[string range $p $a [expr {$a+$n-1}]]] }
    puts "spr starved= [fld $p 0 16]   (lines that ran out of budget)"
    puts "sprDMA trig= [fld $p 254 16]  (sprite-list DMA fires; 0 = list never loaded)"
    puts "codes != 0 = [fld $p 270 16]  (of 512 entries, per line; 0 = list empty)"
    puts "sprRAM OR  = [bin2hex [string range $p 286 317]]  (0 = sprite RAM all zeros)"
    puts "sprDMA src = [bin2hex [string range $p 318 333]]  (dword idx; byte addr = x4)"
    puts "CPU wr spr = [fld $p 334 16]  (dword writes to 0x37000 buffer; 0 = never written)"
    puts "CPU wr tm  = [fld $p 350 16]  (dword writes to 0x38000 buffer -- control, must move)"
    puts "spr tiles  = [fld $p 16 16]  (tile columns fetched)"
    puts "text DMA dw= [fld $p 32 12]  (expect 1024)"
    puts "layer_en   = [string range $p 44 48]"
    puts "spr scanned= [fld $p 81 16]"
    puts "spr y-hit  = [fld $p 65 16]"
    puts "spr emitted= [fld $p 49 16]"
    puts "vbl        = [fld $p 174 16]"
    puts "overruns   = [fld $p 105 16]"
    puts "CS         = [bin2hex [string range $p 122 137]]"
    puts "EIP        = [bin2hex [string range $p 138 169]]"
} elseif {$mode eq "sound"} {
    set p [read_probe_data -instance_index [index_of "SNDV"]]
    # 299 bits, MSB first: 0..15 z80 pc, 16..31 fifo reads, 32..47 ymf writes,
    # 48..63 rom stalls, 64..79 synth overruns, 80..95 slots sounding,
    # 96..111 f2 writes, 112..127 f2 reads, 128..143 longest FIFO-full run,
    # 144..152 peak FIFO fill, 153..168 longest sprite-DMA gap,
    # 169..184 longest single Z80 ROM fetch wait. New fields go on the LSB
    # side, so the offsets above them never move.
    proc fld {p a n} { return [expr 0b[string range $p $a [expr {$a+$n-1}]]] }
    puts "Z80 PC     = [bin2hex [string range $p 0 15]]  (unchanging = sound CPU not running)"
    puts "fifo reads = [fld $p 16 16]  (commands the Z80 took from the 386)"
    puts "ymf writes = [fld $p 32 16]"
    puts "rom stalls = [fld $p 48 16]  (line-buffer misses that hit SDRAM)"
    # Which SIDE of the Z80 -> 386 FIFO is stuck. The 386 blocks at 0x26D65A
    # waiting for a reply; pushes without pops means the 386 is not reading
    # 0x680, pops without pushes means the Z80 never sent one. Printed because
    # the sample-flash bring-up needed exactly this and had to guess (18.x).
    puts "f2 push/pop= [fld $p 96 16]/[fld $p 112 16]  (Z80 -> 386 replies sent/taken)"
    puts "voices     = [fld $p 80 16]  (PCM + FM slots sounding on the last sample)"
    puts "synth ovrun= [fld $p 64 16]  (samples the engine could not finish in time)"
    # These two are high-water marks, so unlike everything above them they mean
    # the same thing whatever interval they are sampled over. A Z80 that stops
    # draining the FIFO blocks the 386 in the sound handshake -- a gameplay
    # freeze with no video symptom -- and this is what names it.
    set pk [fld $p 144 9]
    set fm [fld $p 128 16]
    puts [format "fifo peak  = %d of 511  (deepest the 386 -> Z80 FIFO has ever got)" $pk]
    puts [format "fifo full  = %d units = %.3f s  (longest unbroken block of the 386)" \
          $fm [expr {$fm * 1024.0 / 57272727.0}]]
    # The game loop pushes the sprite list once a frame. 1036 units is one
    # frame at 53.99 Hz; anything much larger is the 386 having hitched, and
    # the fifo readings above say whether the sound handshake caused it.
    set gp [fld $p 153 16]
    puts [format "frame gap  = %d units = %.3f s  (longest gap between sprite DMAs; 1 frame = 1036)" \
          $gp [expr {$gp * 1024.0 / 57272727.0}]]
    # ch3 is the lowest priority SDRAM channel, so this is how long the worst
    # single Z80 fetch waited behind tiles, the 386, sprites and PCM. One
    # unstarved read is tens of cycles; thousands means the sound CPU is being
    # held off long enough to matter. 65535 means it saturated.
    set wm [fld $p 169 16]
    puts [format "fetch wait = %d clk = %.1f us  (worst single Z80 ROM fetch; ch3 is bottom priority)" \
          $wm [expr {$wm / 57.272727}]]
    # The sample flash, on an authentic-flash MRA only; all zeroes everywhere
    # else. 233..264 bytes programmed, 265..280 blocks erased, 281..296 commands
    # DROPPED, 297..298 which chips are busy. A full run programs ~2M bytes and
    # erases 32 blocks. `drops` is the one that matters: it must be 0, and if it
    # is not then bytes went missing and the image is silently wrong.
    set fp [fld $p 233 32]
    set fe [fld $p 265 16]
    set fd [fld $p 281 16]
    if {$fp || $fe || $fd} {
        puts [format "flash prog = %d bytes, %d blocks erased, %d DROPPED (drops must be 0)" \
              $fp $fe $fd]
        puts [format "flash busy = %d  (bit0 = chip 0, bit1 = chip 1)" [fld $p 297 2]]
    }
    # 299..324: bytes of the save file received at load. Zero on an -update MRA
    # that has an .nvm means the file never reached the core.
    set nv [fld $p 299 26]
    if {$nv} { puts [format "nvram in   = %d bytes  (the save file, at load)" $nv] }
    # 325..340 asks, 341..356 beats served. asks>0 with beats==0 means the core
    # asked for a save and the host never came for it.
    set asks  [fld $p 325 16]
    set beats [fld $p 341 26]
    if {$asks || $beats} {
        puts [format "nvram save = %d asks, %d beats served" $asks $beats]
    }

    # ---- the watch (PLAN.md 19.11) ------------------------------------
    # One halfword of the sample flash -- byte 0x29FE, the one rdft2 comes back
    # erased -- seen at BOTH ends of the clk_sys -> clk_ram handoff. 367..393
    # is what spi_soundflash issued, 450..493 what spi_sdr_arb4 latched.
    #
    # Read it as: the two must agree, and both must show ONE low-lane write of
    # 0xFE. A high-lane write means the byte went to 0x29FF, where the next
    # program overwrites it -- which is the only way to lose exactly one byte
    # and still issue the right number of writes.
    set fwn  [fld $p 367 8]
    set fwbe [fld $p 375 2]
    set fwd  [fld $p 377 8]
    set fwe  [fld $p 385 8]
    set fwea [fld $p 393 1]
    set awn  [fld $p 450 8]
    set awbe [fld $p 458 2]
    set awd  [fld $p 460 8]
    set awt  [fld $p 468 26]
    if {$fwn || $awn || $awt} {
        puts [format "watch flash= %d writes, last be=%d data=%02X, %d erases%s" \
              $fwn $fwbe $fwd $fwe [expr {$fwea ? " AFTER a program (!)" : ""}]]
        puts [format "watch arb  = %d writes, last be=%d data=%02X, %d taken on d total" \
              $awn $awbe $awd $awt]
        # Four entries of {addr[11:0], be}: the writes from two bytes below the
        # watch onwards, so a byte issued somewhere else has its neighbours to
        # place it against. The shift register puts the NEWEST in the low bits,
        # and the probe is read most-significant first, so walking i upwards
        # walks it oldest to newest.
        set tr ""
        for {set i 0} {$i < 4} {incr i} {
            set e [fld $p [expr {394 + $i*14}] 14]
            append tr [format " %03X/%d" [expr {$e >> 2}] [expr {$e & 3}]]
        }
        puts "watch trace=$tr  (addr/be, oldest first)"
    }
} elseif {$mode eq "sdram"} {
    # The sdram side of the watch (PLAN.md 19.12). What this module actually
    # put on the bus for the two writes to the watched halfword, and what it
    # did in the four clocks after each.
    #
    # The hypothesis under test: CMD_WRITE goes out with auto-precharge and the
    # controller can issue the next ACTIVE three clocks later, against a
    # tWR + tRP nearer four. Within one bank that truncates the write. So the
    # numbers that matter are `gap` and whether `bank` matches.
    #
    # Entry 0 is the byte that goes missing (low lane, mask 10), entry 1 the
    # one right after it that lands (high lane, mask 01). Same address, same
    # run: whatever differs is the fault.
    set p [read_probe_data -instance_index [index_of "SDRW"]]
    proc fld {p a n} { return [expr 0b[string range $p $a [expr {$a+$n-1}]]] }
    proc cmdname {c} {
        switch -- $c {
            7 { return "NOP " }  3 { return "ACT " }  5 { return "READ" }
            4 { return "WRIT" }  2 { return "PRE " }  1 { return "RFSH" }
            default { return [format "?%d  " $c] }
        }
    }
    set takes  [fld $p 0 8]
    set writes [fld $p 8 8]
    set same   [fld $p 16 8]
    set wbank  [fld $p 24 2]
    set wchip  [fld $p 26 1]
    puts [format "ch3 watch  = %d taken, %d reached CMD_WRITE, %d followed by a SAME-bank ACTIVE" \
          $takes $writes $same]
    puts [format "write bank = %d  chip %d" $wbank $wchip]
    # Nested braces, not quotes: inside a braced list Tcl does not process
    # quotes, so the first attempt printed its own source line.
    foreach {name off} {{entry0, the byte that goes missing} 27
                        {entry1, the control that lands}     67} {
        set dq    [fld $p $off 16]
        set dqm   [fld $p [expr {$off+16}] 2]
        set gap   [fld $p [expr {$off+18}] 4]
        set ab    [fld $p [expr {$off+22}] 2]
        set ac    [fld $p [expr {$off+24}] 1]
        set after [fld $p [expr {$off+25}] 15]
        set cmds ""
        for {set i 4} {$i >= 0} {incr i -1} {
            append cmds [cmdname [expr {($after >> ($i*3)) & 7}]] " "
        }
        puts [format "%s dq=%04X mask=%s  next ACTIVE %s  bus: %s" \
              $name $dq [format %02b $dqm] \
              [expr {$gap ? "+$gap clk, bank $ab chip $ac" : "none within the window"}] \
              $cmds]
    }
    # ---- the FIFO watch (PLAN.md 19.14) -------------------------------
    # The chain's other two links, frozen at the program command for the
    # watched byte: what the 386 FIFO handed the Z80 just before it, and what
    # the flash latched. Near this address the payload runs 00, 00, FE, FF, so
    # a healthy freeze reads pops=0000 00FE with din=FE.
    #
    #   pops ...00FE, din FE, dq FEFE   nothing wrong -- this run kept the byte
    #   pops ...00FE, din FF            corrupted between the FIFO and the flash
    #   pops ...00FF, din FF            the FIFO handed over the wrong byte
    set fwu [fld $p 107 32]
    set fwp [fld $p 139 32]
    set fwl [fld $p 171 9]
    set fwe [fld $p 180 16]
    set fwd [fld $p 196 8]
    set fwf [fld $p 204 1]
    if {$fwf} {
        puts [format "fifo watch = pushed %08X by the 386" $fwu]
        puts [format "             pops   %08X  (last four bytes the Z80 took, newest low)" $fwp]
        puts [format "             flash latched %02X, FIFO had %d bytes waiting" $fwd $fwl]
    } else {
        puts "fifo watch = never froze -- no program command for the watched byte"
    }
    puts [format "empty reads= %d  (reads of 0x4008 with the FIFO empty; these pop nothing)" $fwe]
} elseif {$mode eq "gdt"} {
    set p [read_probe_data -instance_index [index_of "GDTS"]]
    # probe = {gdt5..gdt0}, MSB first -> gdt0 is the last 32 bits
    for {set i 0} {$i < 6} {incr i} {
        set hi [expr {(5-$i)*32}]
        puts [format "gdt dword %d (byte 0x%03X) = %s" $i [expr {0x800+$i*4}] \
              [bin2hex [string range $p $hi [expr {$hi+31}]]]]
    }
} elseif {$mode eq "mask"} {
    # bit 0..3 = back, midl, fore, text; bit 4 = sprites (1 = force off);
    # bit 5 = freeze the CPU.
    set v [lindex $args 1]
    if {$v eq ""} { set v 0 }
    # The index has to be resolved into its own variable first. Writing
    # [index_of \"CTRL\"] inside a "..." string does not work: Tcl parses the
    # bracket body as a script, where \"CTRL\" is a malformed word, so the whole
    # branch failed to parse. That made every `mask` call a silent no-op -- the
    # layer-isolation sweep changed nothing and `mask 0` never released the
    # CPU freeze, which is why repeated runs looked identical.
    set cidx [index_of "CTRL"]
    write_source_data -instance_index $cidx -value [dec2bin $v 8]
    after 50
    set rb [read_source_data -instance_index $cidx]
    puts "layer mask = $rb  (wrote [dec2bin $v 8])"
} elseif {$mode eq "sdram"} {
    # spi_sdr_stats packs trans[18:0] = ch1 .. trans[94:76] = ch5, and the probe
    # string arrives MSB first, so the LEFTMOST field is ch5 and the rightmost
    # ch1 -- the reverse of the channel numbering, which is worth stating because
    # reading it the natural way swaps the PCM and 386 figures and both are
    # plausible numbers.
    #
    # Each count is completed transactions in one 2^21 clk_ram window (18.31 ms,
    # one frame at 53.99 Hz to within a percent), latched at the window end so it
    # cannot wrap between samples. The controller owns the bus for a fixed 8
    # clk_ram cycles per transaction, so occupancy is trans * 8 / 2^21.
    set p [read_probe_data -instance_index [index_of "SDRM"]]
    proc fld {p a n} { return [expr 0b[string range $p $a [expr {$a+$n-1}]]] }
    set total 0
    for {set i 0} {$i < 5} {incr i} {
        set v  [fld $p [expr {$i*19}] 19]
        set nm [lindex {ch5 ch4 ch3 ch2 ch1} $i]
        set ds [lindex {PCM sprites Z80/peek tiles 386-prg} $i]
        set total [expr {$total + $v}]
        puts [format "%-4s %-9s %7d trans/frame  %6.2f%%" \
              $nm $ds $v [expr {$v * 800.0 / (1 << 21)}]]
    }
    puts [format "%-14s %7d trans/frame  %6.2f%%  (auto-refresh is on top)" \
          "ALL" $total [expr {$total * 800.0 / (1 << 21)}]]
} elseif {$mode eq "trace"} {
    set idx [index_of "VITL"]
    set n [lindex $args 1]
    if {$n eq ""} { set n 40 }
    set skip [lindex $args 2]
    if {$skip ne ""} { puts "waiting ${skip} ms before tracing..." ; after $skip }
    set prev ""
    set hist [dict create]
    for {set i 0} {$i < $n} {incr i} {
        set p [read_probe_data -instance_index $idx]
        set eip [bin2hex [string range $p 138 169]]
        set cs  [bin2hex [string range $p 122 137]]
        set why [string range $p 170 173]
        set io  [expr 0b[string range $p 222 237]]
        dict incr hist $eip
        set line "CS=$cs EIP=$eip why=$why iowr=$io"
        if {$line ne $prev} { set prev $line }
    }
    # A single EIP sample cannot tell a tight poll loop from an interrupt
    # handler that merely happens to be running. The histogram can.
    puts "EIP histogram over $n samples (most frequent first):"
    set pairs {}
    dict for {k v} $hist { lappend pairs [list $v $k] }
    foreach e [lsort -integer -index 0 -decreasing $pairs] {
        puts [format "  %5d  %s" [lindex $e 0] [lindex $e 1]]
    }
} elseif {$mode eq "rate"} {
    # Every counter on VITL is a free-running 16-bit wrap counter, so an absolute
    # reading says nothing. What matters is the rate, and above all the rate
    # PER FRAME: "how many scanlines lost their sprite budget in one frame" is
    # the number that decides whether the black band is a bandwidth shortfall.
    set idx [index_of "VITL"]
    set n   [lindex $args 1]
    if {$n eq ""} { set n 12 }
    set ms  [lindex $args 2]
    if {$ms eq ""} { set ms 500 }
    # Optional start delay so sampling can be aimed at one attract scene.
    set skip [lindex $args 3]
    if {$skip ne ""} { puts "waiting ${skip} ms before sampling..." ; after $skip }

    proc fld {p a w} { return [expr 0b[string range $p $a [expr {$a+$w-1}]]] }
    # 16-bit counters wrap; deltas must be taken modulo 2^16.
    proc d16 {now was} { return [expr {($now - $was) & 0xFFFF}] }

    # Timestamp every row against the wall clock. Freezing on a chosen scene
    # needs a delay guessed in advance, and the ROM download makes that guess
    # drift by seconds -- the last attempt landed on a black inter-scene gap.
    # Timestamps instead let a free-running capture be correlated with the
    # video after the fact, so the scene is identified rather than predicted.
    set t0 [clock milliseconds]
    puts "epoch_ms_start $t0"
    set have 0
    puts [format "%8s %7s %7s %8s %8s %8s %8s %9s %9s" \
          "t_ms" "frames" "wrSPR/f" "wrTM/f" "codes!=0" "sprRAMor" "y-hit/f" "emit/f" "sprDMA/f"]
    for {set i 0} {$i < $n} {incr i} {
        set p [read_probe_data -instance_index $idx]
        set vbl [fld $p 174 16]; set stv [fld $p 0 16]; set ovr [fld $p 105 16]
        set scn [fld $p 81 16];  set yh  [fld $p 65 16]; set em [fld $p 49 16]
        set ws  [fld $p 334 16]; set wt  [fld $p 350 16]
        set nzc [fld $p 270 16]; set sd  [fld $p 254 16]
        set sor [bin2hex [string range $p 286 317]]
        if {$have} {
            set dv [d16 $vbl $pv]
            set ds [d16 $stv $ps]; set do [d16 $ovr $po]
            set dc [d16 $scn $pc]; set dy [d16 $yh $py]; set de [d16 $em $pe]
            set tm [expr {[clock milliseconds] - $t0}]
            set dws [d16 $ws $pws]; set dwt [d16 $wt $pwt]; set dsd [d16 $sd $psd]
            # guard: with no frames elapsed a per-frame figure is meaningless
            if {$dv > 0} {
                puts [format "%8d %7d %8.1f %7.1f %9d %9s %8.1f %8.1f %9.2f" \
                      $tm $dv [expr {double($dws)/$dv}] [expr {double($dwt)/$dv}] \
                      $nzc $sor \
                      [expr {double($dy)/$dv}] [expr {double($de)/$dv}] \
                      [expr {double($dsd)/$dv}]]
            }
        }
        set pv $vbl; set ps $stv; set po $ovr
        set pc $scn; set py $yh;  set pe $em
        set pws $ws; set pwt $wt; set psd $sd
        set have 1
        after $ms
    }
    puts "\n(one row per $ms ms. 224 active lines per frame, so starv/frm near 224"
    puts " means every line ran out of sprite budget; near 0 means none did.)"
} elseif {$mode eq "sweep"} {
    # Show one layer at a time on whatever is currently on screen, holding each
    # for `dwell` ms so a single continuous video capture can be cut up
    # afterwards. One JTAG session and ONE capture-device open: the Elgato drops
    # off the bus when it is opened and closed repeatedly, so the sweep must not
    # reopen it per step.
    #
    #   quartus_stp -t tools/jtag_peek.tcl sweep [dwell_ms] [freeze]
    set cidx  [index_of "CTRL"]
    set dwell [lindex $args 1]
    if {$dwell eq ""} { set dwell 6000 }
    set frz   [lindex $args 2]
    if {$frz eq ""} { set frz 1 }
    set fbit  [expr {$frz ? 32 : 0}]

    # bits 0..4 force a layer off, so "only X" means every other bit set.
    foreach step {{all 0} {back 30} {midl 29} {fore 27} {text 23} {sprites 15}} {
        lassign $step nm bits
        set v [expr {$bits | $fbit}]
        write_source_data -instance_index $cidx -value [dec2bin $v 8]
        puts "[clock milliseconds] $nm mask=$v"
        flush stdout
        after $dwell
    }
    write_source_data -instance_index $cidx -value [dec2bin $fbit 8]
    puts "[clock milliseconds] restored mask=$fbit"
} elseif {$mode eq "freeze"} {
    # Wait for a chosen moment in the attract loop, stop the CPU there, and only
    # then measure. cpu_freeze gates cpu_en alone -- the layer and sprite engines
    # keep rendering the frozen frame -- so every counter below describes ONE
    # scene instead of being smeared across whatever the attract cycle was doing.
    #
    #   quartus_stp -t tools/jtag_peek.tcl freeze <delay_ms> [samples] [ms]
    #
    # Sample interval defaults to 40 ms: the sprite counters run at roughly
    # 10^5/s, so a 500 ms interval overflows 16 bits more than once and the
    # deltas alias into nonsense (y-hit reading higher than scanned gives it
    # away). 40 ms keeps the worst-case delta near 4k, comfortably unambiguous.
    set idx   [index_of "VITL"]
    set cidx  [index_of "CTRL"]
    set delay [lindex $args 1]
    if {$delay eq ""} { set delay 26000 }
    set n     [lindex $args 2]
    if {$n eq ""} { set n 10 }
    set ms    [lindex $args 3]
    if {$ms eq ""} { set ms 40 }

    proc fld {p a w} { return [expr 0b[string range $p $a [expr {$a+$w-1}]]] }
    proc d16 {now was} { return [expr {($now - $was) & 0xFFFF}] }

    puts "waiting ${delay} ms, then freezing the CPU..."
    after $delay
    write_source_data -instance_index $cidx -value [dec2bin 32 8]
    after 100
    set p [read_probe_data -instance_index $idx]
    puts "frozen at CS=[bin2hex [string range $p 122 137]] EIP=[bin2hex [string range $p 138 169]]"
    puts "layer_enable (active low, 0=shown) = [string range $p 44 48]"
    puts ""
    puts [format "%7s %7s %8s %8s %8s %8s %9s %9s" \
          "frames" "ovrrun" "starved" "scanned" "y-hit" "emitted" "ovr/frm" "starv/frm"]
    set have 0
    for {set i 0} {$i < $n} {incr i} {
        set p [read_probe_data -instance_index $idx]
        set vbl [fld $p 174 16]; set stv [fld $p 0 16]; set ovr [fld $p 105 16]
        set scn [fld $p 81 16];  set yh  [fld $p 65 16]; set em [fld $p 49 16]
        if {$have} {
            set dv [d16 $vbl $pv]
            if {$dv > 0} {
                puts [format "%7d %7d %8d %8d %8d %8d %9.1f %9.1f" \
                      $dv [d16 $ovr $po] [d16 $stv $ps] [d16 $scn $pc] \
                      [d16 $yh $py] [d16 $em $pe] \
                      [expr {double([d16 $ovr $po])/$dv}] \
                      [expr {double([d16 $stv $ps])/$dv}]]
            }
        }
        set pv $vbl; set ps $stv; set po $ovr
        set pc $scn; set py $yh;  set pe $em
        set have 1
        after $ms
    }
    puts "\nCPU left frozen. Clear it with:  ... jtag_peek.tcl mask 0"
} elseif {$mode eq "prof"} {
    # EIP profiler, standalone: set the window, wait, and read the counters at
    # both ends of the wait. One invocation gives a rate, so this does not need
    # the server -- but it does hold the JTAG chain, so the server must be down.
    #
    #   quartus_stp -t tools/jtag_peek.tcl prof 0x20607C 0x2060B8 [seconds]
    #
    # Known windows (PLAN.md section 16):
    #   rdft   0x203F00 0x203F3A      rfjet  0x20607C 0x2060B8
    #
    # The counters free-run and are never cleared, so the two readings bracket
    # the interval. 40 bits wraps in ~10.7 h; the mask makes one wrap inside an
    # interval come out right regardless.
    set idx [index_of "PROF"]
    set lo  [expr {[lindex $args 1]}]
    set hi  [expr {[lindex $args 2]}]
    set secs [lindex $args 3]
    if {$secs eq ""} { set secs 10 }

    proc pfld {p a w} { return [expr 0b[string range $p $a [expr {$a+$w-1}]]] }

    write_source_data -instance_index $idx \
        -value "[dec2bin $hi 32][dec2bin $lo 32]"
    after 50
    set p0 [read_probe_data -instance_index $idx]
    set t0 [pfld $p0 0 40]
    set i0 [pfld $p0 40 40]
    puts [format "window %08X .. %08X, sampling %s s..." $lo $hi $secs]
    after [expr {int($secs * 1000)}]
    set p1 [read_probe_data -instance_index $idx]
    set t1 [pfld $p1 0 40]
    set i1 [pfld $p1 40 40]

    set mask 0xFFFFFFFFFF
    set dt [expr {($t1 - $t0) & $mask}]
    set di [expr {($i1 - $i0) & $mask}]
    if {$dt == 0} {
        puts "total counter did not move -- is the CPU in reset?"
    } else {
        puts [format "interval  %d clk_cpu cycles = %.3f s" $dt [expr {$dt / 28636364.0}]]
        puts [format "in window %d  = %.2f%%" $di [expr {100.0 * $di / $dt}]]
        puts [format "BUSY      %.2f%%  (of frames: %.0f cycles per frame at 53.99 Hz)" \
              [expr {100.0 * (1.0 - double($di)/$dt)}] \
              [expr {(1.0 - double($di)/$dt) * 28636364.0 / 53.99}]]
    }
} elseif {$mode eq "dump"} {
    set idx   [index_of "PEEK"]
    set addr  [expr {[lindex $args 1]}]
    set count [lindex $args 2]
    if {$count eq ""} { set count 8 }
    for {set i 0} {$i < $count} {incr i} {
        set a [expr {$addr + $i*8}]
        puts [format "%07X %s" $a [bin2hex [peek64 $idx $a]]]
    }
} else {
    puts "usage: quartus_stp -t tools/jtag_peek.tcl \[list | sums | vitals | sound | sdram |"
    puts "       rate | dump <addr> <count> | prof <lo> <hi> \[seconds\] | sdram]"
}

end_insystem_source_probe
