/**
 * pcap_analyzer.c - Valkyrie PCAP Analyzer
 * Build: gcc -O2 -Wall -o pcap_analyzer pcap_analyzer.c -lpthread
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#define ET 0x0800
#define PU 17

typedef struct { uint32_t m; uint16_t vm,vn; int32_t tz; uint32_t sf,sl,nw; } ph_t;
typedef struct { uint32_t ts,tn,il,ol; } pp_t;

static const char *in(uint8_t t) {
 switch(t) {
  case 'S': return "SysEvent"; case 'R': return "StockDir";
  case 'H': return "TradingAct"; case 'A': return "AddOrder";
  case 'F': return "AddOrderMPID"; case 'E': return "Executed";
  case 'C': return "ExecPrice"; case 'X': return "Cancel";
  case 'D': return "Delete"; case 'U': return "Replace";
  case 'P': return "Trade"; case 'Q': return "CrossTrade";
  case 'B': return "BrokenTrade"; case 'I': return "NOII";
  default: return "Other";
 }
}

static uint64_t ns(void) {
 struct timespec ts;
 clock_gettime(CLOCK_MONOTONIC, &ts);
 return (uint64_t)ts.tv_sec*1000000000ULL+ts.tv_nsec;
}

/* ─── Per-packet latency histogram ───
 * `--latency` used to print a single wall-clock total for the whole file,
 * which is a throughput number, not a latency: no distribution, no tail.
 * We now time each packet's parse and report the percentiles an HFT strategy
 * actually cares about. Packets are timed in batches of 64 so the two
 * clock_gettime() calls are amortised to well under a nanosecond each.
 */
#define LAT_BATCH 64
#define LAT_BUCKETS 262144          /* 1 ns buckets: 0..262 us + overflow */

static uint32_t lat_hist[LAT_BUCKETS];
static uint64_t lat_samples = 0, lat_sum = 0, lat_min = 0, lat_max = 0;

static void lat_record(uint64_t v) {
 if (v >= LAT_BUCKETS) v = LAT_BUCKETS-1;      /* overflow bucket */
 lat_hist[v]++;
 lat_samples++;
 lat_sum += v;
 if (lat_min == 0 || v < lat_min) lat_min = v;
 if (v > lat_max) lat_max = v;
}

static uint64_t lat_pct(double q) {
 uint64_t target = (uint64_t)(q*(double)lat_samples + 0.5), cum = 0;
 if (target == 0) target = 1;
 for (int i = 0; i < LAT_BUCKETS; i++) {
  cum += lat_hist[i];
  if (cum >= target) return (uint64_t)i;
 }
 return (uint64_t)(LAT_BUCKETS-1);
}

