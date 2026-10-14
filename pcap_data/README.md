# Test capture

`db-samples.pcap` is the **209 MB / 199 MiB** real NASDAQ exchange capture used
for the measured numbers in `README.md` and for the RTL replay and latency
gates:

- 585 171 packets, all UDP, nanosecond timestamps
- 437 113 ITCH protocol messages
- 38 multicast feed ports (14300–14441, ITCH 5.0)
- 598 s of market data at ~2.67 Mbps

```
sha256: 2f0306fa2fcea13808ce502fe3faa87c10f2e9cd07eb56b8391e7f1c15834c74
```

## Why it is not in this repository

GitHub rejects any file larger than 100 MB (`GH001`), so a 199 MB blob cannot be
pushed as an ordinary git object — nor should it be. A capture of this size is
derived test *data*, not source, and redistributing real exchange data is
usually governed by the feed provider's agreement. The path is gitignored, so
dropping the file in place keeps `git status` clean.

## Providing it

Any classic-PCAP file with nanosecond timestamps works; point the harness at it:

```bash
make rtl-replay  PCAP=/path/to/your-capture.pcap LIMIT=2000
make rtl-latency PCAP=/path/to/your-capture.pcap LIMIT=2000
make latency     PCAP=/path/to/your-capture.pcap
```

`LIMIT` is the number of packets fed to the RTL gates (default 2000), so a small
capture exercises the same code path — the checks are for losslessness and
byte-exactness, not for the specific packet count.

## Which gates need it

| Target | Needs the capture? |
|---|---|
| `make test` / `rtl-test` (directed conformance) | no — self-contained stimulus |
| `make rtl-lint` | no |
| `make rtl-replay` | **yes** |
| `make rtl-latency` | **yes** |
| `make latency` | **yes** |
| `make ci` | **yes** (it includes replay + latency) |

The replay and latency gates fail with an explicit message when the file is
absent rather than a confusing parse error.
