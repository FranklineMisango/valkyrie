# valkyrie — Ultra-Fast Kernel PCIe DMA Module

## Project Overview

Valkyrie is a custom Linux kernel module for **High-Frequency Trading (HFT)** that bypasses the standard network stack, facilitating direct memory access (DMA) transfers from network interface cards (NICs) straight into user-space HFT strategy memory.

> **Status: research prototype with a green hardware-free test harness.**
> The RTL, driver, simulator and tools all build and are covered by `make ci`,
> but **none of it has run on a PCIe card yet**. The host-side DMA *write* path,
> the MAC/PTP front end and timing closure are still to be built — see
> [Road to Production](#road-to-production). Every latency number in this README
> is a *fabric* or *software* figure, never a wire-to-strategy claim.

### Objectives
- **Kernel Bypass**: Interface directly with PCIe hardware endpoints to capture market data without context switching.
- **Zero-Copy**: Map ring buffers from kernel driver space into user-space memory, avoiding memcpy operations.
- **Real Data**: Ingest live/recorded NASDAQ ITCH/OUCH exchange feeds through custom hardware interfaces.

## Architecture

```
  User Space (HFT App)      Kernel Module (LKM)        NIC / FPGA
 ┌─────────────────┐      ┌───────────────────┐      ┌──────────┐
 │ mmap'd Ring     │◄────►│ PCIe Driver       │◄────►│ Market   │
 │ Buffers         │      │ BAR Mapping       │      │ Data In  │
 │ ioctl control   │      │ MSI-X IRQ (4 vec) │      │          │
 │ DMA completions │      │ DMA Ring Buffers  │      │ PCAP     │
 └─────────────────┘      └───────────────────┘      └──────────┘
```

## Components

| Component | File | Description |
|-----------|------|-------------|
| **FPGA RTL** | `fpga/rtl/valkyrie_pcie_core.v` | PCIe DMA capture core: AXI-Lite BAR0, AXI-Stream ingest, ring records with hardware timestamps |
| **Kernel Module** | `src/valkyrie_main.c` | PCIe driver, BAR mapping, MSI-X, DMA rings, mmap, ioctl |
| **FPGA Simulator** | `simulator/valkyrie_sim.c` | User-space PCIe DMA emulator with PCAP injection and latency model |
| **PCAP Analyzer** | `tools/pcap_analyzer.c` | NASDAQ ITCH parser with validation, latency, protocol stats |
| **Shared Types** | `include/valkyrie.h` | Canonical BAR0 register map, ring/DMA descriptors, ITCH structs, IOCTL defs, stats |
| **RTL testbenches** | `fpga/tb/` | Directed conformance, real-PCAP replay, capture-latency measurement |
| **Makefile** | `Makefile` | Kernel module build + host-side test gates (`make ci`) |

## Test Data

`pcap_data/db-samples.pcap` — **209MB** real NASDAQ exchange capture:
- **585,171** packets (100% UDP, nanosecond timestamps)
- **437,113** ITCH protocol messages (AddOrder, Executed, Cancel, Trade, etc.)
- **38** multicast feed ports (14300-14441 range, ITCH 5.0)
- **598s** of market data at **2.67 Mbps**

This capture is **not committed**: at 199 MB it exceeds GitHub's 100 MB per-file
limit, and it is derived test data rather than source. See
[`pcap_data/README.md`](pcap_data/README.md) for how to supply it, or point the
harness at any classic-PCAP file with `make rtl-replay PCAP=/path/to/file.pcap`.
The directed conformance suite (`make test`) and lint (`make rtl-lint`) need no
capture at all.

## Measured Performance

Latency is reported as two separate, attributed numbers rather than one figure.
`make rtl-latency` measures the fabric; `make latency` measures the software path:

| Path | p50 | p99 | Scope |
|---|---|---|---|
| FPGA capture (RTL) | 44 cycles (176 ns @ 250 MHz) | 44 cycles | first byte accepted → record visible to host |
| Host ITCH decode | ~80–95 ns | ~150–450 ns | IP → UDP → ITCH classify, per packet |

Throughput: **~9–12 million packets/second** (585 171 packets in 50–63 ms) on a
laptop; `./tools/pcap_analyzer pcap_data/db-samples.pcap --latency` prints both
numbers for the machine you run it on.

The FPGA figure is exact and reproducible — for a lossless stream, capture
latency equals the frame's own beat count, and the testbench asserts that for
every record on real capture data. The host figure is wall-clock software timing
and moves with machine load. The only remaining term for true wire-to-strategy
latency is `CLOCK_MONOTONIC − timestamp_ns`, which needs the physical card.

## Building

### User-space tools:
```
make tools     # builds tools/pcap_analyzer and simulator/valkyrie_sim
```

### Kernel module:
```
make                      # against the running kernel's headers
make docker-kmod          # compile gate on Linux, from macOS (Docker)
```
The module links GPL-only kernel symbols, so it is tagged `Dual MIT/GPL` (the
source itself is MIT).

## Usage Examples

```bash
# Analyze PCAP with statistics
./tools/pcap_analyzer pcap_data/db-samples.pcap --stats

# Check ITCH message validity
./tools/pcap_analyzer pcap_data/db-samples.pcap --validate

# Per-packet processing latency distribution (min/p50/p90/p99/max)
./tools/pcap_analyzer pcap_data/db-samples.pcap --latency

# Show first 3 packets only
./tools/pcap_analyzer pcap_data/db-samples.pcap --first=3

# Run FPGA simulator with PCAP injection (models the BAR0 latency registers)
./simulator/valkyrie_sim --pcap pcap_data/db-samples.pcap --verbose
./simulator/valkyrie_sim --pcap pcap_data/db-samples.pcap --core-hz 250000000

# RTL: real market data through the capture core + measured latency
make rtl-replay
make rtl-latency BUDGET=512

# Everything that can run without an FPGA
make ci
```

`pcap_replay/pcap_replay.sh` is a thin convenience wrapper around
`pcap_analyzer` (it locates the repo root, builds the binary if missing, and
forwards its arguments); the RTL replay lives in `fpga/tb`.

## Testing

See **[TESTING.md](TESTING.md)** for the layered test plan, what each layer can
and cannot prove without hardware, and the measured results. `make ci` is the
authoritative gate: RTL conformance, lint, real-PCAP replay and capture latency.

## Where This Stands

| Area | State | Evidence |
|---|---|---|
| Canonical BAR0 map, one definition | **done** | `include/valkyrie.h` + `offsetof` asserts |
| Capture FSM, `tready` protocol, byte-exact records | **done** | `make test` — 98 checks |
| Per-record timestamp + fabric latency | **done** | `make rtl-latency` |
| Real-PCAP replay, lossless | **done** | `make rtl-replay` |
| Module compiles against real kernel headers | **done** | `make docker-kmod` |
| Module **bound to a device** (probe/MSI-X/mmap) | not yet | needs QEMU or a card — TESTING.md §1c |
| Host DMA **write** engine (records leave the chip) | **not built** | see below |
| MAC/PHY, VLAN filter, PTP hardware clock | **not built** | `hw_timestamp` is an input port |
| Timing closure / Fmax | **unknown** | no `.xdc`, no synthesis run |
| Loss detection (sequence gaps) | **not implemented** | ring counters only |

Stated plainly: **there is no wire-to-strategy latency number in this repository.**
What exists is the fabric half of it, measured exactly, plus the harness that
will measure the rest the day a card is plugged in.

---

## Road to Production

Six phases, cheapest first. Only Phase 3 needs a card, and Phase 0 needs nothing
but the repo. Each phase lists its exit criterion so "done" is falsifiable.

### Phase 0 — freeze the ABI and make loss detectable (no hardware)

Today the driver cannot tell whether it missed a packet: counters say *how many*
packets were seen, not *which* ones. "Lossless" is only defensible with gap
detection, so this comes before any hardware.

- Add `VALKYRIE_ABI_VERSION` to the BAR0 map + a `GET_VERSION` ioctl; refuse to
  attach a driver to a fabric it does not match.
- Use the existing `_rsvd2` word as a **per-ring 32-bit record sequence number**.
  The header stays 32 bytes, so this is ABI-compatible and the `_Static_assert`
  keeps it honest.
- Set a per-record `flags` bit when `ring_overflow` advances, so host software
  knows *which* record overwrote data rather than only that it happened once.
- Document and test the overflow policy (today: overwrite-oldest) and expose both
  the drop and overwrite counters.
- Split `valkyrie_core.c` (pure logic: ring advance, ioctl copy-out, stats,
  sequence-gap detection) from `valkyrie_pci.c` (PCIe plumbing) so the first half
  is KUnit-testable without hardware — TESTING.md §1b.
- Add a GitHub Actions workflow running `make ci`, `make docker-test` and
  `make docker-kmod` on push, with the images **pinned**, so an iverilog 12↔13
  bump cannot change results silently.

*Exit:* CI green on Linux and macOS; ABI-version mismatch rejected; sequence-gap
test fails on an injected drop and passes otherwise.

### Phase 1 — a real PCIe endpoint in QEMU (no FPGA)

Compiling the module proves it builds, not that `valk_probe` works.

- Model vendor `0x10EE` device `0x903F` as a QEMU PCI device (or a
  `libvfio-user` endpoint) with BAR0 laid out exactly per `sim_bar_t`, an MSI-X
  table, and a DMA engine that can write into guest memory.
- Exercise `valk_probe` → `valk_setup_bars` → `valk_setup_msix` → `valk_mmap`
  → `valk_tasklet` → `valk_remove` against it, with `DMA-API` debugging and
  kmemleak on.

*Exit:* `insmod` probes cleanly, `mmap`'d ring reads what the modelled DMA engine
wrote, `ioctl GET_STATS`/`GET_LATENCY` return sane values, `rmmod` is leak-free.

### Phase 2 — synthesis, timing, and honest nanoseconds

The 250 MHz used to convert cycles to nanoseconds is an **assumption**. Replace
it with a measurement before quoting any ns figure.

- Add a `.xdc`/`.sdc` (PCIe reference + user clock) and run out-of-context
  synthesis; Vivado `report_timing_summary` for the real target, or
  Yosys + nextpnr for a cheap area/Fmax estimate on Artix-7 or ECP5.
- Feed the measured Fmax back through the `CoreHz` parameter so `make rtl-latency`
  stops assuming a clock. Note the direction of travel: Gen4 x8 user clocks run
  ~500 MHz, which *halves* the wall-clock figure for the same cycle count.
- Add functional/coverage reporting to the existing testbenches (cocotb is
  optional; Verilator coverage is nearly free).

### Phase 3 — the DMA write engine, then a first `insmod`

This is the largest missing piece and the reason no record has ever reached host
memory (see below). Pair it with the cheapest platform that has a PCIe hard IP:

- Write the descriptor-driven AXI4 master (details in the next section).
- Bring up on Xilinx XDMA (Alveo U50/U55C, or a Kintex-7 board) and reuse the
  vendor hard IP for the transaction layer rather than reinventing it.
- On the host, watch `dmesg` for the first real probe, confirm BAR0 read-back,
  MSI-X vector count, `mmap` coherence, and one hand-injected packet.

*Exit:* a single record appears in host DDR byte-identical to the stimulus, the
ring counters advance, and `irq_status` W1C clears the interrupt.

### Phase 4 — line rate, PTP, and a defensible loss story

- 10G/25G MAC + PCS (Xilinx 10G/25G Ethernet Subsystem or equivalent) with
  802.1Q VLAN handling and a multicast/feed-port filter in front of the capture
  core. Today the core accepts *all* AXI-Stream traffic.
- An IEEE 1588 PTP hardware clock feeding `hw_timestamp`, disciplined by
  `ptp4l`/`phc2sys`, so the fabric stamp and the host's `CLOCK_MONOTONIC` share
  an epoch. Without that, `CLOCK_MONOTONIC − timestamp_ns` is meaningless.
- Clock-domain crossing: add `s_axis_aclk` (MAC RX) alongside `s_axi_aclk`
  (PCIe user clock) with async FIFOs, and latch the timestamp **in the MAC
  domain** at SOF, not after the crossing.
- Decide the backpressure story. `s_axis_tready` is currently high whenever the
  core is idle or streaming — it never slows the MAC down — so a burst faster
  than the DMA drain silently overwrites the ring. For a single ~2.67 Mbps ITCH
  feed, PCIe Gen3 x8 delivers gigabytes per second and a documented bandwidth
  budget is ample; for aggregated 25G you need a credit scheme and loss
  counters, not hope.
- Optionally set `PKT_FLAG_CHECKSUM_OK`: the flag exists in the header but no RTL
  currently computes anything, and the MAC gives you FCS for free.

*Exit:* 24 h soak at line rate with **zero sequence gaps**, and a per-ring
hardware checksum matching the same software checksum the replay testbench
already computes.

### Phase 5 — productionisation

- Packaging: DKMS, module signing for Secure Boot, and a **PCI-SIG-assigned
  vendor ID** (`0x10EE` is Xilinx's development ID, not ours).
- A `libvalkyrie` for strategy authors: documented mmap consumer protocol with
  read-pointer writeback, sequence-gap detection, and an `epoll`/`eventfd`
  wakeup path — today the only wakeup is the IRQ/tasklet pair. Freeze the ioctl
  ABI (already `'V'`-magic'd) and ship the ring layout as a versioned contract.
- Observability: export ring overflow, sequence gaps and p50/p99 to Prometheus;
  eBPF for the strategy side.
- Ops hardening: IOMMU on *and* off, `vfio-pci` passthrough inside VMs,
  hugepages (`MAP_HUGETLB`; `C_RING_SIZE` is already 2 MiB), `isolcpus`/
  `nohz_full`, IRQ affinity, C-state/turbo jitter control, AER error injection,
  and `rmmod` under load.
- If a board ships: CE/FCC, thermal validation, and a second-source story for
  the FPGA itself.

*Exit:* a documented latency distribution (p50/p99/p99.9) with a named
measurement method, plus a loss counter that reads zero under soak.

## The Engine That Isn't There Yet

`r_ring_base[i]` is programmable over BAR0 — and then never used as a bus
address. Records are written into `mem[]`, an inferred BRAM array, which means
**nothing currently leaves the chip.** This is the single largest gap between
"tested prototype" and "usable NIC", so it is worth naming precisely:

- an AXI4 master (or the vendor IP's DMA port) issuing 64-byte cacheline writes,
  ≤256-beat bursts, breaking on 4 KiB boundaries;
- a descriptor/completion ring, so the driver's `valk_tasklet` has real work to
  reap — the coherent rings (`dma_alloc_coherent`), the tasklet and the per-ring
  MSI-X interrupts all already exist in the driver, but nothing exercises them
  until a device actually writes memory;
- a tail-pointer writeback so host and fabric agree on what has been published;
- 64-bit addressing, which already matches
  `dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(64))` in the driver.

Worth noting: once a real MAC can truncate frames, `captured_length` will start
to differ from `packet_length`. Both fields are already in the header and the
latency testbench already asserts their relationship, so that work has a home.

## Integration Points

| Integration | What it buys | Status |
|---|---|---|
| **DPDK / pktgen** | line-rate traffic generation, plus a CPU baseline to quote honestly | not wired; `fpga/tb/pcap2axis.py` already emits the AXI stimulus format |
| **MoonGen / tcpreplay** | replaying the real capture at 10/25G into the card | not wired |
| **linuxptp** (`ptp4l`, `phc2sys`) | a shared epoch for fabric and host time, so `CLOCK_MONOTONIC − timestamp_ns` means something | required by Phase 4 |
| **Solarflare `ef_vi` / OpenOnload** | the incumbent to benchmark against — "ultra-fast" is a claim relative to this | not wired |
| **NASDAQ ITCH 5.0 / OUCH** | the layer above the ring: feed handler, order book, sequence recovery | parser exists in `tools/pcap_analyzer.c`; no library form and no book |
| **KUnit + QEMU / `libvfio-user`** | kernel-layer correctness without hardware | designed in TESTING.md §1b/§1c, not implemented |
| **cocotb / Verilator coverage** | Python-driven RTL regression and coverage closure | Verilator lint is wired; cocotb is not |
| **GitHub Actions** | enforcing the gate on every push | targets exist (`ci`, `docker-test`, `docker-kmod`); no workflow file yet |
| **Prometheus + eBPF** | production visibility into overflow, gaps and tail latency | nothing yet |

## Hardware Options

| Platform | Role | Trade-off |
|---|---|---|
| Xilinx Alveo U50/U55C | first real bring-up, Gen3 x16 / Gen4 x8, DDR4 | fastest path via Vivado + XDMA; a dev card, not a product |
| Kintex-7 / Artix-7 + XDMA | cheapest PCIe-capable board | Gen2 x4/x8 — fine for logic bring-up, too slow for line-rate claims |
| Artix-7 / ECP5 + Yosys + nextpnr | Fmax and area exploration on an open toolchain | not PCIe-capable on its own, but needs no Vivado licence |
| Intel Stratix 10 / Agilex F-tile | alternative production silicon, 100G-capable | Quartus flow, different hard-IP integration |
| Custom board + 25G MAC + PTP | the shippable product | needs a PCI-SIG vendor ID, DDR, thermal design, CE/FCC |

## Deployment Checklist

What has to be true before this sits next to a real strategy:

- **Host/firmware** — IOMMU verified on *and* off; `vfio-pci` passthrough tested
  if the strategy runs in a VM; `pci_set_master` and 64-bit DMA masks confirmed
  against a real endpoint, not a model.
- **Memory** — coherent rings backed by 2 MiB hugepages to match `C_RING_SIZE`;
  `mmap` alignment and `MAP_HUGETLB` behaviour validated; no reclaim stalls on
  the ring path.
- **CPU/jitter** — `isolcpus`, `nohz_full`, MSI-X IRQ affinity, C-states and
  turbo pinned; optionally `PREEMPT_RT`. Software latency measured on a laptop
  is not a latency budget on a trading box.
- **Boot/supply chain** — signed module for Secure Boot, DKMS rebuild per kernel,
  pinned kernel version; an unsigned module is a failed audit.
- **Failure modes** — AER error injection, a ring-stall watchdog, `rmmod` under
  load, and an overflow policy the strategy can actually act on.
- **Measurement** — a named method for every number quoted (hardware-timestamped
  loopback and/or PTP grandmaster cross-check), reported as a distribution with
  its sample count, never a single best-case figure.

## License

MIT License — Copyright (c) 2026 Frankline Misango Oyolo