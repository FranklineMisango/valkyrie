/**
 * valkyrie_sim.c — FPGA PCIe DMA Simulator
 * Emulates PCIe DMA device in user-space. Streams PCAP through ring buffers.
 * Build: gcc -O2 -Wall -o valkyrie_sim valkyrie_sim.c -lpthread
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <pthread.h>
#include <time.h>
#include <sys/stat.h>
#include <fcntl.h>
#include "valkyrie.h"

/* BAR0 register file. This mirrors include/valkyrie.h's canonical map exactly
 * -- the _Static_asserts below fail the build if the two ever drift apart.
 * (Previously this struct's _pad[8] was twice as large as the comments
 * claimed, which silently moved hw_timestamp/feed_port to 0xB0/0xB8.) */
typedef struct {
    uint32_t dma_control;        /* [0x000] */
    uint32_t dma_status;         /* [0x004] */
    uint32_t irq_control;        /* [0x008] */
    uint32_t irq_status;         /* [0x00C] */
    uint64_t ring_base[8];       /* [0x010] */
    uint32_t ring_size[8];       /* [0x050] */
    uint32_t packet_count[8];    /* [0x070] */
    uint32_t bytes_written_lo;   /* [0x090] */
    uint32_t bytes_written_hi;   /* [0x094] */
    uint32_t _pad0[2];           /* [0x098] */
    uint64_t hw_timestamp;       /* [0x0A0] */
    uint32_t feed_port;          /* [0x0A8] */
    uint32_t _pad1[1];           /* [0x0AC] */
    uint32_t lat_last;           /* [0x0B0] */
    uint32_t lat_min;            /* [0x0B4] */
    uint32_t lat_max;            /* [0x0B8] */
    uint32_t lat_sum_lo;         /* [0x0BC] */
    uint32_t lat_sum_hi;         /* [0x0C0] */
    uint32_t lat_pkts;           /* [0x0C4] */
} sim_bar_t;

_Static_assert(offsetof(sim_bar_t, dma_control) == VALKYRIE_REG_DMA_CTRL,
               "BAR0 map drifted");
_Static_assert(offsetof(sim_bar_t, ring_base)   == VALKYRIE_REG_RING_BASE(0),
               "BAR0 map drifted");
_Static_assert(offsetof(sim_bar_t, ring_size)   == VALKYRIE_REG_RING_SIZE(0),
               "BAR0 map drifted");
_Static_assert(offsetof(sim_bar_t, packet_count) == VALKYRIE_REG_PKT_COUNT(0),
               "BAR0 map drifted");
_Static_assert(offsetof(sim_bar_t, hw_timestamp) == VALKYRIE_REG_TS_LO,
               "BAR0 map drifted");
_Static_assert(offsetof(sim_bar_t, feed_port)   == VALKYRIE_REG_FEED_PORT,
               "BAR0 map drifted");
_Static_assert(offsetof(sim_bar_t, lat_last)    == VALKYRIE_REG_LAT_LAST,
               "BAR0 map drifted");

typedef struct {
    const char *pcap_file;
    int         replay_rate, loop, verbose, running;
    int         nrings;              /* rings actually allocated           */
    uint64_t    core_hz;             /* modelled FPGA core clock (for LAT_*) */
    sim_bar_t   bar;
    pthread_t   dma_thread;
    pthread_mutex_t lock;
    uint8_t    *pcap_data;
    size_t      pcap_size;
    void       *ring_cpu[VALKYRIE_MAX_RING_BUFFERS];
    uint64_t    pkts_inj, bytes_inj;
    struct timespec start;
} sim_state_t;

static sim_state_t g_sim;

static uint64_t now_ns(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000000000ULL + (uint64_t)ts.tv_nsec;
}

/* Fold one packet's latency (modelled core clocks) into the BAR0 LAT_* block,
 * exactly as the RTL does in hardware. */
