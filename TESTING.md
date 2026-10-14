# Testing Valkyrie

What we are actually trying to prove: **market data captured by the NIC reaches
the HFT strategy unmodified, in order, with knowable latency.** The data path is:

```
 NIC / PHY ──► FPGA ingest (AXI-Stream) ──► DMA engine ──► PCIe ──► BAR/ring
                                                                      │
                                        user-space strategy  ◄── mmap ─┘
                                        (in hw: strategy lives IN the FPGA)
```

Every hop can lie independently, so we test each hop in isolation and then the
whole chain. Tests are layered cheapest-first. Layers 0 and 2 run natively on a
laptop; **layer 1 runs in Docker** (a real Linux VM), so no FPGA and no Linux
workstation are required.

| Layer | Target | Tool | Runs here? |
|-------|--------|------|------------|
| 0 RTL | `valkyrie_pcie_core.v` | Icarus Verilog + Verilator | yes (native + Docker) |
| 0d Latency | capture path, ingress → ring | `tb_capture_latency.v` | yes (native + Docker) |
| 1 Kernel | `src/valkyrie_main.c` | compile gate (Docker), then KUnit/QEMU | Docker only |
| 2 User | `include/valkyrie.h`, tools | C unit tests + simulator | yes |
| 3 Hardware | real FPGA card | loopback + latency harness | needs hardware |

### Run everything

```bash
make ci            # the whole hardware-free gate below (~13 s)
make test          # layer 0a: RTL directed conformance        (native)
make rtl-lint      # layer 0c: Verilator lint, zero warnings    (native)
make rtl-replay    # layer 0b: real PCAP market data -> RTL     (native)
make rtl-latency   # layer 0d: capture latency on real PCAP     (native)
make latency       # layer 2:  user-space ITCH latency spread   (native)
make docker-test   # layers 0 + 2 again, on Linux (portability / CI)
make docker-kmod   # layer 1:  compile the module vs real headers
```

`make ci` == `rtl-test rtl-lint rtl-replay rtl-latency`. It fails if any check
fails, if lint emits a single warning, or if one byte of real market data is
lost or mis-stamped — so it is a usable CI gate, not a smoke test.

`make docker-test` runs `docker/run-tests.sh` inside `ubuntu:24.04` (iverilog 12,
Verilator 5.020, gcc 13.3) and exits nonzero if any step fails. Build both images
with `make docker`.

The replay and latency gates read `pcap_data/db-samples.pcap`, which is **not in
git** — it is 199 MB and GitHub rejects files over 100 MB. That file is not a
build product, so supply it locally or redirect the gates with `PCAP=...`; see
[`pcap_data/README.md`](pcap_data/README.md). `make test` and `make rtl-lint`
need no capture.

---

## Layer 0 — FPGA / RTL (Icarus Verilog)

Your strategies run *in the FPGA*, so the RTL is the product. Test it three ways:

### 0a. Directed conformance test (fast, deterministic)

```bash
make test            # == make -C fpga/tb run
```

`fpga/tb/tb_valkyrie_pcie_core.v` is a self-checking testbench that speaks
real AXI-Lite and AXI-Stream and asserts the contract the **Linux driver** and
the **user-space strategy** rely on (98 checks):

- the canonical BAR0 map, which now has **one** definition — the
  `VALKYRIE_REG_*` block in `include/valkyrie.h`. The RTL, the driver, the
  simulator and this testbench all use those numbers, and the testbench fails
  the build if the struct in the simulator drifts (`_Static_assert`/`offsetof`).
- full-offset address decoding: a stray write to `0x40` must not land on
  `dma_ctrl` (the old decoder used only `addr[5:0]`, so it did)
- byte-strobed AXI-Lite writes (`wstrb`), including 64-bit `ring_base`
- DMA-enable gating of `s_axis_tready`
- lossless 64-bit capture: payload byte *i* of a record must equal *i*, which
  catches lane swaps, endianness and offset errors in one sweep
- the 32-byte record header (`valkyrie_pkt_meta_t`) written at the head of every
  packet: timestamp, lengths, port, flags, and the measured latency
