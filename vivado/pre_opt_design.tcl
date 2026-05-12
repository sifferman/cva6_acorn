
# FPnew pipeline regs broadcast into the EX/issue flush logic and dominate
# WNS at 50 MHz. FPnew puts (* keep *) on its pipeline regs to preserve
# pipeline depth — clear those so opt_design / phys_opt are free to clone
# and pack, then set MAX_FANOUT to push opt_design into replicating.
catch {
    set fpu_cells [get_cells -hier -filter {NAME =~ *i_fpnew_cast_multi*mid_pipe*}]
    foreach cell $fpu_cells {
        catch {set_property KEEP        false $cell}
        catch {set_property DONT_TOUCH  false $cell}
    }
    set fpu_nets [get_nets -hier -filter {NAME =~ *i_fpnew_cast_multi*mid_pipe*}]
    foreach net $fpu_nets {
        catch {set_property KEEP        false $net}
        catch {set_property DONT_TOUCH  false $net}
    }
    set fanout_cells [get_cells -hier -filter {NAME =~ *i_fpnew_cast_multi*mid_pipe_dst_fmt_q_reg*}]
    foreach cell $fanout_cells {
        puts "Setting MAX_FANOUT=8 on $cell"
        set_property MAX_FANOUT 8 $cell
    }
}
