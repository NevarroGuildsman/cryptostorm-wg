#!/usr/bin/env bash
# shellcheck disable=SC2154  # variables come from config.sh / the environment
# One tunnel session: resolve the server, write wg0.conf, bring it up, wait
# for a handshake, register port forwards, then hand off to the monitor.
#
# Returns 0 when the monitor asked for a timed rotation (RECONNECT expired),
# non-zero when the server failed at any stage.

WG_IFACE="${WG_IFACE:-wg0}"
WG_CONF_DIR="${WG_CONF_DIR:-/etc/wireguard}"

tunnel_session() {
  local name="$1"
  if [[ $name == "auto" ]]; then
    name=$(servers_select) || { log_warn "no server could be selected"; return 1; }
  fi
  servers_load "$name" || { log_error "server template for '${name}' vanished"; return 1; }

  # TODO(tunnel): resolve ENDPOINT_HOST to an IP, firewall_allow_endpoint,
  # tunnel_write_config, wg-quick up, tunnel_wait_handshake, write DNS to
  # /etc/resolv.conf, portfwd_ensure "$name", monitor_loop "$name", then
  # tunnel_down and firewall_revoke_endpoint on the way out.
  log_error "tunnel_session: not implemented yet (would connect to ${name} at ${ENDPOINT})"
  return 1
}

# tunnel_write_config <endpoint-ip>
# Writes $WG_CONF_DIR/$WG_IFACE.conf with mode 0600. DNS is deliberately not
# written here: wg-quick would need resolvconf, so the session manages
# /etc/resolv.conf directly instead.
tunnel_write_config() {
  local endpoint_ip="$1"
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

tunnel_down() {
  wg-quick down "$WG_IFACE" >/dev/null 2>&1 || true
  rm -f "${WG_CONF_DIR}/${WG_IFACE}.conf"
}