- `tkeep` sizing of a short final beat
- MSI-X assertion and `irq_status` W1C
- a **continuous protocol monitor**: `tready` may never fall while a packet is
  in flight. This is the invariant the first version of the core broke (it
  dropped the first beat of every frame while changing state), and a sampled
  check would have missed it.

The testbench exits **non-zero** when a check fails, so it gates CI.

### 0b. Real market-data replay (cosimulation)

Random stimulus finds protocol bugs; **real data** finds accounting bugs.

```bash
make rtl-replay PCAP=pcap_data/db-samples.pcap LIMIT=2000
```

`fpga/tb/pcap2axis.py` converts the capture into AXI-Stream beats
(`tdata tkeep tlast` per line); `fpga/tb/tb_pcap_replay.v` plays them into the
DUT with a **compliant handshake** (advance only when `tready` is high) and a
watchdog. When the stream is done it reads the DUT's own counters back over
AXI-Lite, then **walks every ring and parses the record stream** to prove the
bytes really are in memory:

```
beats in file / beats accepted / backpressure cycles
stalls inside a packet           (must be 0)
packets in file vs records walked
payload bytes in ring vs stimulus (byte-for-byte, plus a checksum per ring)
bytes_written register vs payload + 32 B header x packets
lat_pkts register vs packets
malformed record headers         (must be 0)
```

Backpressure *between* packets is legal AXI-Stream behaviour and is counted
separately; backpressure *inside* a packet means an accepted beat was discarded,
so it is a hard failure. Any mismatch prints **NON-CONFORMANT** and exits
nonzero, which is what makes `make rtl-replay` a CI gate rather than a report.

### 0c. Static lint (catches what simulation shouldn't have to)

```bash
make rtl-lint                     # verilator --lint-only -Wall
```

Lint catches truncation, dead logic and incomplete FSMs that a hand-written
testbench can easily miss. The RTL is lint-clean at `-Wall` with **zero
warnings**, so any new warning is a regression and `make ci` stops.

### 0d. Capture latency on real market data (the number that matters)

```bash
make rtl-latency PCAP=pcap_data/db-samples.pcap LIMIT=2000 BUDGET=512
```

`fpga/tb/tb_capture_latency.v` measures the FPGA's share of the latency:
**from the first byte of a frame being accepted on the AXI-Stream to the
completed record being visible to the host**, counted in core clock cycles. It
drives `hw_timestamp` as a free-running wire clock, then walks the captured
records and verifies, per packet:

- `timestamp_ns` is *exactly* the wire time at that frame's SOF — the stamp is
  anchored to arrival, not taken later and back-dated
- `captured_length` equals the stimulus byte count
- `hw_latency_cycles` equals the frame's own beat count, exactly
- the BAR0 aggregates (`last/min/max/sum/pkts`, i.e. what
  `VALKYRIE_IOCTL_GET_LATENCY` returns) agree with the per-record data

It then reports min/p50/p99/max in cycles and nanoseconds and fails if p99
exceeds `BUDGET`. Because the count is exact, the "measurement" is also the
assertion: a frame whose latency is not its beat count fails the run.

Converting cycles to nanoseconds needs the core frequency; the user-space side
of the same number is shown by `make latency` (layer 2).

### Adding an RTL test

```verilog
check32("name", dut.some_signal, EXPECTED);   // self-checking helper
```

Extend the `[1]`..`[7]` sequence in the testbench and keep every check labelled
so a failure names itself.

---

## Layer 1 — Kernel module (Linux / Docker)

`src/valkyrie_main.c` is a PCIe driver; testing it needs a kernel that
enumerates the device. Three complementary approaches:

### 1a. Compile gate — `make docker-kmod` (run this first)

```bash
make docker-kmod
```

`docker/Dockerfile.kmod` installs `linux-headers-generic` (Ubuntu 24.04 → 6.8.0-*).
**Containers share the host kernel**, so `uname -r` inside the container names a
kernel whose headers do not exist; the target therefore points kbuild at the
headers that are actually on disk:

```bash
make -C /lib/modules/$(ls /lib/modules | head -1)/build M=$PWD modules
```

This is a *compile* gate, not an `insmod` gate — vermagic will not match the host
kernel, which is expected and irrelevant for catching API/ABI breakage.

### 1b. KUnit for the pure logic

