# vivado -mode batch -source vivado.tcl -tclargs "FPGA=115-2"
package require cmdline
package require try

source common.tcl

# Define command line options
set options {
    {f.arg "" "filename - .f file or .sv file"}
    {clk.arg 4.0 "target clock frequency"}
    {part.arg "xczu7ev-ffvc1156-2-e" "part number. Default = xczu7ev-ffvc1156-2-e (one of the free ZU+ boards)"}
    {top.arg "" "name of the top module to be synthesised"}
    {out.arg "" "name of the output dir"}
    {synth.arg "" "generic parameters - passed directly to synth design"}
    {run.arg "impl" "Run Vivado with options. synth and impl for out-of-context mode synthesis and implementation. bts for bitstream generation"}
}

set usage ": vivado.tcl \[options] filename ...\noptions:"
try {
    array set params [::cmdline::getoptions argv $options $usage]
} trap {CMDLINE USAGE} {msg o} {
    # Trap the usage signal, print the message, and exit the application.
    # Note: Other errors are not caught and passed through to higher levels!
    puts $msg
    exit 1
}

set part $params(part)
set files $params(f)
set top $params(top)
set clk $params(clk)
set runmode $params(run)
set outname $params(out)

if {$outname eq ""} {
    set outname $top
}

set output_dir  [file normalize "build/$outname"]
file mkdir $output_dir
set done_file "$output_dir/done"

# create_project [‑part <arg>] [‑force] [‑in_memory] [‑ip] [‑rtl_kernel][‑quiet] [‑verbose] [<name>] [<dir>]
set prj_cmd "create_project -quiet -part $part $top $output_dir"

# generate_target [‑force] [‑quiet] [‑verbose] <name> <objects
set generate_cmd "generate_target -verbose all \[get_ips\]"

# synth_design [‑name <arg>] [‑part <arg>] [‑constrset <arg>] [‑top <arg>]
#  [‑include_dirs <args>] [‑generic <args>] [‑define <args>]
#  [‑verilog_define <args>] [‑vhdl_define <args>]
#  [‑flatten_hierarchy <arg>] [‑gated_clock_conversion <arg>]
#  [‑directive <arg>] [‑rtl] [‑lint] [‑file <arg>] [‑bufg <arg>] [‑no_lc]
#  [‑shreg_min_size <arg>] [‑mode <arg>] [‑fsm_extraction <arg>]
#  [‑rtl_skip_mlo] [‑rtl_skip_ip] [‑rtl_skip_constraints]
#  [‑srl_style <arg>] [‑keep_equivalent_registers]
#  [‑resource_sharing <arg>] [‑cascade_dsp <arg>]
#  [‑control_set_opt_threshold <arg>] [‑incremental_mode <arg>]
#  [‑max_bram <arg>] [‑max_uram <arg>] [‑max_dsp <arg>]
#  [‑max_bram_cascade_height <arg>] [‑max_uram_cascade_height <arg>]
#  [‑global_retiming <arg>] [‑no_srlextract] [‑assert] [‑no_timing_driven]
#  [‑sfcu] [‑debug_log] [‑rtl_block_model] [‑quiet] [‑verbose]
set synth_cmd "synth_design -top $top"
if {$params(synth) ne ""} {
    append synth_cmd " " $params(synth)
}

# opt_design [‑retarget] [‑propconst] [‑sweep] [‑bram_power_opt] [‑remap]
#  [‑aggressive_remap] [‑resynth_remap] [‑resynth_area]
#  [‑resynth_seq_area] [‑directive <arg>] [‑muxf_remap]
#  [‑hier_fanout_limit <arg>] [‑bufg_opt] [‑mbufg_opt]
#  [‑shift_register_opt] [‑dsp_register_opt] [‑srl_remap_modes <arg>]
#  [‑control_set_merge] [‑control_set_opt] [‑merge_equivalent_drivers]
#  [‑carry_remap] [‑debug_log] [‑property_opt_only] [‑quiet] [‑verbose]
set opt_cmd "opt_design"

