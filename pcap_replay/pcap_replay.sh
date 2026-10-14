#!/bin/bash
# pcap_replay.sh — Valkyrie PCAP Replay Harness Wrapper
set -e

# Project root is one level up from this script
DIR="$(cd "$(dirname "$0")/.." && pwd)"
ANALYZER="$DIR/tools/pcap_analyzer"

if [ ! -x "$ANALYZER" ]; then
    echo "Building pcap_analyzer..."
    cd "$DIR"
    gcc -O2 -Wall -Iinclude -o tools/pcap_analyzer tools/pcap_analyzer.c -lpthread
fi

echo "=== Valkyrie PCAP Replay Harness ==="
cd "$DIR"
"$ANALYZER" "$@"