static void lat_account(sim_state_t *s, uint32_t cyc, uint64_t ts)
{
    pthread_mutex_lock(&s->lock);
    if (s->bar.lat_pkts == 0 || cyc < s->bar.lat_min) s->bar.lat_min = cyc;
    if (cyc > s->bar.lat_max) s->bar.lat_max = cyc;
    s->bar.lat_last   = cyc;
    s->bar.lat_sum_lo += cyc;
    if (s->bar.lat_sum_lo < cyc) s->bar.lat_sum_hi++;
    s->bar.lat_pkts++;
    s->bar.hw_timestamp = ts;
    pthread_mutex_unlock(&s->lock);
}

static int load_pcap(sim_state_t *s, const char *path)
{
    struct stat st;
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open"); return -1; }
    fstat(fd, &st);
    s->pcap_size = st.st_size;
    s->pcap_data = malloc(s->pcap_size);
    if (!s->pcap_data) { close(fd); return -1; }
    if (read(fd, s->pcap_data, s->pcap_size) < 0) {
        perror("read"); close(fd); return -1;
    }
    close(fd);
    printf("[SIM] PCAP: %s (%.2f MB)\n", path, s->pcap_size/1048576.0);
    return 0;
}

static void* dma_thread(void *arg)
{
    sim_state_t *s = (sim_state_t*)arg;
    size_t pos = 24;
    size_t woff[VALKYRIE_MAX_RING_BUFFERS] = {0};   /* per-ring write offset */
    uint32_t ring = 0;

    while (s->running && pos + 16 <= s->pcap_size) {
        uint32_t ts_sec, ts_nsec, ilen, olen;
        memcpy(&ts_sec,  s->pcap_data+pos,   4);
        memcpy(&ts_nsec, s->pcap_data+pos+4, 4);
        memcpy(&ilen,    s->pcap_data+pos+8, 4);
        memcpy(&olen,    s->pcap_data+pos+12,4);
        pos += 16;
        if (pos + ilen > s->pcap_size) break;
        uint8_t *pkt = s->pcap_data + pos;

        uint32_t cap = ilen < VALKYRIE_MAX_PACKET_SIZE
                     ? ilen : VALKYRIE_MAX_PACKET_SIZE;
        uint32_t need = VALKYRIE_PKT_HDR_SIZE + cap;

        if (s->nrings < 1) break;
        if (woff[ring] + need > s->bar.ring_size[ring])
            woff[ring] = 0;                        /* circular wrap */

        uint64_t t0 = now_ns();
        uint8_t *slot = (uint8_t*)s->ring_cpu[ring] + woff[ring];
        valkyrie_pkt_meta_t *m = (valkyrie_pkt_meta_t*)slot;
        m->timestamp_ns   = (uint64_t)ts_sec*1000000000ULL + ts_nsec;
        m->packet_length  = olen;
        m->captured_length= cap;
        m->port_id        = (uint16_t)s->bar.feed_port;
        m->flags          = PKT_FLAG_HW_TIMESTAMP;
        m->protocol       = 0x0800;
        memcpy(slot + VALKYRIE_PKT_HDR_SIZE, pkt, cap);
        uint64_t t1 = now_ns();

        /* Latency in modelled core clocks, so it is directly comparable with
         * the RTL's VALKYRIE_REG_LAT_* counters. */
        uint64_t cyc = (t1 - t0) * s->core_hz / 1000000000ULL;
        if (cyc == 0) cyc = 1;
        m->hw_latency_cycles = (uint32_t)cyc;
        lat_account(s, (uint32_t)cyc, m->timestamp_ns);

        woff[ring] += need;
        s->bar.bytes_written_lo += need;
        if (s->bar.bytes_written_lo < need) s->bar.bytes_written_hi++;
        s->bar.packet_count[ring]++;

        s->pkts_inj++; s->bytes_inj += ilen; pos += ilen;
        ring = (ring + 1) % (uint32_t)s->nrings;
        if (s->replay_rate > 0) {
            struct timespec ts = { .tv_nsec = 1000000000/s->replay_rate };
            nanosleep(&ts, NULL);
        }
    }
    printf("[SIM] Done: %llu pkts\n", (unsigned long long)s->pkts_inj);
    return NULL;
}

