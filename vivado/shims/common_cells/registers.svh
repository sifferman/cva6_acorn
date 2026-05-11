// Vivado-friendly shim of pulp-platform/common_cells registers.svh.
//
// The upstream file uses macro parameter defaults (e.g. `__clk = `REG_DFLT_CLK`)
// which Vivado's synthesis preprocessor rejects with
//   [Synth 8-10840] illegal macro parameter near '= `REG_DFLT_CLK, ...
//
// All call sites in cva6 use the 3-arg form of `FF and the 4-arg form of `FFL
// (verified by grep at the time of writing), so this shim hardcodes the
// default clk/rst into the macro body and drops the optional parameters.
// Every other macro is copied verbatim from upstream.
//
// vivado/shims is listed first in include_dirs so `include "common_cells/
// registers.svh"` resolves here instead of the vendor copy.

`ifndef COMMON_CELLS_REGISTERS_SVH_
`define COMMON_CELLS_REGISTERS_SVH_

`ifdef VERILATOR
`define NO_SYNOPSYS_FF 1
`endif

`define REG_DFLT_CLK clk_i
`define REG_DFLT_RST rst_ni

// Flip-Flop with asynchronous active-low reset (3-arg form: clk_i / rst_ni
// implicit). For the rare 5-arg case, use the renamed `FF_EXPLICIT below.
`define FF(__q, __d, __reset_value)                                            \
  always_ff @(posedge `REG_DFLT_CLK or negedge `REG_DFLT_RST) begin            \
    if (!`REG_DFLT_RST) begin                                                  \
      __q <= (__reset_value);                                                  \
    end else begin                                                             \
      __q <= (__d);                                                            \
    end                                                                        \
  end

`define FFAR(__q, __d, __reset_value, __clk, __arst)     \
  always_ff @(posedge (__clk) or posedge (__arst)) begin \
    if (__arst) begin                                    \
      __q <= (__reset_value);                            \
    end else begin                                       \
      __q <= (__d);                                      \
    end                                                  \
  end

`define FFARN(__q, __d, __reset_value, __clk, __arst_n)                        \
  always_ff @(posedge (__clk) or negedge (__arst_n)) begin                     \
    if (!__arst_n) begin                                                       \
      __q <= (__reset_value);                                                  \
    end else begin                                                             \
      __q <= (__d);                                                            \
    end                                                                        \
  end

`define FFSR(__q, __d, __reset_value, __clk, __reset_clk) \
  always_ff @(posedge (__clk)) begin                      \
    __q <= (__reset_clk) ? (__reset_value) : (__d);       \
  end

`define FFSRN(__q, __d, __reset_value, __clk, __reset_n_clk) \
  always_ff @(posedge (__clk)) begin                         \
    __q <= (!__reset_n_clk) ? (__reset_value) : (__d);       \
  end

`define FFNR(__q, __d, __clk)        \
  always_ff @(posedge (__clk)) begin \
    __q <= (__d);                    \
  end

// Load-enable FF with async active-low reset (4-arg form: clk_i / rst_ni
// implicit).
`define FFL(__q, __d, __load, __reset_value)                                   \
  always_ff @(posedge `REG_DFLT_CLK or negedge `REG_DFLT_RST) begin            \
    if (!`REG_DFLT_RST) begin                                                  \
      __q <= (__reset_value);                                                  \
    end else begin                                                             \
      __q <= (__load) ? (__d) : (__q);                                         \
    end                                                                        \
  end

`define FFLAR(__q, __d, __load, __reset_value, __clk, __arst)                  \
  always_ff @(posedge (__clk) or posedge (__arst)) begin                       \
    if (__arst) begin                                                          \
      __q <= (__reset_value);                                                  \
    end else begin                                                             \
      __q <= (__load) ? (__d) : (__q);                                         \
    end                                                                        \
  end

`define FFLARN(__q, __d, __load, __reset_value, __clk, __arst_n)               \
  always_ff @(posedge (__clk) or negedge (__arst_n)) begin                     \
    if (!__arst_n) begin                                                       \
      __q <= (__reset_value);                                                  \
    end else begin                                                             \
      __q <= (__load) ? (__d) : (__q);                                         \
    end                                                                        \
  end

`define FFLSR(__q, __d, __load, __reset_value, __clk, __reset_clk)             \
  always_ff @(posedge (__clk)) begin                                           \
    __q <= (__reset_clk) ? (__reset_value) : ((__load) ? (__d) : (__q));       \
  end

`define FFLSRN(__q, __d, __load, __reset_value, __clk, __reset_n_clk)          \
  always_ff @(posedge (__clk)) begin                                           \
    __q <= (!__reset_n_clk) ? (__reset_value) : ((__load) ? (__d) : (__q));    \
  end

`define FFLARNC(__q, __d, __load, __clear, __reset_value, __clk, __arst_n)     \
  always_ff @(posedge (__clk) or negedge (__arst_n)) begin                     \
    if (!__arst_n) begin                                                       \
      __q <= (__reset_value);                                                  \
    end else begin                                                             \
      __q <= (__clear) ? (__reset_value) : (__load) ? (__d) : (__q);           \
    end                                                                        \
  end

`define FFLNR(__q, __d, __load, __clk) \
  always_ff @(posedge (__clk)) begin   \
    __q <= (__load) ? (__d) : (__q);   \
  end

`endif
