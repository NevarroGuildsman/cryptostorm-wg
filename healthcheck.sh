#!/usr/bin/env bash
# Docker HEALTHCHECK. Healthy when wg0 exists and its most recent handshake is
# under three minutes old (WireGuard renews at least every two minutes with a
# 25 second keepalive). A status file written by the monitor can veto later.
set -u

WG_IFACE="${WG_IFACE:-wg0}"

last=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
[[ -n $last && $last -gt 0 ]] || exit 1

now=$(date +%s)
(( now - last < 180 )) || exit 1

exit 0
