#!/bin/sh
# Verdict on a Z boot log of the `-Dzicro-only` lane: every zicro_session_* KTEST
# must be present AND pass. A missing gate is a failure (a boot that died early, or a
# build without -Dzicro-src, must never read as green).
#
#   zig build run-x86_64-kvm -Dzicro-src=<Zicro> -Dzart-src= -Dzicro-only 2>&1 | tee boot.log
#   scripts/check-z-session.sh boot.log
set -eu
log=${1:?usage: check-z-session.sh <boot.log>}
fail=0
for gate in first_frame key pointer unknown_ignored resize close; do
    line=$(grep -a "zicro_session_$gate" "$log" | tail -n 1 || true)
    if [ -z "$line" ]; then
        echo "MISSING  zicro_session_$gate"
        fail=1
    elif echo "$line" | grep -aq 'PASS'; then
        echo "PASS     zicro_session_$gate"
    else
        echo "FAIL     zicro_session_$gate: $line"
        fail=1
    fi
done
exit $fail
