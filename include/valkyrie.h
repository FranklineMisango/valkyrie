#ifndef VALKYRIE_H
#define VALKYRIE_H

/**
 * Valkyrie — Ultra-Fast Kernel PCIe DMA Module for HFT
 * Shared types for kernel module, FPGA simulator, & PCAP replay.
 */

#include <stdint.h>
#include <stddef.h>

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

/* ─── Ring Buffer Descriptor ─── */
typedef struct __attribute__((packed)) {
    volatile uint32_t head;
    volatile uint32_t tail;
    volatile uint32_t flags;
    volatile uint32_t _rsvd;
    uint64_t          base_addr;
    uint32_t          buf_size;
    uint32_t          packet_count;
} valkyrie_ring_desc_t;

#define VALKYRIE_RING_ACTIVE   (1 << 0)
#define VALKYRIE_RING_FULL     (1 << 1)
#define VALKYRIE_RING_ERROR    (1 << 2)
#define VALKYRIE_RING_OVERFLOW (1 << 3)

/* ─── DMA Descriptor ─── */
typedef struct __attribute__((packed)) {
    uint64_t src_addr;
    uint64_t dst_addr;
    uint32_t length;
    uint32_t control;
    uint32_t next_desc;
    uint32_t status;
} valkyrie_dma_desc_t;

#define DMA_DESC_CTRL_IRQ_EN  (1 << 0)
#define DMA_DESC_CTRL_CHAIN   (1 << 1)
#define DMA_DESC_CTRL_LAST    (1 << 2)
#define DMA_DESC_STATUS_DONE  (1 << 0)
#define DMA_DESC_STATUS_ERROR (1 << 1)

/* ─── Packet Metadata ─── */
typedef struct __attribute__((packed)) {
    uint64_t timestamp_ns;
    uint32_t packet_length;
    uint32_t captured_length;
    uint16_t port_id;
    uint16_t flags;
    uint16_t protocol;
    uint16_t _rsvd;
} valkyrie_pkt_meta_t;

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
    uint8_t  msg_type;
    uint8_t  tracking;
    uint32_t seq_number;
    char     session[10];
    uint8_t  payload[];
} itch_msg_t;

/* ─── IOCTL Commands ─── */
#define VALKYRIE_IOCTL_MAGIC     'V'
#define VALKYRIE_IOCTL_GET_RING  _IOR(VALKYRIE_IOCTL_MAGIC, 1, valkyrie_ring_desc_t)
#define VALKYRIE_IOCTL_SET_RING  _IOW(VALKYRIE_IOCTL_MAGIC, 2, valkyrie_ring_desc_t)
#define VALKYRIE_IOCTL_START_DMA _IO(VALKYRIE_IOCTL_MAGIC, 3)
#define VALKYRIE_IOCTL_STOP_DMA  _IO(VALKYRIE_IOCTL_MAGIC, 4)
#define VALKYRIE_IOCTL_GET_STATS _IOR(VALKYRIE_IOCTL_MAGIC, 5, valkyrie_stats_t)
#define VALKYRIE_IOCTL_RESET     _IO(VALKYRIE_IOCTL_MAGIC, 6)

/* ─── Statistics ─── */
typedef struct __attribute__((packed)) {
    uint64_t packets_received;
    uint64_t packets_dropped;
    uint64_t bytes_transferred;
    uint64_t dma_completions;
    uint64_t dma_errors;
    uint64_t ring_overflows;
    uint64_t irq_count;
} valkyrie_stats_t;

/* ─── PCAP Replay Packet ─── */
typedef struct __attribute__((packed)) {
    uint64_t ts_sec;
    uint64_t ts_nsec;
    uint32_t pkt_len;
    uint32_t cap_len;
    uint8_t  data[VALKYRIE_MAX_PACKET_SIZE];
} valkyrie_pcap_pkt_t;

#ifdef __cplusplus
}
#endif

#endif /* VALKYRIE_H */