The ioctl handlers, ring bookkeeping and
`valk_tasklet` advance/tail logic are testable without hardware once split out
of the file-ops entry points. Move them into a `valkyrie_core.c` with no `pci_`
dependencies, then:

```c
static struct kunit_case valkyrie_cases[] = {
    KUNIT_CASE(valkyrie_ring_advance),
    KUNIT_CASE(valkyrie_ioctl_get_ring),
    KUNIT_CASE(valkyrie_stats_accumulate),
    {}
};
kunit_test_suite(valkyrie_test_suite(valkyrie_cases));
```

Run with `./tools/testing/kunit/kunit.py run`.

### 1c. QEMU with a virtual PCIe device

`qemu-system-x86_64` is installed here.
Boot a Linux guest and attach a device the driver will bind to. QEMU's `edu`
device is a real DMA-capable PCI endpoint and is the standard vehicle for
exercising a DMA driver without hardware:

```bash
qemu-system-x86_64 -M q35 -m 2G -kernel bzImage -append "console=ttyS0" \
  -device edu -nographic
```

Then `insmod valkyrie.ko`, run `pcitest`-style read/write/mmap/ioctl checks, and
verify `dmesg` shows probe → BARs → MSI-X → DMA → remove. To model *Valkyrie
specifically* you want a custom QEMU PCI device (or a `libvfio-user` endpoint)
presenting vendor `0x10EE` device `0x903F` with BAR0 laid out per `sim_bar_t`.
That is the only way to exercise `valk_probe`, `valk_setup_bars`,
`valk_setup_msix` and `valk_mmap` for real.

**Non-negotiable checks for this layer:**

- register map offsets shared with the RTL are byte-identical
- the `mmap`'d ring is the same memory DMA writes (`dma_alloc_coherent`)
- ioctl `GET_STATS` never reports fewer packets than were visibly written
- `rmmod` after a forced `unmap` is clean (no leaked `dma_free_coherent`)

---

## Layer 2 — user-space tools (runs anywhere)

```bash
make tools          # builds tools/pcap_analyzer and simulator/valkyrie_sim
make latency        # per-packet ITCH decode latency distribution
./tools/pcap_analyzer pcap_data/db-samples.pcap --validate --stats
./simulator/valkyrie_sim --pcap pcap_data/db-samples.pcap --verbose
./simulator/valkyrie_sim --pcap pcap_data/db-samples.pcap --core-hz 250000000
```

**`--latency` now measures latency.** It used to print a single wall-clock total
for the whole file, which is a *throughput* figure wearing a latency label: no
distribution, no tail, and nothing about any individual packet. It now times each
packet's decode (IP → UDP → ITCH classify) in windows of 64 packets and reports
min/p50/p90/p99/max plus the mean, so the tail is visible. Two `clock_gettime`
calls per window cost well under a nanosecond per packet.

**`valkyrie_sim` models the same registers.** It writes real
`valkyrie_pkt_meta_t` records (32-byte header + payload) into four rings that
advance round-robin and wrap — it used to overwrite ring 0's first slot 585 171
times and report success — stamps `hw_latency_cycles`, and folds
`last/min/max/sum/pkts` into the same `sim_bar_t` fields the RTL exposes at
`0xB0`..`0xC4`. That struct is pinned to `include/valkyrie.h` with
`_Static_assert(offsetof(...))`, so a drifted offset fails the build instead of
silently reading garbage (the previous `_pad[8]` had moved `hw_timestamp` to
0xB0 while its comment claimed 0xA0).

`pcap_replay/pcap_replay.sh` is a thin wrapper around the analyzer (`cd` to the
repo root, build if missing, forward args) — it has no replay logic of its own;
the name is aspirational and the RTL replay lives in `fpga/tb`.

Add ABI/contract tests so a header change can never silently shift a BAR offset:

```c
_Static_assert(sizeof(valkyrie_pkt_meta_t) == VALKYRIE_PKT_HDR_SIZE,
               "the RTL writes this header byte-by-byte; its size is an interface");
```

Keep a small **synthetic PCAP** in-repo so layer 2 never depends on the 209 MB
sample: build packets whose ITCH fields are known, then assert the analyzer
reports exactly those counts.

### Golden-model cosimulation (the important one for on-FPGA strategies)

