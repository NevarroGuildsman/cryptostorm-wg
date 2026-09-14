#!/usr/bin/env bash
# shellcheck disable=SC2154  # variables come from config.sh / the environment
# Network plumbing shared by the firewall, server ranking and tunnel code:
# the resolvers and default route Docker gave the container, hostname
# resolution that bypasses the tunnel DNS, and /etc/resolv.conf handling.

WG_IFACE="${WG_IFACE:-wg0}"
NET_STATE_DIR="/run/cryptostorm"
NET_RESOLV_BACKUP="${NET_STATE_DIR}/resolv.conf.orig"
declare -a NET_ORIG_NS=()
NET_GW=""
NET_DEV=""

# net_init
# Records the original resolvers and default route before anything changes.
# Called once, after config_load and before firewall_init.
net_init() {
  mkdir -p "$NET_STATE_DIR"
  [[ -f $NET_RESOLV_BACKUP ]] || cp /etc/resolv.conf "$NET_RESOLV_BACKUP"
  mapfile -t NET_ORIG_NS < <(awk '/^nameserver/ {print $2}' "$NET_RESOLV_BACKUP")

  local kw1 kw2 kw3
  read -r kw1 kw2 NET_GW kw3 NET_DEV _ < <(ip -4 route show default 2>/dev/null | head -1)
  [[ $kw1 == default && $kw2 == via && $kw3 == dev && -n $NET_GW && -n $NET_DEV ]] \
    || die 20 "no IPv4 default route found; is the container attached to a network?"
  log_info "uplink ${NET_DEV} via ${NET_GW}; original resolvers: ${NET_ORIG_NS[*]:-<none>}"
}

# net_resolve <hostname-or-ip>
# Prints the first IPv4 address. Asks the original resolvers directly so it
# keeps working after /etc/resolv.conf has been pointed at the tunnel DNS and
# while the tunnel is down. Caller must open the probe window first.
net_resolve() {
  local host="$1" ns ip
  if [[ $host =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$host"
    return 0
  fi
  for ns in "${NET_ORIG_NS[@]}"; do
    ip=$(dig +short +time=3 +tries=2 "@${ns}" A "$host" 2>/dev/null \
         | grep -m1 -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || true)
    [[ -n $ip ]] && { echo "$ip"; return 0; }
  done
  ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}' || true)
  [[ -n $ip ]] && { echo "$ip"; return 0; }
  return 1
}

# net_use_tunnel_dns
# Points /etc/resolv.conf at DNS (comma list). Every process in this network
# namespace, including containers that join it, then resolves through the
# tunnel instead of Docker's embedded resolver, which would otherwise forward
# queries from the host outside the tunnel.
net_use_tunnel_dns() {
  local -a list
  local n out=""
  IFS=',' read -r -a list <<< "$DNS"
  for n in "${list[@]}"; do
    n="${n// /}"
    [[ -n $n ]] && out+="nameserver ${n}"$'\n'
  done
  if printf '%s' "$out" > /etc/resolv.conf 2>/dev/null; then
    log_info "resolv.conf now uses tunnel DNS ${DNS}"
  else
    log_warn "could not write /etc/resolv.conf; DNS may bypass the tunnel"
  fi
}

net_restore_dns() {
  [[ -f $NET_RESOLV_BACKUP ]] && cat "$NET_RESOLV_BACKUP" > /etc/resolv.conf 2>/dev/null
  return 0
}

# _sleep <seconds>
# Interruptible sleep so TERM/INT traps run promptly instead of after the nap.
_sleep() {
  sleep "$1" &
  wait $! || true
}
