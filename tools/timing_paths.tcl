#============================================================================
#  SeibuSPI - name the worst timing paths after a build
#
#  quartus_sta's default report gives the Setup Summary, which names the clock
#  and the slack but NOT the endpoints, and the .sta.rpt it writes contains no
#  path listing at all. So a failing build tells you how badly and on which
#  clock, and nothing about where. This closes that gap.
#
#      make -C .. timing            # or:
#      quartus_sta -t tools/timing_paths.tcl [npaths]
#
#  Run it from the project root, after a fit. It prints slack, source and
#  destination for the worst paths; a run of identical endpoints is the usual
#  signature of one long combinational chain rather than many separate faults.
#============================================================================

set npaths 25
if {$argc >= 1} { set npaths [lindex $quartus(args) 0] }

project_open SeibuSPI
create_timing_netlist
read_sdc
update_timing_netlist
set_time_format -unit ns -decimal_places 3

puts "=== worst $npaths setup paths ==="
foreach_in_collection p [get_timing_paths -setup -npaths $npaths -detail summary] {
    set slack [get_path_info $p -slack]
    set from  [get_node_info [get_path_info $p -from] -name]
    set to    [get_node_info [get_path_info $p -to] -name]
    puts [format "%8.3f  %s" $slack $from]
    puts [format "       -> %s" $to]
}

puts ""
puts "=== worst 10 hold paths ==="
foreach_in_collection p [get_timing_paths -hold -npaths 10 -detail summary] {
    set slack [get_path_info $p -slack]
    set from  [get_node_info [get_path_info $p -from] -name]
    set to    [get_node_info [get_path_info $p -to] -name]
    puts [format "%8.3f  %s" $slack $from]
    puts [format "       -> %s" $to]
}

project_close
