proc read_rtl {filename} {
    set file_extension [file extension $filename]
    puts "reading $filename"
    if {$file_extension eq ".sv"} {
        read_verilog -sv $filename
    } elseif {$file_extension eq ".v"} {
        read_verilog $filename
    } elseif {$file_extension eq ".xdc"} {
        read_xdc $filename
    } elseif {$file_extension eq ".xci"} {
        read_ip $filename
        set ip_name [file rootname [file tail $filename]]
        generate_target all [get_ips $ip_name]
    } elseif {$file_extension eq ".bd"} {
        read_bd $filename
    } else {
        puts "Unsupported file extension for file: $filename"
    }
}

proc read_f {filename} {
    set fp [open $filename r]
    while {[gets $fp line] != -1} {
        set line [string trim $line]
        if {$line eq ""} { continue }
        if {[string match "#*" $line]} { continue }
        if {[string match "//*" $line]} { continue }
        read_rtl $line
    }
    close $fp
}

proc load_files {files output_dir} {
    if {[file extension $files] eq ".f"} {
        read_f $files
    } elseif {$files != ""} {
        read_rtl $files
    } elseif {[file exists $output_dir/synth.f]} {
        read_f $output_dir/synth.f
    } else {
        puts "ERROR: no files loaded"
        puts $output_dir/synth.f
    }
    update_compile_order -fileset sources_1
}

proc get_generics {input_string} {
    set result ""
    set regex {([A-Za-z]+)=([0-9]+)}
    foreach {fullmatch key value} [regexp -all -inline -nocase $regex $input_string] {
        append result "_[string tolower $key][string tolower $value]"
    }
    if {[string length $result] > 0} {
        set result [string range $result 1 end]
    }
    return $result
}

proc mark_success {path} {
    set fh [open $path "w"]
    puts $fh "ok"
    close $fh
}
proc remove_if_exists {path} {
    if {[file exists $path]} { file delete -force $path }
}

proc ensure_top {top} {
    if {$top eq ""} { error "Top module/entity name is required (-top)." }
}

proc maybe_create_clock {clk_ns} {
    set p [get_ports -quiet clk]
    if {[llength $p] == 0} {
        set p [get_ports -quiet -regexp {^clk}]
    }
    if {[llength $p] > 0} {
        catch { delete_clocks [get_clocks -quiet clk] }
        create_clock -name clk -period $clk_ns [lindex $p 0]
    } else {
        puts "INFO: no top-level port named 'clk*' found; skipping create_clock."
    }
}

# Write timing metrics JSON: WNS (ns), period (ns), and Fmax (MHz)
proc write_timing_metrics {output_dir clk_ns} {
    set wns ""
    # Try to get worst setup path slack for any clock (prefer 'clk' if present)
    set clk_obj [get_clocks -quiet clk]
    if {[llength $clk_obj] > 0} {
        set paths [get_timing_paths -quiet -setup -to $clk_obj -nworst 1]
    } else {
        set paths [get_timing_paths -quiet -setup -nworst 1]
    }
    if {[llength $paths] > 0} {
        set wns [get_property SLACK [lindex $paths 0]]
    } else {
        set wns ""
    }
    # Compute Fmax from period and WNS when available
    set period_ns $clk_ns
    set fmax_mhz ""
    if {$wns ne ""} {
        # New period is period - wns
        set new_period [expr {$period_ns - double($wns)}]
        if {$new_period > 0} {
            set fmax_mhz [expr {1000.0 / $new_period}]
        }
    }
    # Write JSON
    set fh [open "$output_dir/timing_metrics.json" "w"]
    puts $fh "{"
    puts $fh "  \"wns_ns\": [format %.6f $wns],"
    puts $fh "  \"period_ns\": [format %.6f $period_ns],"
    if {$fmax_mhz ne ""} {
        puts $fh "  \"fmax_mhz\": [format %.3f $fmax_mhz]"
    } else {
        puts $fh "  \"fmax_mhz\": null"
    }
    puts $fh "}"
    close $fh
}
