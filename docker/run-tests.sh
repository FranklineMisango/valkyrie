#!/bin/sh
# Valkyrie portable Linux test suite.
#
#   docker run --rm -v "$PWD":/w -w /w valkyrie-test sh docker/run-tests.sh
#
# Every step is reported; the script exits nonzero if any step failed, so it
# can be used directly as a CI gate. All steps are expected to PASS; the
# defects this gate originally documented are fixed (see TESTING.md).
set -u

rc=0

run() {
    name="$1"
    shift
    printf '\n=== %s ===\n' "$name"
    "$@"
    st=$?
    if [ "$st" -eq 0 ]; then
        printf '  [PASS] %s\n' "$name"
    else
        printf '  [FAIL rc=%d] %s\n' "$st" "$name"
        rc=1
    fi
    return 0
}

printf 'host kernel : %s\n'   "$(uname -r)"
printf 'iverilog    : %s\n'   "$(iverilog -V 2>&1 | head -1)"
printf 'verilator   : %s\n'   "$(verilator --version 2>&1 | head -1)"
printf 'gcc         : %s\n'   "$(gcc --version 2>&1 | head -1)"

# /w is the host tree bind-mounted in, so compiled artifacts from the host
# (e.g. a macOS Icarus build) are visible here. A stale .vvp makes make skip
# recompiling, and then this machine's vvp cannot load the VPI module paths
# baked into it -- which shows up as the baffling
#   "System task/function $display() is not defined by any module"
# rather than as a build error. Force a clean rebuild so the gate is hermetic.
rm -f fpga/tb/*.vvp fpga/tb/*.vcd fpga/tb/stim.axis

run "RTL directed conformance"      make -C fpga/tb run
run "Verilator lint"                make -C fpga/tb lint
run "RTL PCAP replay (2000 pkts)"   make -C fpga/tb replay LIMIT=2000
run "RTL capture latency"           make -C fpga/tb latency LIMIT=2000
run "user-space tools build"        make tools

if [ -f pcap_data/db-samples.pcap ]; then
    run "pcap_analyzer on real capture" \
        sh -c './tools/pcap_analyzer pcap_data/db-samples.pcap | head -25'
else
    printf '\n=== pcap_analyzer: SKIP (pcap_data/db-samples.pcap not mounted) ===\n'
fi

printf '\n=========================================\n'
if [ "$rc" -eq 0 ]; then
    printf 'ALL LINUX GATES PASSED\n'
else
    printf 'LINUX GATES FAILED\n'
fi
printf '=========================================\n'
exit "$rc"
