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

typedef struct {
    uint32_t dma_control;      /* [0x00] */
    uint32_t dma_status;       /* [0x04] */
    uint32_t irq_control;      /* [0x08] */
    uint32_t irq_status;       /* [0x0C] */
    uint64_t ring_base[8];     /* [0x10] */
    uint32_t ring_size[8];     /* [0x50] */
    uint32_t packet_count[8];  /* [0x70] */
    uint32_t _pad[8];
    uint64_t hw_timestamp;     /* [0xA0] */
    uint32_t feed_port;        /* [0xA8] */
} sim_bar_t;

typedef struct {
    const char *pcap_file;
    int         replay_rate, loop, verbose, running;
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

static int load_pcap(sim_state_t *s, const char *path)
{
    struct stat st;
    int fd = open(path, O_RDONLY);
    if (fd < 0) { perror("open"); return -1; }
    fstat(fd, &st);
    s->pcap_size = st.st_size;
    s->pcap_data = malloc(s->pcap_size);
    if (!s->pcap_data) { close(fd); return -1; }
    read(fd, s->pcap_data, s->pcap_size); close(fd);
    printf("[SIM] PCAP: %s (%.2f MB)\n", path, s->pcap_size/1048576.0);
    return 0;
}

static void* dma_thread(void *arg)
{
    sim_state_t *s = (sim_state_t*)arg;
    size_t pos = 24;
    while (s->running && pos + 16 <= s->pcap_size) {
        uint32_t ts_sec, ts_nsec, ilen, olen;
        memcpy(&ts_sec,  s->pcap_data+pos,   4);
        memcpy(&ts_nsec, s->pcap_data+pos+4, 4);
        memcpy(&ilen,    s->pcap_data+pos+8, 4);
        memcpy(&olen,    s->pcap_data+pos+12,4);
        pos += 16;
        if (pos + ilen > s->pcap_size) break;
        uint8_t *pkt = s->pcap_data + pos;
        for (int r = 0; r < VALKYRIE_MAX_RING_BUFFERS; r++) {
            if (!s->ring_cpu[r]) continue;
            valkyrie_pkt_meta_t *m = (valkyrie_pkt_meta_t*)s->ring_cpu[r];
            m->timestamp_ns = (uint64_t)ts_sec*1000000000ULL + ts_nsec;
            m->packet_length = olen;
            m->captured_length = ilen < 2048 ? ilen : 2048;
            m->port_id = s->bar.feed_port;
            m->flags = PKT_FLAG_HW_TIMESTAMP;
            m->protocol = 0x0800;
            memcpy(m+1, pkt, m->captured_length);
            break;
        }
        s->pkts_inj++; s->bytes_inj += ilen; pos += ilen;
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
        else if (!strcmp(argv[i],"--help")) {
            printf("Usage: %s --pcap <file> [--rate Hz] [--loop] [--verbose]\n", argv[0]);
            return 0;
        }
    }
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
    return 0;
}