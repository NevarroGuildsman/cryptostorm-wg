#!/usr/bin/env bash
# shellcheck disable=SC2154  # variables come from config.sh / net.sh
# Kill switch. Default-deny egress on every interface except loopback and the
# WireGuard interface, plus explicit allowances for the active endpoint,
# LOCAL_SUBNETS, and a short probe window used for ranking and resolution.
#
# filter table layout:
#   OUTPUT         lo, established/related, wg0, LOCAL_SUBNETS, then the two
#                  chains below; policy DROP. FORWARD policy DROP.
#   CSWG_ENDPOINT  UDP to the endpoint of the tunnel being brought up
#   CSWG_PROBE     ICMP echo and DNS while ranking servers or resolving names
#
# Interface matches use "! -o wg0" rather than a hard-coded uplink name.

IPT=""
IP6T=""

# firewall_detect
# Picks a working iptables front end. Alpine ships both nf_tables and legacy
# variants; older host kernels only accept legacy. wg-quick calls plain
# `iptables`, so whichever variant works is linked over it.
firewall_detect() {
  local cand
  for cand in iptables iptables-nft iptables-legacy; do
    command -v "$cand" >/dev/null 2>&1 || continue
    if "$cand" -w 5 -L OUTPUT -n >/dev/null 2>&1; then
      IPT="$cand"
      break
    fi
  done
  [[ -n $IPT ]] || die 20 "no working iptables backend; the container needs cap_add NET_ADMIN"

  if [[ $IPT != "iptables" ]]; then
    log_warn "iptables default backend unusable on this kernel; using ${IPT}"
    local tool src dst
    for tool in iptables iptables-restore iptables-save; do
      src=$(command -v "${tool/iptables/$IPT}" 2>/dev/null || true)
      dst=$(command -v "$tool" 2>/dev/null || true)
      [[ -n $src && -n $dst ]] && ln -sf "$src" "$dst" 2>/dev/null
    done
  fi

  local v6="${IPT/iptables/ip6tables}"
  if command -v "$v6" >/dev/null 2>&1 && "$v6" -w 5 -L OUTPUT -n >/dev/null 2>&1; then
    IP6T="$v6"
  fi
  log_info "firewall backend: ${IPT}${IP6T:+ and $IP6T}"
}

firewall_init() {
  firewall_detect
  local chain subnet
  local -a subnets

  for chain in CSWG_ENDPOINT CSWG_PROBE; do
    $IPT -w 5 -N "$chain" 2>/dev/null || $IPT -w 5 -F "$chain"
  done

  $IPT -w 5 -F OUTPUT
  $IPT -w 5 -A OUTPUT -o lo -j ACCEPT
  $IPT -w 5 -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
  $IPT -w 5 -A OUTPUT -o "$WG_IFACE" -j ACCEPT
  $IPT -w 5 -A OUTPUT -j CSWG_ENDPOINT
  $IPT -w 5 -A OUTPUT -j CSWG_PROBE

  if [[ -n $LOCAL_SUBNETS ]]; then
    IFS=',' read -r -a subnets <<< "$LOCAL_SUBNETS"
    for subnet in "${subnets[@]}"; do
      subnet="${subnet// /}"
      [[ -n $subnet ]] || continue
      $IPT -w 5 -A OUTPUT -d "$subnet" -j ACCEPT
      # Keep the LAN reachable through the uplink once the tunnel owns the
      # default route; wg-quick's policy routing honours main-table routes.
      # Directly connected subnets already have a route and are left alone.
      if [[ -z $(ip route show "$subnet" 2>/dev/null) ]]; then
        ip route replace "$subnet" via "$NET_GW" dev "$NET_DEV" \
          || log_warn "could not add uplink route for ${subnet}"
      fi
    done
  fi

  $IPT -w 5 -P OUTPUT DROP
  $IPT -w 5 -P FORWARD DROP

  if [[ -n $IP6T ]]; then
    $IP6T -w 5 -F OUTPUT
    $IP6T -w 5 -A OUTPUT -o lo -j ACCEPT
    $IP6T -w 5 -A OUTPUT -o "$WG_IFACE" -j ACCEPT
    $IP6T -w 5 -P OUTPUT DROP
    $IP6T -w 5 -P FORWARD DROP
  else
    log_warn "ip6tables unavailable; relying on net.ipv6.conf.all.disable_ipv6=1 from compose"
  fi

  log_info "kill switch active: egress only via ${WG_IFACE}${LOCAL_SUBNETS:+ and LAN ${LOCAL_SUBNETS}}"
}

# firewall_allow_endpoint <ip> <port>
firewall_allow_endpoint() {
  $IPT -w 5 -A CSWG_ENDPOINT ! -o "$WG_IFACE" -p udp -d "$1" --dport "$2" -j ACCEPT
}

firewall_revoke_endpoint() {
  $IPT -w 5 -F CSWG_ENDPOINT
}

# Probe window: ICMP echo for latency ranking, DNS for resolving endpoints
# through the original resolvers. Opened for seconds at a time only while
# the tunnel is down.
firewall_allow_probe() {
  $IPT -w 5 -A CSWG_PROBE ! -o "$WG_IFACE" -p icmp --icmp-type echo-request -j ACCEPT
  $IPT -w 5 -A CSWG_PROBE ! -o "$WG_IFACE" -p udp --dport 53 -j ACCEPT
  $IPT -w 5 -A CSWG_PROBE ! -o "$WG_IFACE" -p tcp --dport 53 -j ACCEPT
}

firewall_revoke_probe() {
  $IPT -w 5 -F CSWG_PROBE
}