The strategy runs in hardware, so "correct" must be defined in software first:

1. Write a software reference in Python/C that consumes the same PCAP and emits
   the strategy's outputs (order-book deltas, quotes, fills).
2. `pcap2axis.py` feeds the identical byte stream into the RTL strategy core.
3. Stream both output sequences out (AXI-Stream / BAR trace) and **diff them
   packet by packet**, reporting the first divergent ITCH sequence number.

That diff is the only test that proves the hardware strategy and the software
model agree on real market data. Do it with a **reduced symbol universe**
first; the full 585 K-packet capture produces a very long trace.

---

## Layer 3 — hardware-in-the-loop

- **Loopback**: program the FPGA to echo the DMA ring back through a second ring;
  compare sent vs received byte-for-byte. Proves PCIe round-trip integrity.
- **Timestamp / latency**: the RTL already latches `hw_timestamp` (readable at
  `0xA0`/`0xA4`, `VALKYRIE_REG_TS_*`) into every record's `timestamp_ns`. Diff it
  against `CLOCK_MONOTONIC` in the user-space reader to get true wire-to-strategy
  latency, then assert a p99 budget. `VALKYRIE_IOCTL_GET_LATENCY` returns the
  FPGA-side split (per-packet cycles plus aggregate min/max/mean) so the fabric
  and host halves can be attributed separately instead of as one number.
- **Ring invariants under load**: run a bounded producer (FPGA) and consumer
  (strategy) and assert `tail <= head`, no overwrite of unread slots, and that
  `ring_overflows` stays 0. This is the test that catches the head/tail bugs the
  RTL has today.

---

## Current status (as measured on this tree)

`make ci` is the authoritative result: **98/98 directed checks, replay
CONFORMANT, latency PASSED, Verilator lint with zero warnings.** When this
harness was first written it reported 8 RTL failures, ~88 % byte loss on real
data and a kernel module that would not compile. Those are now fixed, so the
layers are finally measurable:

| Layer | Command | Result |
|---|---|---|
| 0a RTL conformance | `make test` | 98 checks, 0 failures |
| 0b real-PCAP replay | `make rtl-replay` | 2000 pkts, 86 743 beats, **0** mid-packet stalls |
| 0c lint | `make rtl-lint` | clean at `-Wall` (was 16 warnings) |
| 0d capture latency | `make rtl-latency` | **p99 44 cycles = 176 ns @ 250 MHz** |
| 1 kernel compile | `make docker-kmod` | `valkyrie.ko` links, 0 errors |
| 2 host ITCH latency | `make latency` | p50 78 ns, p99 156 ns @ 12.0 M pkt/s |
| 0+2 inside Linux | `make docker-test` | identical to macOS |

### What the latency tests actually say

| Measurement | Value | Scope |
|---|---|---|
| FPGA capture, p50 | 44 cycles (176 ns @ 250 MHz) | first byte accepted → record visible to host |
| FPGA capture, min / max | 8 / 44 cycles (32 / 176 ns) | 64-byte to 352-byte frames |
| Host ITCH decode, p50 | ~80–95 ns | IP → UDP → ITCH classify, per packet |
| Host ITCH decode, p99 | ~150–450 ns | tail over 585 171 packets |

The FPGA figure is a *fabric* number and it is exact: for a lossless
back-to-back stream the capture latency equals the frame's beat count, and the
test asserts that equality for every record. It is also reproducible — macOS and
the Linux container report identical cycles. The host figure is a *software*
number and moves with the machine, which is why `make latency` prints the
distribution rather than a single value. The remaining term,
`CLOCK_MONOTONIC − timestamp_ns`, is wire-to-strategy latency and is the only
part that needs the real card.

### What these tests still cannot see (no hardware)

- **real DMA to host memory**: the RTL models the rings as on-chip memory, so
  `ring_base` is programmed and readable but the PCIe *master* write path is not
  modelled. A real card is the only way to prove the host sees those bytes.
- **enumeration, MSI-X delivery, `insmod`/`rmmod`**: the Docker gate proves API
  compatibility against real headers, not that the driver binds a device.
- **absolute wire-clock accuracy**: the tests prove `hw_timestamp` is *sampled at
  arrival* and carried losslessly; they say nothing about the MAC's clock being
  right, which is a hardware-calibration question.

