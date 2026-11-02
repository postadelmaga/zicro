#!/bin/sh
# Verdict on a Z boot log of the `-Dzicro-only` lane: every gate below must be
# present AND pass, and the boot must end with the KTEST summary. A missing gate is a
# failure (a boot that died early, or a build without -Dzicro-src, never reads as
# green). Failures are explained with the boot's own diagnostic lines, which name who
# is at fault: TIMEOUT / PROTOCOL (zicro-k lines), the client's or host's exit verdict.
#
#   zig build run-x86_64-kvm -Dzicro-src=<Zicro> -Dzart-src=<Zart> -Dzicro-only 2>&1 | tee boot.log
#   scripts/check-z-session.sh boot.log            # Zart's demo required (darwin_zart)
#   ZICRO_NO_ZART=1 scripts/check-z-session.sh boot.log   # only when built without Zart
set -eu
log=${1:?usage: check-z-session.sh <boot.log>}
gates="zicro_session_first_frame zicro_session_key zicro_session_pointer
zicro_session_unknown_ignored zicro_session_resize zicro_session_multi_resize
zicro_session_close
zicro_kh_handshake zicro_kh_rapid_configure zicro_kh_stray_cap
zicro_kh_close_mid_request zicro_kh_no_leak zicro_kh_server_gone
zicro_host_bad_requests zicro_host_disconnect"
[ "${ZICRO_NO_ZART:-0}" = 1 ] || gates="$gates darwin_zart"
fail=0
for gate in $gates; do
    line=$(grep -a "KTEST $gate " "$log" | tail -n 1 || true)
    if [ -z "$line" ]; then
        echo "MISSING  $gate"
        fail=1
    elif echo "$line" | grep -aq 'PASS'; then
        echo "PASS     $gate"
    else
        echo "FAIL     $gate"
        fail=1
    fi
done
if ! grep -aq 'KTEST summary .* checks PASS' "$log"; then
    echo "FAIL     the boot did not reach a clean KTEST summary"
    fail=1
fi
if [ $fail -ne 0 ]; then
    echo "--- diagnostics (who is at fault) ---"
    grep -a -E 'zicro(-k)?: |KERNEL PANIC|watchdog' "$log" | tail -n 40 || true
fi
exit $fail
