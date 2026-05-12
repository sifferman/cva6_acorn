
# Post-placement: force replication of FPnew's mid_pipe_dst_fmt_q net based
# on the physical distribution of its 160+ sinks. Logical opt_design only
# managed one replica (MAX_FANOUT was respected at the cell, not the net);
# phys_opt sees placement and can spread copies near each sink cluster.
catch {
    set nets [get_nets -hier -filter {NAME =~ *i_fpnew_cast_multi*mid_pipe_dst_fmt_q* && FLAT_PIN_COUNT > 50}]
    if {[llength $nets] > 0} {
        puts "Forcing replication on [llength $nets] FPnew net(s)"
        phys_opt_design -force_replication_on_nets $nets
    }
}