# place_design [‑directive <arg>] [‑no_timing_driven] [‑timing_summary]
#  [‑unplace] [‑post_place_opt] [‑no_psip] [‑sll_align_opt] [‑no_bufg_opt]
#  [‑ultrathreads] [‑quiet] [‑verbose]
set place_cmd "place_design"

# route_design [‑unroute] [‑release_memory] [‑nets <args>] [‑physical_nets]
#  [‑pins <arg>] [‑directive <arg>] [‑tns_cleanup] [‑no_timing_driven]
#  [‑preserve] [‑delay] [‑auto_delay] ‑max_delay <arg> ‑min_delay <arg>
#  [‑timing_summary] [‑finalize] [‑ultrathreads] [‑eco] [‑no_psir]
#  [‑quiet] [‑verbose]
set route_cmd "route_design"

remove_if_exists $done_file

try {
    set in_memory 1
    if {$runmode eq "prj"} { set in_memory 0 }
    if {$in_memory} {
        append prj_cmd " -in_memory"
    }

    puts "INFO: creating project: $prj_cmd"
    eval $prj_cmd

    # Load sources
    load_files $files $output_dir

    switch -- $runmode {
        "prj" {
            # Just set properties and exit; no build
            if {$top ne ""} {
                set_property top $top [current_fileset]
            }
            # Try to resolve IPs (if any were read from .f)
            catch { eval "generate_target -verbose all \[get_ips\]" }
            puts "INFO: project setup complete."
        }

        "sim" {
            ensure_top $top
            # If a sim fileset exists, set top there as well
            if {[llength [get_filesets -quiet sim_1]]} {
                set_property top $top [get_filesets sim_1]
            } else {
                create_fileset -simset sim_1
                set_property top $top [get_filesets sim_1]
            }

            puts "INFO: launching simulation (batch, run -all)"
            # Vivado sim defaults to xsim; assume tb is in the sources/.f
            launch_simulation
            run -all
            # close_simulation may fail if already closed; ignore
            catch { close_sim }
            puts "INFO: simulation completed."
        }

        "synth" {
            ensure_top $top
            # Out-of-context synth
            append synth_cmd " -mode out_of_context"
            puts "INFO: running: $synth_cmd"
            eval $synth_cmd
            maybe_create_clock $clk
            # Reports
            report_utilization -hierarchical -file "$output_dir/utilization_synth.txt"
            report_timing_summary -file "$output_dir/timing_synth.txt" -warn_on_violation
            write_checkpoint -force "$output_dir/post_synth.dcp"
        }

        "impl" {
            ensure_top $top
            # OOC synth + opt/place/route
            append synth_cmd " -mode out_of_context"
            puts "INFO: running: $synth_cmd"
            eval $synth_cmd
            maybe_create_clock $clk
            eval $opt_cmd
            eval $place_cmd
            eval $route_cmd
            # Reports
            report_utilization -hierarchical -file "$output_dir/utilization_impl.txt"
            report_timing_summary -file "$output_dir/timing_impl.txt" -warn_on_violation
            write_checkpoint -force "$output_dir/post_route_impl.dcp"
        }

        "bts" {
            ensure_top $top
            # Full non-OOC flow to bitstream
            puts "INFO: running: $synth_cmd"
            eval $synth_cmd
            maybe_create_clock $clk
            eval $opt_cmd
            eval $place_cmd
            eval $route_cmd
            # Reports + bitstream
            report_utilization -hierarchical -file "$output_dir/utilization_bts.txt"
            report_timing_summary -file "$output_dir/timing_bts.txt" -warn_on_violation
            write_checkpoint -force "$output_dir/post_route_bts.dcp"
            write_bitstream -force "$output_dir/$top.bit"
        }

        default {
            error "Unknown -run mode: $runmode (expected prj|synth|impl|bts|sim)"
        }
    }

    # Success marker
    mark_success $done_file
    exit 0

} on error {e opts} {
    puts "ERROR: $e"
    puts [dict get $opts -errorinfo]
    # Ensure 'done' is not present on failure
    remove_if_exists $done_file
    exit 2
}
