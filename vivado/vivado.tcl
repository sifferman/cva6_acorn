
# Vivado project bootstrap for cva6_xdma.
#
# Args (from Makefile):
set bd_name    [lindex $argv 0]
set variant    [lindex $argv 1]
set part_name  [lindex $argv 2]
set dram_size  [lindex $argv 3]
set bd_tcl     [lindex $argv 4]
set cva6_dir   [lindex $argv 5]
set mig_prj    [lindex $argv 6]
set target_cfg [lindex $argv 7]
set xdc_file   [lindex $argv 8]

create_project acorn_$variant $bd_name/ -part $part_name

# CVA6 sources
set ::env(CVA6_REPO_DIR) $cva6_dir
set ::env(TARGET_CFG)    $target_cfg
set ::env(HPDCACHE_DIR)  "$cva6_dir/core/cache_subsystem/hpdcache"
set cva6_sources [split [string trim [exec python3 \
    "$cva6_dir/util/flist_flattener.py" \
    "$cva6_dir/core/Flist.cva6"]]]
set cva6_sources [lsearch -all -inline -not -exact $cva6_sources ""]

# Extra files
lappend cva6_sources \
    "$cva6_dir/vendor/pulp-platform/axi/src/axi_intf.sv" \
    "$cva6_dir/corev_apu/tb/ariane_axi_pkg.sv" \
    "$cva6_dir/common/local/util/tc_sram_fpga_wrapper.sv" \
    "$cva6_dir/common/local/util/hpdcache_sram_1rw.sv" \
    "$cva6_dir/common/local/util/hpdcache_sram_wbyteenable_1rw.sv" \
    "$cva6_dir/vendor/pulp-platform/fpga-support/rtl/SyncSpRamBeNx64.sv" \
    "$cva6_dir/vendor/pulp-platform/fpga-support/rtl/SyncSpRamBeNx32.sv" \
    "$cva6_dir/vendor/pulp-platform/fpga-support/rtl/SyncSpRam.sv"

# Drop testbench-only / non-synthesisable .sv files that Flist still pulls in.
# Mirrors the $(fpga_filter) list in third_party/cva6/Makefile.
set fpga_filter [list \
    "$cva6_dir/corev_apu/bootrom/bootrom.sv" \
    "$cva6_dir/core/include/instr_tracer_pkg.sv" \
    "$cva6_dir/common/local/util/instr_tracer.sv" \
    "$cva6_dir/vendor/pulp-platform/tech_cells_generic/src/rtl/tc_sram.sv" \
    "$cva6_dir/common/local/util/tc_sram_wrapper.sv" \
    "$cva6_dir/corev_apu/tb/ariane_peripherals.sv" \
    "$cva6_dir/corev_apu/tb/ariane_testharness.sv" \
    "$cva6_dir/core/cache_subsystem/hpdcache/rtl/src/common/macros/behav/hpdcache_sram_1rw.sv" \
    "$cva6_dir/core/cache_subsystem/hpdcache/rtl/src/common/macros/behav/hpdcache_sram_wbyteenable_1rw.sv" \
    "$cva6_dir/core/cache_subsystem/hpdcache/rtl/src/common/macros/behav/hpdcache_sram_wmask_1rw.sv" \
]
foreach f $fpga_filter {
    set cva6_sources [lsearch -all -inline -not -exact $cva6_sources $f]
}

read_verilog -sv $cva6_sources

# CVA6 include dirs (copied from CVA6's run.tcl).
set_property include_dirs [list \
    "[pwd]/../vivado/shims" \
    "$cva6_dir/core/include" \
    "$cva6_dir/vendor/pulp-platform/common_cells/include" \
    "$cva6_dir/vendor/pulp-platform/axi/include" \
    "$cva6_dir/core/cache_subsystem/hpdcache/rtl/include" \
    "$cva6_dir/corev_apu/register_interface/include" \
    "$cva6_dir/corev_apu/instr_tracing/ITI/include" \
] [current_fileset]

# Vivado requires .svh include files to be added to the project and marked as
# global headers (just listing them in include_dirs isn't enough for module-
# reference RTL like our wrapper). Discover them dynamically so we don't have
# to maintain a hand list — exclude testbench-only headers and the per-board
# config .svh files (only one board's config can be active at a time).
set cva6_headers [split [exec find $cva6_dir \
    -name "*.svh" \
    -not -path "*/corev_apu/tb/*" \
    -not -path "*/verif/*" \
    -not -path "*/core/cvfpu/src/common_cells/*" \
    -not -name "agilex7.svh" \
    -not -name "genesysii.svh" \
    -not -name "kc705.svh" \
    -not -name "nexys_video.svh" \
    -not -name "vc707.svh" \
    -not -name "vcu118.svh" \
    -not -name "ex_trace_item.svh" \
    -not -name "instr_trace_item.svh" \
    -not -name "assertions.svh" \
    -not -name "registers.svh"] "\n"]
# Use our shim's registers.svh (no macro parameter defaults)
lappend cva6_headers "[pwd]/../vivado/shims/common_cells/registers.svh"
read_verilog -sv $cva6_headers
set_property -dict {file_type {Verilog Header} is_global_include 1} \
    -objects [get_files -of_objects [get_filesets sources_1] $cva6_headers]

# Project-local RTL (wrapper, bootrom, console buffer) -------------------------
add_files -norecurse [list \
    "../rtl/cva6_acorn_wrapper.v" \
    "../rtl/cva6_acorn_core.sv" \
    "../rtl/axi_bram_init.v" \
    "../rtl/axi_console_buffer.v" \
    "../rtl/axi_ctrl_regs.v" \
]

# Constraints ------------------------------------------------------------------
add_files -fileset constrs_1 -norecurse $xdc_file
set_property PROCESSING_ORDER EARLY [get_files -of_objects [get_filesets constrs_1]]

# Block design -----------------------------------------------------------------
create_bd_design "design_1"
source $bd_tcl
save_bd_design

make_wrapper -files [get_files design_1.bd] -top -import
set_property top design_1_wrapper [current_fileset]

# Synthesis / implementation ---------------------------------------------------
set_property STEPS.SYNTH_DESIGN.ARGS.FLATTEN_HIERARCHY none [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE PerformanceOptimized [get_runs synth_1]
launch_runs synth_1 -jobs [exec nproc]
wait_on_run synth_1

# Implementation tuning ------------------------------------------------------
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE               ExtraTimingOpt    [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED                true              [get_runs impl_1]
set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE            AggressiveExplore [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE               AggressiveExplore [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED     true              [get_runs impl_1]
set_property STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]

launch_runs impl_1 -to_step write_bitstream -jobs [exec nproc]
wait_on_run impl_1
