# valkyrie
An Ultra Fast kernel PCIe module to perform direct memory access transfers of data from nic to hft algorithms 


## Project Overview & Objectives
In High-Frequency Trading (HFT), microsecond latency reductions dictate profitability. Traditional network socket layers (TCP/IP stacks, kernel-space packet processing) introduce severe jitter and traversal overhead. Valkyrie is a custom Linux kernel module designed to bypass the standard network stack entirely, facilitating direct memory access (DMA) transfers from network interface cards (NICs) straight into user-space HFT strategy memory.

### Primary Objectives
Kernel Bypass Integration: Interface directly with PCIe hardware endpoints to capture market data packets without context switching.

Zero-Copy Architecture: Map ring buffers directly from kernel driver space into user-space application memory pages, avoiding CPU-heavy memcpy operations.

Real-Life Data Integration: Ingest live or recorded PCAP feeds from major financial exchanges (e.g., ITCH/OUCH protocols) straight through custom hardware interfaces.

## Architectural Specifications
A. PCIe Device Driver & BAR Mapping
Base Address Registers (BARs): Map the NIC's onboard memory and control registers into kernel space via ioremap().

Interrupt Handling (MSI-X): Implement Message Signaled Interrupts-Extended (MSI-X) to route packet arrival events to dedicated CPU cores, avoiding legacy interrupt sharing bottlenecks.

B. Ring Buffer & Memory Locking (mlock)
Allocate non-paged kernel memory blocks and pin user-space ring buffers using get_user_pages() and mlock() to prevent the Linux kernel from swapping memory pages to disk.


## Testing & Validation with Real-Life Data
PCAP Replay Harness: Feed historical raw exchange capture files (PCAPs) into a simulated PCIe loopback or testing FPGA card to measure end-to-end packet processing latency.

Jitter Profiling: Track nanosecond-level latency distributions under heavy load using hardware timestamping capabilities built into modern NICs.
