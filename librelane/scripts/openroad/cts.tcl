# Copyright 2020-2022 Efabless Corporation
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
source $::env(SCRIPTS_DIR)/openroad/common/io.tcl
source $::env(SCRIPTS_DIR)/openroad/common/resizer.tcl

read_current_odb

# Repeat the clock
# root BEFORE clock_tree_synthesis. The stock flow leaves the source's net (here 3.1 mm from the pll to the tree roots) to
# the repair_clock_nets below, which runs after the latency balancer and chains repeaters to one root only: 5 ns of skew
# between the trees. A chain inserted here is a through path for TritonCTS: common to every tree, inside the balance.
if { [info exists ::env(CTS_ROOT_CHAIN_PIN)] } {
    set rc_i [string last "/" $::env(CTS_ROOT_CHAIN_PIN)]
    set rc_src [[$::block findInst [string range $::env(CTS_ROOT_CHAIN_PIN) 0 [expr {$rc_i - 1}]]] findITerm [string range $::env(CTS_ROOT_CHAIN_PIN) [expr {$rc_i + 1}] end]]
    set rc_net [$rc_src getNet]
    set rc_dbu [expr {double([$::block getDbUnitsPerMicron])}]
    set rc_bb [$rc_src getBBox]
    set rc_sx [expr {([$rc_bb xMin] + [$rc_bb xMax]) / 2.0}]; set rc_sy [expr {([$rc_bb yMin] + [$rc_bb yMax]) / 2.0}]
    set rc_xs {}; set rc_ys {}
    foreach rc_s [$rc_net getITerms] {
        if { ![$rc_s isInputSignal] } { continue }
        set rc_b [[$rc_s getInst] getBBox]
        lappend rc_xs [expr {([$rc_b xMin] + [$rc_b xMax]) / 2.0}]; lappend rc_ys [expr {([$rc_b yMin] + [$rc_b yMax]) / 2.0}]
    }
    set rc_tx [expr {([tcl::mathfunc::min {*}$rc_xs] + [tcl::mathfunc::max {*}$rc_xs]) / 2.0}]
    set rc_ty [expr {([tcl::mathfunc::min {*}$rc_ys] + [tcl::mathfunc::max {*}$rc_ys]) / 2.0}]
    set rc_len [expr {(abs($rc_tx - $rc_sx) + abs($rc_ty - $rc_sy)) / $rc_dbu}]
    set rc_n [expr {max(1, int(ceil($rc_len / $::env(CTS_ROOT_CHAIN_MAX_SEGMENT))) - 1)}]
    set rc_master [$::db findMaster $::env(CTS_ROOT_BUFFER)]
    $rc_src disconnect
    set rc_prev [odb::dbNet_create $::block clk_rootchain_n0]; $rc_prev setSigType CLOCK
    $rc_src connect $rc_prev
    for { set rc_k 1 } { $rc_k <= $rc_n } { incr rc_k } {
        set rc_inst [odb::dbInst_create $::block $rc_master clkbuf_rootchain_$rc_k]
        set rc_f [expr {double($rc_k) / ($rc_n + 1)}]
        $rc_inst setOrigin [expr {int($rc_sx + $rc_f * ($rc_tx - $rc_sx))}] [expr {int($rc_sy + $rc_f * ($rc_ty - $rc_sy))}]
        $rc_inst setPlacementStatus PLACED
        # the buffer's one signal input and one signal output (A and X on a sky130 clkbuf)
        set rc_a ""; set rc_x ""
        foreach rc_it [$rc_inst getITerms] {
            if { [$rc_it isInputSignal] } { set rc_a $rc_it } elseif { [$rc_it isOutputSignal] } { set rc_x $rc_it }
        }
        $rc_a connect $rc_prev
        if { $rc_k < $rc_n } { set rc_prev [odb::dbNet_create $::block clk_rootchain_n$rc_k]; $rc_prev setSigType CLOCK } else { set rc_prev $rc_net }
        $rc_x connect $rc_prev
    }
    puts [format "LIBRELANE_DEV: cts root chain: %d x %s from %s toward (%.0f, %.0f) um, %.0f um per segment; last buffer drives %s" \
        $rc_n $::env(CTS_ROOT_BUFFER) $::env(CTS_ROOT_CHAIN_PIN) [expr {$rc_tx / $rc_dbu}] [expr {$rc_ty / $rc_dbu}] [expr {$rc_len / ($rc_n + 1)}] [$rc_net getName]]
}

# set rc values
source $::env(SCRIPTS_DIR)/openroad/common/set_rc.tcl
estimate_parasitics -placement

# Clone clock tree inverters next to register loads
# so cts does not try to buffer the inverted clocks.
# Honour RSZ_DONT_TOUCH_RX / RSZ_DONT_TOUCH_LIST here (repair_clock_inverters skips dont-touch
# inverters). Unpatched, it cloned the pll ring's tap inverter once per clock sink onto a ring node.
puts "LIBRELANE_DEV: cts dont_touch around repair_clock_inverters"
set_dont_touch_objects
repair_clock_inverters
unset_dont_touch_objects

