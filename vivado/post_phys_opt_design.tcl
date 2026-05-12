
# Second pass of forced replication, after the main phys_opt has run. Some
# replicas of replicas only become eligible once the previous round's clones
# are placed — this picks up that extra round.
catch {
    set nets [get_nets -hier -filter {NAME =~ *i_fpnew_cast_multi*mid_pipe_dst_fmt* && FLAT_PIN_COUNT > 30}]
    if {[llength $nets] > 0} {
        puts "Second-pass replication on [llength $nets] FPnew net(s)"
        phys_opt_design -force_replication_on_nets $nets
    }
}