### Defects this work found and fixed

Every one of these was caught by a test in this repo, not by inspection:

| Defect | Consequence | Fix |
|---|---|---|
| `tready` registered across state changes | the master saw a beat "accepted" during the publish cycle, then it was dropped | `tready` is now combinational on `S_IDLE \|\| S_DATA` |
| only `tdata[7:0]` stored | 7 of every 8 bytes lost | full 64-bit capture, every `tkeep` lane |
| first beat of every packet discarded | every frame truncated at the head | one FSM; no state change consumes a beat |
| ring head added the pre-increment value | byte accounting wrong by a beat per packet | counters derived from the record length |
| `hw_timestamp` never reached the ring | latency unknowable | 32-byte record header, stamped at SOF |
| three disagreeing BAR maps (RTL / comments / real struct layout) | every mmap'd read returned garbage | one canonical map in `include/valkyrie.h` + `offsetof` asserts |
| `addr[5:0]` decode only | `0x40` aliased `dma_ctrl` | full-offset decode |
| `wstrb` ignored | a partial write clobbered whole registers | byte-strobed writes |
| `feed_port`/`hw_timestamp` at the wrong offsets | driver read the wrong registers | RTL moved to 0xA8/0xA0 |
| `valk_probe` epilogue after `MODULE_VERSION` | 8 functions nested inside `valk_probe`; no build | epilogue restored |
| `class_create(THIS_MODULE,…)`, `vma->vm_flags \|=` | fails on kernel ≥ 6.3/6.4 | version-guarded `class_create`/`vm_flags_set` |
| `MODULE_LICENSE("MIT")` + GPL-only symbols | modpost refused to link the module | `Dual MIT/GPL` |
| shared header included `<stdint.h>` | kernel (freestanding) could not compile it | `__KERNEL__` split, `__u8/__u32/__u64` |
| simulation measured "latency" as total wall time | the number was throughput, not latency | per-packet windowed distribution |
| simulator overwrote one ring slot N times | capture never modelled, latency meaningless | round-robin rings with wrap and real records |


### Layer 1 result

`make docker-kmod` now **builds** `valkyrie.ko` against Ubuntu 24.04 headers
(kernel 6.8):

```
CC [M]  /w/src/valkyrie_main.o
LD [M]  /w/valkyrie.o
MODPOST /w/Module.symvers
LD [M]  /w/valkyrie.ko
```

Five independent defect classes had to be fixed to get there, and each one hid
the next — which is exactly why a compile gate is worth having:

| # | Error | Fix |
|---|---|---|
| 1 | `fatal error: stdint.h: No such file or directory` (then `stddef.h`) | `__KERNEL__` split in the shared header: `<linux/types.h>`/`<linux/ioctl.h>` for the kernel, libc for user space, ABI types as `__u8/__u32/__u64` |
| 2 | `error: invalid storage class for function 'valk_open'` (×8) | `valk_probe`'s epilogue (`err_unmap:` … `return ret; }`) had been left *after* `MODULE_VERSION`, so `valk_open` … `module_exit` and every `MODULE_*` macro were nested inside `valk_probe`; restored, with real ring/irq/tasklet teardown |
| 3 | `error: too many arguments to function 'class_create'` | version-guarded `class_create()` (kernel ≥ 6.4 dropped the `owner` argument) |
| 4 | `error: assignment of read-only member 'vm_flags'` | `vm_flags_set()` on kernel ≥ 6.3 |
| 5 | `ERROR: modpost: GPL-incompatible module valkyrie.ko uses GPL-only symbol 'class_destroy'` (and four more) | `MODULE_LICENSE("Dual MIT/GPL")` — the source is MIT, but the module links GPL-only symbols, so a GPL-compatible tag is required |

This is a *compile* gate, not an `insmod` gate: containers share the host kernel,
so vermagic cannot match and loading is not attempted. That is the deliberate
boundary of what is provable without the card.

Running it also leaves `.o`/`.ko`/`.*.cmd` files next to the sources, because
kbuild writes into the mounted tree; they are gitignored and harmless, and
`make clean` (with `KERNELDIR` pointed at those headers) removes them.


