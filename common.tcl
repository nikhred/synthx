proc read_rtl {filename} {
    # Get the file extension
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
    set lines {}

    while {[gets $fp line] != -1} {
        read_rtl $line
    }
    close $fp
}

proc load_files {files output_dir} {
    if {[file extension $files] eq ".f"} {
        read_f $files
    } elseif {$files != ""} {
        # this option is only to run vivado.tcl directly
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

    # Use a regular expression to extract parameters in the format KEY=VALUE
    set regex {([A-Za-z]+)=([0-9]+)}
    foreach {fullmatch key value} [regexp -all -inline -nocase $regex $input_string] {
        append result "_[string tolower $key][string tolower $value]"
    }

    # Remove the leading underscore if the result is not empty
    if {[string length $result] > 0} {
        set result [string range $result 1 end]
    }

    return $result
}

# utility: mark success/failure
proc mark_success {path} {
    set fh [open $path "w"]
    puts $fh "ok"
    close $fh
}
proc remove_if_exists {path} {
    if {[file exists $path]} { file delete -force $path }
}

proc ensure_top {top} {
    if {$top eq ""} {
        error "Top module/entity name is required (-top)."
    }
}

proc maybe_create_clock {clk_ns} {
    # Only add a default clock if a 'clk' port exists; skip otherwise.
    set p [get_ports -quiet clk]
    if {[llength $p] > 0} {
        catch { delete_clocks [get_clocks -quiet clk] }
        create_clock -name clk -period $clk_ns $p
    } else {
        puts "INFO: no top-level port named 'clk' found; skipping create_clock."
    }
}
