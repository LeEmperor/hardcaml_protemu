# Hardcaml protocol emulator — phase P0

This phase-P0 design proves the path from Hardcaml through generated Verilog and
the Tiny Tapeout wrapper. It accepts a timed command for protocol pin 0 and
atomically commits its registered value and output enable after 1–15 clock cycles.

Set `ui_in[3:0]` to a nonzero delay, `ui_in[4]` to the requested pin value,
`ui_in[5]` to the requested output enable, and pulse `ui_in[6]` while `uo_out[4]`
is high. The low nibble of `uo_out` exposes the remaining timer; bits 5, 6, and 7
report busy, completion, and a rejected zero-delay command.

The eight `uio` signals are reserved for the eventual programmable protocol pin
bank. P0 directly controls only pin 0. Reset or `ena=0` releases every `uio` pin;
reset asserts asynchronously at the wrapper and releases into the Hardcaml block
after two clock edges.
