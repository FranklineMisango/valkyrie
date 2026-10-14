#ifndef VALKYRIE_H
#define VALKYRIE_H

/**
 * Valkyrie — Ultra-Fast Kernel PCIe DMA Module for HFT
 * Shared types for kernel module, FPGA simulator, & PCAP replay.
 */

#ifdef __KERNEL__
/* Kernel context: pull fixed-width types and ioctl helpers from the kernel.
 * Including <stdint.h>/<stddef.h> here would break the module build
 * (-Werror), because the kernel deliberately has no such headers. */
# include <linux/types.h>
# include <linux/ioctl.h>
#else
# include <stdint.h>
# include <stddef.h>
# include <sys/ioctl.h>
/* User space gets the kernel's fixed-width spellings, so the ABI structs
 * below can use one set of type names in both worlds. */
typedef uint8_t  __u8;
typedef uint16_t __u16;
typedef uint32_t __u32;
typedef uint64_t __u64;
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ─── PCIe & DMA Constants ─── */
#define VALKYRIE_DEVICE_NAME      "valkyrie"
#define VALKYRIE_CLASS_NAME       "valkyrie_dma"
#define VALKYRIE_BAR_COUNT        6
#define VALKYRIE_MAX_RING_BUFFERS 8
#define VALKYRIE_RING_BUF_SIZE    (2UL * 1024 * 1024)  /* 2 MB */
#define VALKYRIE_RING_BUF_COUNT   4
#define VALKYRIE_DMA_BLOCK_SIZE   4096
#define VALKYRIE_MAX_PACKET_SIZE  2048
#define VALKYRIE_MSIX_VECTORS     4

/* ─── BAR0 Register Map ───
 * Single source of truth for the RTL (fpga/rtl/valkyrie_pcie_core.v), the
 * Linux driver and the user-space simulator. These three used to carry
 * private copies that disagreed (feed_port at 0x10 vs 0xA8, hw_timestamp at
 * 0x1C vs 0xA0/B0), so any register read through mmap returned garbage.
 * fpga/tb/tb_valkyrie_pcie_core.v checks the RTL against these numbers.
 */
#define VALKYRIE_REG_DMA_CTRL       0x000  /* RW  b0 enable, b1 soft-reset       */
#define VALKYRIE_REG_DMA_STATUS     0x004  /* RO  b0 running, b1 busy, b2 error  */
#define VALKYRIE_REG_IRQ_CTRL       0x008  /* RW  b0 packet-ready IRQ enable     */
#define VALKYRIE_REG_IRQ_STATUS     0x00C  /* RO / W1C  b0 packet-ready          */
#define VALKYRIE_REG_RING_BASE(i)   (0x010 + 8*(i))  /* RW u64 host phys addr   */
#define VALKYRIE_REG_RING_SIZE(i)   (0x050 + 4*(i))  /* RW u32 bytes per ring   */
#define VALKYRIE_REG_PKT_COUNT(i)   (0x070 + 4*(i))  /* RO u32 per-ring packets */
#define VALKYRIE_REG_BYTES_WRITTEN  0x090  /* RO  u64 total ring bytes written   */
#define VALKYRIE_REG_TS_LO          0x0A0  /* RO  hw_timestamp[31:0]  (ns)       */
#define VALKYRIE_REG_TS_HI          0x0A4  /* RO  hw_timestamp[63:32]            */
#define VALKYRIE_REG_FEED_PORT      0x0A8  /* RW  u32 UDP feed port              */
/* Capture latency instrumentation: ingress -> ring publish, in core clocks. */
#define VALKYRIE_REG_LAT_LAST       0x0B0  /* RO  last packet, clocks            */
#define VALKYRIE_REG_LAT_MIN        0x0B4  /* RO  minimum observed               */
#define VALKYRIE_REG_LAT_MAX        0x0B8  /* RO  maximum observed               */
#define VALKYRIE_REG_LAT_SUM_LO     0x0BC  /* RO  accumulator, low  32 bits      */
#define VALKYRIE_REG_LAT_SUM_HI     0x0C0  /* RO  accumulator, high 32 bits      */
#define VALKYRIE_REG_LAT_PKTS       0x0C4  /* RO  packets in the sample          */
#define VALKYRIE_REG_RING_OVERFLOW  0x0C8  /* RO  records that wrapped the ring  */
#define VALKYRIE_BAR0_SIZE          0x1000

#define VALKYRIE_DMA_CTRL_ENABLE    0x1
#define VALKYRIE_DMA_CTRL_RESET     0x2
#define VALKYRIE_DMA_STATUS_RUNNING 0x1
#define VALKYRIE_DMA_STATUS_BUSY    0x2
#define VALKYRIE_DMA_STATUS_ERROR   0x4

/* ─── Ring Buffer Descriptor ─── */
typedef struct __attribute__((packed)) {
    volatile __u32 head;
    volatile __u32 tail;
    volatile __u32 flags;
    volatile __u32 _rsvd;
    __u64          base_addr;
    __u32          buf_size;
    __u32          packet_count;
} valkyrie_ring_desc_t;

#define VALKYRIE_RING_ACTIVE   (1 << 0)
#define VALKYRIE_RING_FULL     (1 << 1)
#define VALKYRIE_RING_ERROR    (1 << 2)
#define VALKYRIE_RING_OVERFLOW (1 << 3)

/* ─── DMA Descriptor ─── */
typedef struct __attribute__((packed)) {
    __u64 src_addr;
    __u64 dst_addr;
    __u32 length;
    __u32 control;
    __u32 next_desc;
    __u32 status;
} valkyrie_dma_desc_t;

