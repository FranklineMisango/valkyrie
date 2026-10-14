# Valkyrie — PCIe DMA kernel module + host-side test harness
#
# Kernel module (needs Linux headers):
#   make                                   # headers for the running kernel
#   make KERNELDIR=/lib/modules/<ver>/build
#   make docker-kmod                       # compile gate in Linux (macOS hosts)
#
# Host-side tests (no kernel headers required):
#   make test | rtl-test | rtl-lint | rtl-replay | rtl-latency | ci | tools
#   make latency                           # user-space ITCH latency distribution
#   make docker-test                       # RTL + tools gate inside Linux
#
# `make ci` is the full hardware-free gate: directed RTL conformance, Verilator
# lint, real-PCAP replay and the real-PCAP capture-latency measurement.

# ═══════════════════════════ kbuild context ═══════════════════════════
# kbuild re-invokes this file with KERNELRELEASE set. Only module objects may
# be declared here; anything else must live in the `else` branch, or our
# all:/clean: recipes would override kbuild's own goals.
ifneq ($(KERNELRELEASE),)
obj-m := valkyrie.o
valkyrie-objs := src/valkyrie_main.o

ccflags-y := -I$(src)/include -O2 -Wall -Werror
else

# ═══════════════════════════ normal make ═══════════════════════════

KERNELDIR ?= /lib/modules/$(shell uname -r)/build
PWD       := $(shell pwd)

all:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules

clean:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) clean
	rm -f *.o *.ko *.mod.c Module.symvers Module.markers modules.order

install:
	$(MAKE) -C $(KERNELDIR) M=$(PWD) modules_install
	depmod -a

# ═══════════════════════ containerized Linux gates ═══════════════════════
# macOS cannot build/load Linux kernel modules; Docker supplies a Linux userland
# plus real kernel headers, so those layers become testable from this host.
DOCKER     ?= docker
KMOD_IMAGE ?= valkyrie-kmod
TEST_IMAGE ?= valkyrie-test
DOCKER_RUN := $(DOCKER) run --rm --user $(shell id -u):$(shell id -g) \
                -v $(CURDIR):/w -w /w

# Layer 1: compile src/valkyrie_main.c against real kernel headers.
# Containers share the *host* kernel, so `uname -r` does not name the kernel
# whose headers apt installed — point KERNELDIR at what is actually on disk.
docker-kmod:
	$(DOCKER) build -t $(KMOD_IMAGE) -f docker/Dockerfile.kmod .
	$(DOCKER_RUN) $(KMOD_IMAGE) sh -c \
	  'make KERNELDIR=/lib/modules/$$(ls /lib/modules | head -1)/build'

# Layers 0 + 2: RTL sim, Verilator lint, PCAP replay, user-space tools.
docker-test:
	$(DOCKER) build -t $(TEST_IMAGE) -f docker/Dockerfile.test .
	$(DOCKER_RUN) $(TEST_IMAGE) sh docker/run-tests.sh

# Full Linux gate (both images, both gates).
docker: docker-kmod docker-test

.PHONY: all clean install test rtl-test rtl-lint rtl-replay rtl-latency latency \
        ci tools docker docker-kmod docker-test

# ─── Host-side test targets (no kernel headers required) ───
# RTL functional conformance (Icarus Verilog). Fails on real defects.
rtl-test:
	$(MAKE) -C fpga/tb run

# Verilator lint gate (structural checks: truncation, unused/dead logic).
rtl-lint:
	$(MAKE) -C fpga/tb lint

# Full gate: functional + lint.
ci: rtl-test rtl-lint rtl-replay rtl-latency

# Replay real PCAP market data through the RTL AXI-Stream ingress.
#   make rtl-replay PCAP=pcap_data/db-samples.pcap LIMIT=2000
PCAP  ?= pcap_data/db-samples.pcap
LIMIT ?= 2000
rtl-replay:
	$(MAKE) -C fpga/tb replay PCAP=$(CURDIR)/$(PCAP) LIMIT=$(LIMIT)

# Capture latency on real market data: ingress -> ring publish, in core clocks.
# Asserts that every frame is stamped at arrival and that p99 fits the budget.
#   make rtl-latency LIMIT=2000 BUDGET=512
BUDGET ?= 512
rtl-latency:
	$(MAKE) -C fpga/tb latency PCAP=$(CURDIR)/$(PCAP) LIMIT=$(LIMIT) BUDGET=$(BUDGET)

# User-space tools (analyzer + simulator) - used by the PCAP replay harness.
tools:
	gcc -O2 -Wall -Iinclude -o tools/pcap_analyzer tools/pcap_analyzer.c -lpthread
	gcc -O2 -Wall -Iinclude -o simulator/valkyrie_sim simulator/valkyrie_sim.c -lpthread

# Host-side ITCH decode latency distribution over the same capture.
latency: tools
	./tools/pcap_analyzer $(PCAP) --latency

test: rtl-test

endif