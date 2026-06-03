set script_dir [file dirname [file normalize [info script]]]
set root_dir   [file normalize [file join $script_dir ".."]]
set out_dir    [file normalize [file join $root_dir "result" "vivado" "aes_gcm_core_zynq7100"]]
set part_name  "xc7z100ffg900-2"

file mkdir $out_dir

# Read source files from filelist
set fl [open [file join $root_dir "scripts" "filelist.txt"] r]
while {[gets $fl line] >= 0} {
    set line [string trim $line]
    if {$line ne ""} {
        read_verilog [file join $root_dir [string map {\\ /} $line]]
    }
}
close $fl

synth_design -top aes_gcm_core -part $part_name -flatten_hierarchy rebuilt -mode out_of_context

create_clock -period 4.000 -name i_clk [get_ports i_clk]

report_utilization -file [file join $out_dir "utilization.rpt"]
report_timing_summary -delay_type max -max_paths 20 -file [file join $out_dir "timing_summary.rpt"]
write_checkpoint -force [file join $out_dir "post_synth.dcp"]
puts "SYNTH_DONE: aes_gcm_core $part_name @250MHz"
