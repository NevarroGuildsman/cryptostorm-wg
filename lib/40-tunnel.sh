#!/usr/bin/env bash
# shellcheck disable=SC2154  # variables come from config.sh / the environment
# One tunnel session: resolve the server, write wg0.conf, bring it up, wait
# for a handshake, confirm connectivity, register port forwards, then hand
# off to the monitor.
#
# Returns 0 when the monitor asked for a timed rotation (RECONNECT expired),
# non-zero when the server failed at any stage. Always tears down on exit.

WG_IFACE="${WG_IFACE:-wg0}"
WG_CONF_DIR="${WG_CONF_DIR:-/etc/wireguard}"
TUNNEL_STATUS_FILE="/run/cryptostorm/status"

tunnel_session() {
  local name="$1" ip out rc

  if [[ $name == "auto" ]]; then
    name=$(servers_select) || { log_warn "auto: no server could be selected"; return 1; }
    log_info "auto: selected ${name}"
  fi
  servers_load "$name" || { log_error "server template for '${name}' vanished"; return 1; }

  firewall_allow_probe
  ip=$(net_resolve "$ENDPOINT_HOST") || true
  firewall_revoke_probe
  [[ -n $ip ]] || { log_warn "[${name}] cannot resolve ${ENDPOINT_HOST}"; return 1; }

  firewall_allow_endpoint "$ip" "$ENDPOINT_PORT"
  tunnel_write_config "$ip"
  log_info "[${name}] connecting to ${ENDPOINT_HOST} (${ip}:${ENDPOINT_PORT})"

  if ! out=$(wg-quick up "$WG_IFACE" 2>&1); then
    log_error "[${name}] wg-quick up failed: ${out//$'\n'/ | }"
    tunnel_teardown
    return 1
  fi
  if ! tunnel_wait_handshake 15; then
    log_warn "[${name}] no handshake within 15s"
    tunnel_teardown
    return 1
  fi
  if ! tunnel_wait_connectivity 3; then
    log_warn "[${name}] handshake completed but ${PING_TARGET} is unreachable through the tunnel"
    tunnel_teardown
    return 1
  fi

  log_info "[${name}] connected"
  tunnel_status_write "$name" "$ip"
  notify_send connected "connected to ${name}" "server=${name}" "endpoint=${ip}:${ENDPOINT_PORT}"
  portfwd_ensure "$name"

  monitor_loop "$name" && rc=0 || rc=$?
  tunnel_teardown
  return "$rc"
}

# tunnel_write_config <endpoint-ip>
# DNS is deliberately absent: wg-quick would need resolvconf, and resolv.conf
# is managed by net_use_tunnel_dns for the whole container lifetime instead.
tunnel_write_config() {
  local endpoint_ip="$1"
  mkdir -p "$WG_CONF_DIR"
  (
    umask 077
    cat > "${WG_CONF_DIR}/${WG_IFACE}.conf" <<CONF
[Interface]
PrivateKey = ${PRIVATE_KEY}
Address = ${ADDRESS}

[Peer]
PublicKey = ${PUBLIC_KEY}
PresharedKey = ${PSK}
Endpoint = ${endpoint_ip}:${ENDPOINT_PORT}
AllowedIPs = ${ALLOWED_IPS}
PersistentKeepalive = 25
CONF
  )
}

# tunnel_wait_handshake [seconds]
tunnel_wait_handshake() {
  local deadline=$(( $(date +%s) + ${1:-15} ))
  local last
  while (( $(date +%s) < deadline )); do
    last=$(wg show "$WG_IFACE" latest-handshakes 2>/dev/null | awk '{print $2}' | sort -n | tail -1)
    [[ -n $last && $last -gt 0 ]] && return 0
    sleep 0.5
  done
  return 1
}

# tunnel_wait_connectivity [attempts]
tunnel_wait_connectivity() {
  local n
  for (( n = 0; n < ${1:-3}; n++ )); do
    monitor_check && return 0
    sleep 2
  done
  return 1
}

tunnel_status_write() {
  printf 'server=%s\nendpoint=%s\nsince=%s\n' "$1" "$2" "$(date -Iseconds)" > "$TUNNEL_STATUS_FILE"
}

# tunnel_teardown
# Idempotent. Safe to call when nothing is up (also used by the signal trap).
tunnel_teardown() {
  if ip link show "$WG_IFACE" >/dev/null 2>&1; then
    wg-quick down "$WG_IFACE" >/dev/null 2>&1 || ip link del "$WG_IFACE" 2>/dev/null || true
  fi
  rm -f "${WG_CONF_DIR}/${WG_IFACE}.conf" "$TUNNEL_STATUS_FILE"
  [[ -n $IPT ]] && firewall_revoke_endpoint
  return 0
}