puts "\[INFO\] Configuring cts characterization…"
set cts_characterization_args [list]
if { [info exists ::env(CTS_MAX_CAP)] } {
    lappend cts_characterization_args -max_cap [expr {$::env(CTS_MAX_CAP) * 1e-12}]; # pF -> F
}
if { [info exists ::env(CTS_MAX_SLEW)] } {
    lappend cts_characterization_args -max_slew [expr {$::env(CTS_MAX_SLEW) * 1e-9}]; # ns -> S
}
log_cmd configure_cts_characterization {*}$cts_characterization_args

puts "\[INFO\] Performing clock tree synthesis…"
puts "\[INFO\] Looking for the following net(s): $::env(CLOCK_NET)"
puts "\[INFO\] Running Clock Tree Synthesis…"

proc get_buflist {} {
    set result [list]
    foreach selector $::env(CTS_CLK_BUFFERS) {
        # if we can find an exact match, avoid expensive search operation
        set exact_match [$::db findMaster $selector]
        if { "$exact_match" == "NULL" } {
            # time to dig for matches…
            foreach lib $::libs {
                foreach master [$lib getMasters] {
                    set name [$master getName]
                    if { [string match $selector $name] } {
                        lappend result $name
                    }
                }
            }
        } else {
            lappend result [$exact_match getName]
        }
    }
    return $result
}

set arg_list [list]
lappend arg_list -buf_list [get_buflist]
lappend arg_list -root_buf $::env(CTS_ROOT_BUFFER)

append_if_exists_argument arg_list CTS_SINK_CLUSTERING_SIZE -sink_clustering_size
append_if_exists_argument arg_list CTS_SINK_CLUSTERING_MAX_DIAMETER -sink_clustering_max_diameter
append_if_flag arg_list CTS_SINK_CLUSTERING_ENABLE -sink_clustering_enable
append_if_exists_argument arg_list CTS_MACRO_CLUSTERING_SIZE -macro_clustering_size
append_if_exists_argument arg_list CTS_MACRO_CLUSTERING_MAX_DIAMETER -macro_clustering_max_diameter
append_if_flag arg_list CTS_DISABLE_POST_PROCESSING -post_cts_disable
append_if_flag arg_list CTS_OBSTRUCTION_AWARE -obstruction_aware
append_if_flag arg_list CTS_BALANCE_LEVELS -balance_levels
append_if_exists_argument arg_list CTS_APPLY_NDR -apply_ndr

if { $::env(CTS_DISTANCE_BETWEEN_BUFFERS) != 0 } {
    lappend arg_list -distance_between_buffers $::env(CTS_DISTANCE_BETWEEN_BUFFERS)
}

if { [info exists ::env(CTS_SINK_BUFFER_MAX_CAP_DERATE_PCT)] } {
    lappend arg_list -sink_buffer_max_cap_derate [expr $::env(CTS_SINK_BUFFER_MAX_CAP_DERATE_PCT) / 100.0]
}

if { [info exists ::env(CTS_DELAY_BUFFER_DERATE_PCT)] } {
    lappend arg_list -delay_buffer_derate [expr $::env(CTS_DELAY_BUFFER_DERATE_PCT) / 100]
}

log_cmd clock_tree_synthesis {*}$arg_list

set_propagated_clock [all_clocks]

estimate_parasitics -placement
puts "\[INFO\] Repairing long wires on clock nets…"
# CTS leaves a long wire from the pad to the clock tree root.
# The repair restricted to the clock nets whose driver matches CTS_CLK_REPAIR_DRIVERS_RX. OpenROAD's
# repairClkNets skips a net only when odb marks it special (dont-touch is not tested on that path), so every other clock
# net carries the flag for the duration of the call.
if { [info exists ::env(CTS_CLK_REPAIR_DRIVERS_RX)] } {
    set rr_flagged {}; set rr_kept 0
    foreach rr_net [$::block getNets] {
        if { [$rr_net getSigType] ne "CLOCK" || [$rr_net isSpecial] } { continue }
        set rr_drv ""
        foreach rr_it [$rr_net getITerms] { if { [$rr_it isOutputSignal] } { set rr_drv [[$rr_it getInst] getName]; break } }
        if { $rr_drv ne "" && [regexp -- $::env(CTS_CLK_REPAIR_DRIVERS_RX) $rr_drv] } { incr rr_kept } else { $rr_net setSpecial; lappend rr_flagged $rr_net }
    }
    puts "LIBRELANE_DEV: cts clock repair restricted: [llength $rr_flagged] clock nets skipped, $rr_kept left to repair_clock_nets"
    repair_clock_nets -max_wire_length $::env(CTS_CLK_MAX_WIRE_LENGTH)
    foreach rr_net $rr_flagged { $rr_net clearSpecial }
} else {
    repair_clock_nets -max_wire_length $::env(CTS_CLK_MAX_WIRE_LENGTH)
}

estimate_parasitics -placement
write_views

puts "\[INFO\] Legalizing…"
source $::env(SCRIPTS_DIR)/openroad/common/dpl.tcl

estimate_parasitics -placement


write_views

puts "%OL_CREATE_REPORT cts.rpt"
report_cts
puts "%OL_END_REPORT"
