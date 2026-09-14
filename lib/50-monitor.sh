#!/usr/bin/env bash
# shellcheck disable=SC2154  # variables come from config.sh / the environment
# Connection monitor. Runs while a tunnel is up.

# monitor_check
# True when the peer has handshaken within three minutes and PING_TARGET
# answers through the WireGuard interface.
monitor_check() {
  local last now
  last=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
  [[ -n $last && $last -gt 0 ]] || return 1
  now=$(date +%s)
  (( now - last < 180 )) || return 1
  ping -4 -q -c 3 -W 2 -w 8 -I "$WG_IFACE" "$PING_TARGET" >/dev/null 2>&1
}

# monitor_loop <server-name>
#   Every CHECK_INTERVAL seconds run monitor_check. Three consecutive failures
#   mean the server is dead: return 1 so the session fails over. When
#   RECONNECT is non-zero and has elapsed, return 0 so the caller rotates to
#   the next server cleanly. Re-runs the port-forward registrar every
#   PORTFWD_REFRESH seconds in case a forward was removed server-side.
monitor_loop() {
  local name="$1"
  local strikes=0 deadline=0 now nap last_fwd
  (( RECONNECT > 0 )) && deadline=$(( $(date +%s) + RECONNECT ))
  last_fwd=$(date +%s)

  while :; do
    now=$(date +%s)
    if (( deadline > 0 && now >= deadline )); then
      log_info "[${name}] reconnect timer (${RECONNECT}s) expired; rotating to the next server"
      notify_send rotated "leaving ${name} after ${RECONNECT}s" "server=${name}"
      return 0
    fi

    if monitor_check; then
      strikes=0
    else
      strikes=$((strikes + 1))
      log_warn "[${name}] connectivity check failed (strike ${strikes}/3)"
      if (( strikes >= 3 )); then
        notify_send failover "${name} stopped responding; failing over" "server=${name}"
        return 1
      fi
      _sleep 10
      continue
    fi

    if (( now - last_fwd >= PORTFWD_REFRESH )); then
      portfwd_ensure "$name"
      last_fwd=$now
    fi

    nap=$CHECK_INTERVAL
    (( deadline > 0 && deadline - now < nap )) && nap=$(( deadline - now ))
    (( nap < 1 )) && nap=1
    _sleep "$nap"
  done
}
