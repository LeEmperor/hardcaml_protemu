IVERILOG ?= iverilog
VVP ?= vvp
BUILD_DIR ?= ../build/rtl-test
SOURCES = ../src/p0_observable.v ../src/project.v tb.v
NETLIST ?= gate_level_netlist.v

.PHONY: rtl gate clean

rtl:
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -s tb -o $(BUILD_DIR)/p0_wrapper $(SOURCES)
	$(VVP) $(BUILD_DIR)/p0_wrapper

gate:
	test -n "$(PDK_ROOT)"
	test -f "$(NETLIST)"
	mkdir -p $(BUILD_DIR)
	$(IVERILOG) -g2012 -Wall -Wno-timescale -DGL_TEST -DFUNCTIONAL -DSIM \
		-s tb -o $(BUILD_DIR)/p0_wrapper_gate \
		$(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_io/verilog/sg13cmos5l_io.v \
		$(PDK_ROOT)/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/verilog/sg13cmos5l_stdcell.v \
		$(NETLIST) tb.v
	$(VVP) $(BUILD_DIR)/p0_wrapper_gate

clean:
	rm -f $(BUILD_DIR)/p0_wrapper $(BUILD_DIR)/p0_wrapper_gate
