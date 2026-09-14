#!/usr/bin/env bash
# shellcheck disable=SC2154  # variables come from config.sh / net.sh
# Kill switch. Default-deny egress on every interface except loopback and the
# WireGuard interface, plus narrowly scoped allowances for the active
# endpoint, LOCAL_SUBNETS, and a short probe window used for resolution and
# latency ranking.
#
# filter table layout (IPv4):
#   OUTPUT
#     -d 127.0.0.11         -> CSWG_PROBE, then DROP   Docker's embedded resolver
#     -o lo                 ACCEPT
#     -o wg0                ACCEPT
#     ! -o wg0 established/related, REPLY direction only   answers to inbound
#                                                          connections (LAN to
#                                                          published ports)
#     -> CSWG_ENDPOINT      UDP to the endpoint being dialled
#     -> CSWG_PROBE         DNS to the original resolvers and ICMP echo to the
#                           candidate endpoints, only while the tunnel is down
#     -d LOCAL_SUBNETS      ACCEPT
#     policy DROP; FORWARD policy DROP
#
# Matching established traffic only in the reply direction means a flow that
# a process opened during the probe window cannot continue once the window
# closes: its later packets are in the original direction and are dropped.
#
# Every rule change that protects the tunnel is fatal on failure. A gateway
# whose kill switch is half-installed must not keep running.

IPT=""
IP6T=""

# _ipt <args...>   run the chosen backend; exit the container on failure
_ipt() {
  $IPT -w 5 "$@" || die 21 "firewall change failed: ${IPT} $*"
}

_ip6t() {
  $IP6T -w 5 "$@" || die 21 "firewall change failed: ${IP6T} $*"
}

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
      [[ -n $src && -n $dst ]] || continue
      ln -sf "$src" "$dst" || die 20 "could not link ${dst} to ${src} for wg-quick"
    done
  fi

  local v6="${IPT/iptables/ip6tables}"
  if command -v "$v6" >/dev/null 2>&1 && "$v6" -w 5 -L OUTPUT -n >/dev/null 2>&1; then
    IP6T="$v6"
  fi
  log_info "firewall backend: ${IPT}${IP6T:+ and $IP6T}"
}

# firewall_ipv6_guard
# IPv6 must fail closed. Either ip6tables installs a default-deny policy, or
# the kernel has IPv6 disabled for this namespace. Anything else is fatal.
firewall_ipv6_guard() {
  if [[ -n $IP6T ]]; then
    _ip6t -F OUTPUT
    _ip6t -A OUTPUT -o lo -j ACCEPT
    _ip6t -A OUTPUT -o "$WG_IFACE" -j ACCEPT
    _ip6t -P OUTPUT DROP
    _ip6t -P FORWARD DROP
    log_info "IPv6 egress denied via ${IP6T}"
    return 0
  fi

  local knob=/proc/sys/net/ipv6/conf/all/disable_ipv6
  if [[ ! -e $knob ]]; then
    log_info "kernel has no IPv6 in this namespace"
    return 0
  fi
  # Docker normally mounts /proc/sys read-only; this only succeeds when the
  # runtime allows it, so it is a best-effort attempt before verifying.
  sysctl -qw net.ipv6.conf.all.disable_ipv6=1 >/dev/null 2>&1 || true
  if [[ $(cat "$knob") == 1 ]]; then
    log_info "IPv6 disabled by sysctl (ip6tables unavailable)"
    return 0
  fi
  die 22 "ip6tables is unusable and IPv6 is enabled: traffic could leave outside the tunnel. Add sysctl net.ipv6.conf.all.disable_ipv6=1 to the container."
}

firewall_init() {
  firewall_detect
  local chain subnet
  local -a subnets

  for chain in CSWG_ENDPOINT CSWG_PROBE; do
    $IPT -w 5 -N "$chain" 2>/dev/null || _ipt -F "$chain"
  done

  _ipt -F OUTPUT
  # Docker's embedded resolver forwards queries from the host, outside the
  # tunnel. Only the probe window may reach it.
  _ipt -A OUTPUT -d 127.0.0.11 -j CSWG_PROBE
  _ipt -A OUTPUT -d 127.0.0.11 -j DROP
  _ipt -A OUTPUT -o lo -j ACCEPT
  _ipt -A OUTPUT -o "$WG_IFACE" -j ACCEPT
  _ipt -A OUTPUT ! -o "$WG_IFACE" -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT
  _ipt -A OUTPUT -j CSWG_ENDPOINT
  _ipt -A OUTPUT -j CSWG_PROBE

  if [[ -n $LOCAL_SUBNETS ]]; then
    IFS=',' read -r -a subnets <<< "$LOCAL_SUBNETS"
    for subnet in "${subnets[@]}"; do
      subnet="${subnet// /}"
      [[ -n $subnet ]] || continue
      _ipt -A OUTPUT -d "$subnet" -j ACCEPT
      # Keep the LAN reachable through the uplink once the tunnel owns the
      # default route; wg-quick's policy routing honours main-table routes.
      # Directly connected subnets already have a route and are left alone.
      if [[ -z $(ip route show "$subnet" 2>/dev/null) ]]; then
        ip route replace "$subnet" via "$NET_GW" dev "$NET_DEV" \
          || die 21 "could not add uplink route for ${subnet}"
      fi
    done
  fi

  _ipt -P OUTPUT DROP
  _ipt -P FORWARD DROP
  firewall_ipv6_guard

  log_info "kill switch active: egress only via ${WG_IFACE}${LOCAL_SUBNETS:+ and LAN ${LOCAL_SUBNETS}}"
}

# firewall_allow_endpoint <ip> <port>
# Returns non-zero on failure so the session can abort without a tunnel.
firewall_allow_endpoint() {
  $IPT -w 5 -A CSWG_ENDPOINT ! -o "$WG_IFACE" -p udp -d "$1" --dport "$2" -j ACCEPT
}

firewall_revoke_endpoint() {
  _ipt -F CSWG_ENDPOINT
}

# Probe window. Opened for seconds at a time only while the tunnel is down.
#
# firewall_allow_dns
#   DNS to the resolvers Docker configured: the embedded resolver on
#   loopback (its port is rewritten by Docker's NAT before filtering, so the
#   match is by address) and any non-loopback resolver on port 53.
firewall_allow_dns() {
  local ns
  for ns in "${NET_ORIG_NS[@]}"; do
    if [[ $ns == 127.* ]]; then
      $IPT -w 5 -A CSWG_PROBE -o lo -d "$ns" -j ACCEPT || return 1
    else
      $IPT -w 5 -A CSWG_PROBE ! -o "$WG_IFACE" -d "$ns" -p udp --dport 53 -j ACCEPT || return 1
      $IPT -w 5 -A CSWG_PROBE ! -o "$WG_IFACE" -d "$ns" -p tcp --dport 53 -j ACCEPT || return 1
    fi
  done
}

# firewall_allow_icmp <ip...>
#   ICMP echo requests to the listed addresses only.
firewall_allow_icmp() {
  local ip
  for ip in "$@"; do
    $IPT -w 5 -A CSWG_PROBE ! -o "$WG_IFACE" -p icmp --icmp-type echo-request -d "$ip" -j ACCEPT || return 1
  done
}

# firewall_revoke_probe
#   Fatal on failure: a probe window that cannot be closed is a leak.
firewall_revoke_probe() {
  _ipt -F CSWG_PROBE
}