int main(int argc, char **argv) {
 const char *path=NULL; int v=0,lt=0,st=0,fn=10;
 for (int i=1;i<argc;i++) {
  if (argv[i][0]!='-') { path=argv[i]; continue; }
  if (!strcmp(argv[i],"--validate")) { v=1; continue; }
  if (!strcmp(argv[i],"--latency")) { lt=1; st=1; continue; }
  if (!strcmp(argv[i],"--stats")) { st=1; continue; }
  if (!strncmp(argv[i],"--first=",8)) { fn=atoi(argv[i]+8); continue; }
  printf("Usage: %s [pcap] [--validate] [--latency] [--stats] [--first=N]\n",argv[0]);
  if (!strcmp(argv[i],"--help")) return 0;
 }
 if (!path) path="pcap_data/db-samples.pcap";
 struct stat sb; int fd=open(path,O_RDONLY);
 if (fd<0) { perror("open"); return 1; }
 fstat(fd,&sb); long fsz=sb.st_size;
 uint8_t *buf=malloc(fsz);
 if (!buf) { close(fd); return 1; }
 read(fd,buf,fsz); close(fd);
 ph_t *p=(ph_t*)buf;
 printf("=== Valkyrie PCAP Analyzer ===\n");
 printf("PCAP: 0x%08x v=%u.%u sl=%u\n",p->m,p->vm,p->vn,p->sl);
 printf("File: %ldB (%.2fMB)\n\n",fsz,fsz/1048576.0);
 size_t pos=sizeof(ph_t);
 uint64_t tot=0,udp=0,itch=0,bytes=0,large=0,small=(uint64_t)-1;
 uint64_t pcnt[256]={0}; uint16_t ports[256]; int np=0;
 uint64_t mc[256]={0}; double fts=0,lts=0;
 uint64_t t0=lt?ns():0;
 uint64_t pt0=0; int lat_n=0;
 printf("--- First %d ITCH ---\n",fn);
 while(pos+sizeof(pp_t)<=(size_t)fsz) {
  pp_t *ph=(pp_t*)(buf+pos); tot++;
  size_t nxt=pos+sizeof(pp_t)+ph->il;
  if (nxt>(size_t)fsz) break;
  if (lt && lat_n==0) pt0=ns();
  bytes+=ph->il;
  if (ph->ol>large) large=ph->ol;
  if (ph->il<small) small=ph->il;
  if (tot==1) fts=ph->ts+ph->tn/1e9;
  lts=ph->ts+ph->tn/1e9;
  if (ph->il>=42) {
   uint8_t *pkt=buf+pos+sizeof(pp_t);
   if (((pkt[12]<<8)|pkt[13])==ET) {
    uint8_t *ip=pkt+14;
    int ihl=(ip[0]&0x0f)*4;
    if (ip[9]==PU) {
     udp++;
     uint8_t *u=ip+ihl;
     uint16_t sp=(u[0]<<8)|u[1];
     uint16_t ulen=(u[4]<<8)|u[5];
     size_t pl=ulen>8?ulen-8:0;
     int pi=-1;
     for (int k=0;k<np;k++) if (ports[k]==sp) { pi=k; break; }
     if (pi<0&&np<256) { pi=np; ports[np++]=sp; }
     pcnt[pi]++;
     if (pl>0) {
      uint8_t *pay=u+8;
      uint8_t mr=pay[0]; mc[mr]++;
      if (mr>='A') {
       itch++;
       if (st&&itch<=(uint64_t)fn) {
        printf("[%llu]@%u.%09u UDP %u '%c' %s %zuB\n",
               (unsigned long long)tot,ph->ts,ph->tn,sp,
               (mr>=32&&mr<127)?mr:'?',in(mr),pl);
        printf(" "); for (size_t i=0;i<pl&&i<48;i++) printf("%02x",pay[i]);
        printf("\n");
       }
       if (v&&pl>=12) {
        uint32_t seq; memcpy(&seq,pay+2,4);
        if (seq>1000000000) printf(" WARN: seq=%u\n",seq);
       }
      }
     }
    }
   }
  }
  if (lt) {
   if (++lat_n == LAT_BATCH) { lat_record((ns()-pt0)/LAT_BATCH); lat_n=0; }
  }
  pos=nxt;
 }
 if (lt && lat_n) lat_record((ns()-pt0)/lat_n);     /* partial batch */
 uint64_t t1=lt?ns():0;
 double dur=lts-fts;
 printf("\n=== Summary ===\n");
 printf("Tot:%llu|UDP:%llu(%.1f%%)|ITCH:%llu\n",
        (unsigned long long)tot,(unsigned long long)udp,
        tot?100.0*udp/tot:0,(unsigned long long)itch);
 printf("Bytes:%llu(%.2fMB)|Pkt:min=%llu max=%llu avg=%.0f\n",
        (unsigned long long)bytes,bytes/1048576.0,
        (unsigned long long)small,(unsigned long long)large,
        tot?(double)bytes/tot:0);
 if (dur>0) printf("Dur:%.3fs|Rate:%.2fMbps\n",dur,bytes*8.0/dur/1e6);
 if (lt&&t1>t0) {
  printf("\n--- Latency (per packet, averaged over %d-packet windows) ---\n",LAT_BATCH);
  printf("Samples : %llu windows over %llu packets\n",
         (unsigned long long)lat_samples,(unsigned long long)tot);
  if (lat_samples) {
   printf("Latency : min=%llu p50=%llu p90=%llu p99=%llu max=%llu ns\n",
          (unsigned long long)lat_min,(unsigned long long)lat_pct(0.50),
          (unsigned long long)lat_pct(0.90),(unsigned long long)lat_pct(0.99),
          (unsigned long long)lat_max);
   printf("Mean    : %.1f ns/packet\n",(double)lat_sum/(double)lat_samples);
  }
  printf("Throughput: %.3fms total, %.0f packets/s\n",
         (t1-t0)/1e6,tot/((t1-t0)/1e9));
 }
 if (st) {
  printf("\n--- Ports ---\n");
  for (int i=0;i<np-1;i++) for (int j=0;j<np-i-1;j++)
   if (pcnt[j]<pcnt[j+1]) {
    uint64_t t=pcnt[j];pcnt[j]=pcnt[j+1];pcnt[j+1]=t;
    uint16_t p=ports[j];ports[j]=ports[j+1];ports[j+1]=p;
   }
  for (int i=0;i<np&&i<10;i++)
   printf("Port %5u: %llu(%.1f%%)\n",ports[i],(unsigned long long)pcnt[i],100.0*pcnt[i]/tot);
  printf("\n--- ITCH ---\n");
  for (int i=0;i<256;i++) if (mc[i]>0)
   printf("'%c'0x%02x %-12s: %llu\n",(i>=32&&i<127)?i:'?',i,in(i),(unsigned long long)mc[i]);
 }
 free(buf); return 0;
}