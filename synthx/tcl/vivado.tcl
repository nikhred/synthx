# vivado -mode batch -source vivado.tcl -tclargs "FPGA=115-2"
package require cmdline
package require try

source [file join [file dirname [info script]] common.tcl]

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

# If -out is an absolute path, use it directly. Otherwise place under ./build/
if {[file pathtype $outname] eq "absolute"} {
    set output_dir [file normalize $outname]
} else {
    set output_dir  [file normalize "build/$outname"]
}
file mkdir $output_dir
set done_file "$output_dir/done"

set prj_cmd "create_project -quiet -part $part $top $output_dir"
set generate_cmd "generate_target -verbose all \[get_ips\]"

set synth_cmd "synth_design -top $top"
if {$params(synth) ne ""} {
    append synth_cmd " " $params(synth)
}

set opt_cmd "opt_design"
set place_cmd "place_design"
set route_cmd "route_design"

remove_if_exists $done_file

try {
    set in_memory 1
    if {$runmode eq "prj"} { set in_memory 0 }
    if {$in_memory} { append prj_cmd " -in_memory" }

    puts "INFO: creating project: $prj_cmd"
    eval $prj_cmd

    load_files $files $output_dir

    switch -- $runmode {
        "prj" {
            if {$top ne ""} { set_property top $top [current_fileset] }
            catch { eval "generate_target -verbose all \[get_ips\]" }
            puts "INFO: project setup complete."
        }
        "sim" {
            ensure_top $top
            if {[llength [get_filesets -quiet sim_1]]} {
                set_property top $top [get_filesets sim_1]
            } else {
                create_fileset -simset sim_1
                set_property top $top [get_filesets sim_1]
            }
            puts "INFO: launching simulation (batch, run -all)"
            launch_simulation
            run -all
            catch { close_sim }
            puts "INFO: simulation completed."
        }
        "synth" {
            ensure_top $top
            append synth_cmd " -mode out_of_context"
            puts "INFO: running: $synth_cmd"
            eval $synth_cmd
            maybe_create_clock $clk
            # Mode-specific reports
            report_utilization -hierarchical -file "$output_dir/utilization_synth.txt"
            report_timing_summary -file "$output_dir/timing_synth.txt" -warn_on_violation
            write_checkpoint -force "$output_dir/post_synth.dcp"
        }
        "impl" {
            ensure_top $top
            append synth_cmd " -mode out_of_context"
            puts "INFO: running: $synth_cmd"
            eval $synth_cmd
            maybe_create_clock $clk
            eval $opt_cmd
            eval $place_cmd
            eval $route_cmd
            # Mode-specific reports
            report_utilization -hierarchical -file "$output_dir/utilization_impl.txt"
            report_timing_summary -file "$output_dir/timing_impl.txt" -warn_on_violation
            write_checkpoint -force "$output_dir/post_route_impl.dcp"
        }
        "bts" {
            ensure_top $top
            puts "INFO: running: $synth_cmd"
            eval $synth_cmd
            maybe_create_clock $clk
            eval $opt_cmd
            eval $place_cmd
            eval $route_cmd
            # Mode-specific reports
            report_utilization -hierarchical -file "$output_dir/utilization_bts.txt"
            report_timing_summary -file "$output_dir/timing_bts.txt" -warn_on_violation
            write_checkpoint -force "$output_dir/post_route_bts.dcp"
            write_bitstream -force "$output_dir/$top.bit"
        }
        default {
            error "Unknown -run mode: $runmode (expected prj|synth|impl|bts|sim)"
        }
    }

    mark_success $done_file
    exit 0

} on error {e opts} {
    puts "ERROR: $e"
    puts [dict get $opts -errorinfo]
    remove_if_exists $done_file
    exit 2
}
