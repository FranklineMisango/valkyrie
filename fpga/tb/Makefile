# Valkyrie FPGA RTL testbench (Icarus Verilog)
#   make          - directed conformance suite on the PCIe DMA core
#   make replay   - replay real PCAP market data into the RTL (AXI-Stream)
#   make latency  - measure ingress -> ring-publish latency on real PCAP data
#   make lint     - Verilator lint pass over the RTL
#   make wave     - open the VCD in gtkwave
#   make clean
RTL   := ../rtl/valkyrie_pcie_core.v
TB    := tb_valkyrie_pcie_core.v
TOP   := tb_valkyrie_pcie_core
IVFLAGS := -g2012 -Wall -I../rtl

# PCAP replay settings (override on the command line)
PCAP  ?= ../../pcap_data/db-samples.pcap
LIMIT ?= 2000
STIM  := stim.axis
# p99 capture-latency budget in core clocks (see tb_capture_latency.v)
BUDGET ?= 512

all: run

$(TOP).vvp: $(TB) $(RTL)
	iverilog $(IVFLAGS) -o $@ $(TB) $(RTL)

run: $(TOP).vvp
	@vvp $(TOP).vvp

# --- real market data -> AXI-Stream cosim ---
replay.vvp: tb_pcap_replay.v $(RTL)
	iverilog $(IVFLAGS) -o $@ tb_pcap_replay.v $(RTL)

# --- latency measurement on real market data ---
latency.vvp: tb_capture_latency.v $(RTL)
	iverilog $(IVFLAGS) -o $@ tb_capture_latency.v $(RTL)

$(STIM): FORCE pcap2axis.py $(PCAP)
	python3 pcap2axis.py $(PCAP) $(STIM) $(LIMIT)

stim: $(STIM)

replay: replay.vvp $(STIM)
	@vvp replay.vvp +axis=$(STIM)

latency: latency.vvp $(STIM)
	@vvp latency.vvp +axis=$(STIM) +budget=$(BUDGET)

wave: $(TOP).vvp
	@vvp $(TOP).vvp > /dev/null
	gtkwave valkyrie_pcie_core.vcd &

lint:
	verilator --lint-only -Wall -Wno-DECLFILENAME $(RTL)

clean:
	rm -f *.vvp *.vcd stim.axis

.PHONY: all run replay latency stim wave lint clean FORCE
FORCE:

