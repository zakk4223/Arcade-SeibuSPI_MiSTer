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
    # 96 bits, MSB first: 0..15 z80 pc, 16..31 fifo reads, 32..47 ymf writes,
    # 48..63 rom stalls, 64..79 synth overruns, 80..95 slots sounding
    proc fld {p a n} { return [expr 0b[string range $p $a [expr {$a+$n-1}]]] }
    puts "Z80 PC     = [bin2hex [string range $p 0 15]]  (unchanging = sound CPU not running)"
    puts "fifo reads = [fld $p 16 16]  (commands the Z80 took from the 386)"
    puts "ymf writes = [fld $p 32 16]"
    puts "rom stalls = [fld $p 48 16]  (line-buffer misses that hit SDRAM)"
    puts "voices     = [fld $p 80 16]  (PCM + FM slots sounding on the last sample)"
    puts "synth ovrun= [fld $p 64 16]  (samples the engine could not finish in time)"
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
    puts "usage: quartus_stp -t tools/jtag_peek.tcl \[list | sums | dump <addr> <count>\]"
}

end_insystem_source_probe
