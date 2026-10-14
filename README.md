# valkyrie — Ultra-Fast Kernel PCIe DMA Module

## Project Overview

Valkyrie is a custom Linux kernel module for **High-Frequency Trading (HFT)** that bypasses the standard network stack, facilitating direct memory access (DMA) transfers from network interface cards (NICs) straight into user-space HFT strategy memory.

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
| **Kernel Module** | `src/valkyrie_main.c` | PCIe driver, BAR mapping, MSI-X, DMA rings, mmap, ioctl |
| **FPGA Simulator** | `simulator/valkyrie_sim.c` | User-space PCIe DMA emulator with PCAP injection |
| **PCAP Analyzer** | `tools/pcap_analyzer.c` | NASDAQ ITCH parser with validation, latency, protocol stats |
| **Shared Types** | `include/valkyrie.h` | Ring/DMA descriptors, ITCH structs, IOCTL defs, stats |
| **Makefile** | `Makefile` | Kernel module build (`make -C /lib/modules/...`) |

## Test Data

`pcap_data/db-samples.pcap` — **209MB** real NASDAQ exchange capture:
- **585,171** packets (100% UDP, nanosecond timestamps)
- **437,113** ITCH protocol messages (AddOrder, Executed, Cancel, Trade, etc.)
- **38** multicast feed ports (14300-14441 range, ITCH 5.0)
- **598s** of market data at **2.67 Mbps**

## Performance (macOS, pcap_analyzer)

- **11.5 million packets/second** processing
- **50ms** to parse + analyze all 585K packets
- Zero-copy architecture eliminates memcpy overhead

## Building

### User-space tools:
```
gcc -O2 -Iinclude -o tools/pcap_analyzer tools/pcap_analyzer.c -lpthread
gcc -O2 -Iinclude -o simulator/valkyrie_sim simulator/valkyrie_sim.c -lpthread
```

### Kernel module (Linux):
```
make -C /lib/modules/$(uname -r)/build M=$PWD modules
sudo insmod valkyrie.ko
```

## Usage Examples

```bash
# Analyze PCAP with statistics
./tools/pcap_analyzer pcap_data/db-samples.pcap --stats

# Check ITCH message validity
./tools/pcap_analyzer pcap_data/db-samples.pcap --validate

# Measure processing latency
./tools/pcap_analyzer pcap_data/db-samples.pcap --latency

# Show first 3 packets only
./tools/pcap_analyzer pcap_data/db-samples.pcap --first=3

# Run FPGA simulator with PCAP injection
./simulator/valkyrie_sim --pcap pcap_data/db-samples.pcap --verbose

# Run PCAP replay harness
./pcap_replay/pcap_replay.sh pcap_data/db-samples.pcap --latency
```

## License

MIT License — Copyright (c) 2026 Frankline Misango Oyolo