int main(int argc, char **argv)
{
    sim_state_t *s = &g_sim;
    memset(s, 0, sizeof(*s)); s->running = 1;
    pthread_mutex_init(&s->lock, NULL);
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i],"--pcap") && i+1<argc) s->pcap_file = argv[++i];
        else if (!strcmp(argv[i],"--rate") && i+1<argc) s->replay_rate = atoi(argv[++i]);
        else if (!strcmp(argv[i],"--loop")) s->loop = 1;
        else if (!strcmp(argv[i],"--verbose")) s->verbose = 1;
        else if (!strcmp(argv[i],"--core-hz") && i+1<argc)
            s->core_hz = strtoull(argv[++i], NULL, 0);
        else if (!strcmp(argv[i],"--help")) {
            printf("Usage: %s --pcap <file> [--rate Hz] [--core-hz Hz] "
                   "[--loop] [--verbose]\n", argv[0]);
            return 0;
        }
    }
    if (s->core_hz == 0) s->core_hz = 250000000ULL;   /* 250 MHz core */
    s->nrings = VALKYRIE_RING_BUF_COUNT;
    printf("=== Valkyrie FPGA DMA Simulator ===\n");
    for (int i = 0; i < VALKYRIE_RING_BUF_COUNT; i++) {
        s->ring_cpu[i] = malloc(VALKYRIE_RING_BUF_SIZE);
        if (!s->ring_cpu[i]) { perror("malloc"); return 1; }
        memset(s->ring_cpu[i], 0, VALKYRIE_RING_BUF_SIZE);
        s->bar.ring_base[i] = (uint64_t)(uintptr_t)s->ring_cpu[i];
        s->bar.ring_size[i] = VALKYRIE_RING_BUF_SIZE;
        printf("  Ring %d: %p\n", i, s->ring_cpu[i]);
    }
    s->bar.dma_control = 1; s->bar.feed_port = 14317;
    if (!s->pcap_file) s->pcap_file = "pcap_data/db-samples.pcap";
    if (access(s->pcap_file, R_OK) == 0) load_pcap(s, s->pcap_file);
    else printf("[SIM] No PCAP, idle\n");
    clock_gettime(CLOCK_MONOTONIC, &s->start);
    pthread_create(&s->dma_thread, NULL, dma_thread, s);

    /* Let DMA thread run to completion unless stopped via signal */
    pthread_join(s->dma_thread, NULL);
    s->running = 0;
    for (int i = 0; i < VALKYRIE_RING_BUF_COUNT; i++)
        free(s->ring_cpu[i]);
    free(s->pcap_data);
    printf("=== Done: %llu pkts, %llu bytes ===\n",
           (unsigned long long)s->pkts_inj, (unsigned long long)s->bytes_inj);

    if (s->bar.lat_pkts) {
        uint64_t sum = ((uint64_t)s->bar.lat_sum_hi << 32) | s->bar.lat_sum_lo;
        double cyc_ns = 1e9 / (double)s->core_hz;
        printf("--- Capture latency, ingress -> ring (BAR0 LAT_*) ---\n");
        printf("  core clock   : %.0f MHz (%.2f ns/cycle)\n",
               s->core_hz/1e6, cyc_ns);
        printf("  samples      : %u\n", s->bar.lat_pkts);
        printf("  last         : %u cycles (%.0f ns)\n",
               s->bar.lat_last, s->bar.lat_last*cyc_ns);
        printf("  min / max    : %u / %u cycles (%.0f / %.0f ns)\n",
               s->bar.lat_min, s->bar.lat_max,
               s->bar.lat_min*cyc_ns, s->bar.lat_max*cyc_ns);
        printf("  mean         : %.1f cycles (%.0f ns)\n",
               (double)sum/s->bar.lat_pkts, (double)sum/s->bar.lat_pkts*cyc_ns);
        printf("  last arrival : %llu ns (BAR0 hw_timestamp)\n",
               (unsigned long long)s->bar.hw_timestamp);
        printf("  ring bytes   : %llu (incl. %d-byte headers)\n",
               (((uint64_t)s->bar.bytes_written_hi << 32) | s->bar.bytes_written_lo),
               VALKYRIE_PKT_HDR_SIZE);
    }
    return 0;
}