#define DMA_DESC_CTRL_IRQ_EN  (1 << 0)
#define DMA_DESC_CTRL_CHAIN   (1 << 1)
#define DMA_DESC_CTRL_LAST    (1 << 2)
#define DMA_DESC_STATUS_DONE  (1 << 0)
#define DMA_DESC_STATUS_ERROR (1 << 1)

/* ─── Packet Metadata ───
 * The FPGA writes this header at the head of every captured packet, followed
 * by `captured_length` bytes of frame, so user space walks the ring as a
 * sequence of { valkyrie_pkt_meta_t, payload } records. Its size is fixed by
 * VALKYRIE_PKT_HDR_SIZE because the RTL emits it byte-by-byte.
 */
typedef struct __attribute__((packed)) {
    __u64 timestamp_ns;      /* [0x00] hw_timestamp latched at ingress (SOF) */
    __u32 packet_length;     /* [0x08] on-wire frame length                  */
    __u32 captured_length;   /* [0x0C] bytes actually stored in the ring     */
    __u16 port_id;           /* [0x10] feed port                             */
    __u16 flags;             /* [0x12] PKT_FLAG_*                            */
    __u16 protocol;          /* [0x14] ethertype                             */
    __u16 _rsvd;             /* [0x16]                                       */
    __u32 hw_latency_cycles; /* [0x18] ingress -> ring publish, core clocks  */
    __u32 _rsvd2;            /* [0x1C] pad to VALKYRIE_PKT_HDR_SIZE          */
} valkyrie_pkt_meta_t;

#define VALKYRIE_PKT_HDR_SIZE 32
_Static_assert(sizeof(valkyrie_pkt_meta_t) == VALKYRIE_PKT_HDR_SIZE,
               "the RTL emits a 32-byte packet header; keep this struct in sync");

#define PKT_FLAG_HW_TIMESTAMP (1 << 0)
#define PKT_FLAG_CHECKSUM_OK  (1 << 1)

/* ─── ITCH Protocol (NASDAQ TotalView-ITCH 5.0) ─── */
enum itch_msg_type {
    ITCH_SYSTEM_EVENT    = 'S', ITCH_STOCK_DIRECTORY = 'R',
    ITCH_TRADING_ACTION  = 'H', ITCH_ADD_ORDER       = 'A',
    ITCH_ADD_ORDER_MPID  = 'F', ITCH_ORDER_EXECUTED  = 'E',
    ITCH_ORDER_EXEC_PRC  = 'C', ITCH_ORDER_CANCEL    = 'X',
    ITCH_ORDER_DELETE    = 'D', ITCH_ORDER_REPLACE   = 'U',
    ITCH_TRADE           = 'P', ITCH_CROSS_TRADE     = 'Q',
    ITCH_BROKEN_TRADE    = 'B', ITCH_NOII            = 'I',
};

typedef struct __attribute__((packed)) {
    __u8  msg_type;
    __u8  tracking;
    __u32 seq_number;
    char  session[10];
    __u8  payload[];
} itch_msg_t;

/* ─── IOCTL Commands ─── */
#define VALKYRIE_IOCTL_MAGIC     'V'
#define VALKYRIE_IOCTL_GET_RING  _IOR(VALKYRIE_IOCTL_MAGIC, 1, valkyrie_ring_desc_t)
#define VALKYRIE_IOCTL_SET_RING  _IOW(VALKYRIE_IOCTL_MAGIC, 2, valkyrie_ring_desc_t)
#define VALKYRIE_IOCTL_START_DMA _IO(VALKYRIE_IOCTL_MAGIC, 3)
#define VALKYRIE_IOCTL_STOP_DMA  _IO(VALKYRIE_IOCTL_MAGIC, 4)
#define VALKYRIE_IOCTL_GET_STATS _IOR(VALKYRIE_IOCTL_MAGIC, 5, valkyrie_stats_t)
#define VALKYRIE_IOCTL_RESET     _IO(VALKYRIE_IOCTL_MAGIC, 6)
#define VALKYRIE_IOCTL_GET_LATENCY _IOR(VALKYRIE_IOCTL_MAGIC, 7, valkyrie_latency_t)

/* ─── Capture Latency (RTL instrumentation, read back through BAR0) ───
 * "Latency" here is the FPGA's ingress -> ring-publish delay in core clocks.
 * User space converts it to nanoseconds with the core clock frequency, then
 * adds (CLOCK_MONOTONIC - timestamp_ns) to get true wire-to-strategy latency.
 */
typedef struct __attribute__((packed)) {
    __u64 timestamp_ns;   /* latest hw_timestamp (last packet's arrival)  */
    __u64 sum_cycles;     /* accumulator over `packets` samples           */
    __u32 last_cycles;
    __u32 min_cycles;
    __u32 max_cycles;
    __u32 packets;
    __u32 ring_overflows;
    __u32 _rsvd;
} valkyrie_latency_t;

/* ─── Statistics ─── */
typedef struct __attribute__((packed)) {
    __u64 packets_received;
    __u64 packets_dropped;
    __u64 bytes_transferred;
    __u64 dma_completions;
    __u64 dma_errors;
    __u64 ring_overflows;
    __u64 irq_count;
} valkyrie_stats_t;

/* ─── PCAP Replay Packet ─── */
typedef struct __attribute__((packed)) {
    __u64 ts_sec;
    __u64 ts_nsec;
    __u32 pkt_len;
    __u32 cap_len;
    __u8  data[VALKYRIE_MAX_PACKET_SIZE];
} valkyrie_pcap_pkt_t;

#ifdef __cplusplus
}
#endif

#endif /* VALKYRIE_H */