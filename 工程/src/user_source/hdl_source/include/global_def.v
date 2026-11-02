


`define   DATA_WIDTH                        32
`define   ADDR_WIDTH                        21
`define   DM_WIDTH                          4

`define   ROW_WIDTH                        11
`define   BA_WIDTH                        2

// Parenthesize arithmetic macros: Verilog substitutes text, not evaluated values.
`define   SDR_CLK_PERIOD                    (1000000000 / 125000000)
// Refresh conservatively every 15.624 us at 125 MHz (1953 cycles).
// Keep the 11-bit row address geometry unchanged; refresh rate is independent.
// init_cnt counts from zero through the terminal value (1952 inclusive).
`define   SELF_REFRESH_INTERVAL             (((64000000 / (`SDR_CLK_PERIOD)) / 4096) - 1)

