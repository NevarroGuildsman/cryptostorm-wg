#!/usr/bin/env bash
# Environment contract. Every variable the container reads is declared here.
#
#   PRIVATE_KEY    (required) WireGuard private key issued by CryptoStorm
#   PSK            (required) pre-shared key issued by CryptoStorm
#   ADDRESS        (required) tunnel address, e.g. 10.10.17.119/32
#   SERVER         (default: auto) ordered, '+'-joined list of server names,
#                  e.g. newyork+dc+chicago. The entry 'auto' picks the lowest
#                  latency server among CANDIDATES each time it comes around.
#                  A legacy 'cs-' prefix on names is accepted and stripped.
#   CANDIDATES     (default: every bundled server) comma list restricting what
#                  'auto' may choose, e.g. newyork,dc,chicago
#   RECONNECT      (default: 0) seconds before rotating to the next SERVER
#                  entry while healthy. 0 disables timed rotation.
#   ALLOWED_IPS    (default: 0.0.0.0/0) WireGuard AllowedIPs for the peer
#   LOCAL_SUBNETS  (default: none) comma list of LAN subnets that stay
#                  reachable outside the tunnel, e.g. 192.168.50.0/24
#   DNS            (default: 10.31.33.8) resolver used while connected
#   FORWARD_PORTS  (default: none) comma list of ports to register on every
#                  server we connect to, e.g. 46805,48979 (30000-65535)
#   NOTIFY_URL     (default: none) webhook that receives JSON event payloads
#   PING_TARGET    (default: 1.1.1.1) address used for connectivity checks
#   CHECK_INTERVAL (default: 120) seconds between connectivity checks

# shellcheck disable=SC2034
declare -a SERVERS=()
declare -a CANDIDATE_LIST=()
declare -a FORWARD_PORT_LIST=()

config_load() {
  : "${SERVER:=auto}"
  : "${CANDIDATES:=}"
  : "${RECONNECT:=0}"
  : "${ALLOWED_IPS:=0.0.0.0/0}"
  : "${LOCAL_SUBNETS:=}"
  : "${DNS:=10.31.33.8}"
  : "${FORWARD_PORTS:=}"
  : "${NOTIFY_URL:=}"
  : "${PING_TARGET:=1.1.1.1}"
  : "${CHECK_INTERVAL:=120}"

  [[ -n ${PRIVATE_KEY:-} ]] || die 10 "PRIVATE_KEY is not set"
  [[ -n ${PSK:-} ]]         || die 10 "PSK is not set"
  [[ -n ${ADDRESS:-} ]]     || die 10 "ADDRESS is not set"

  # ADDRESS may arrive exactly as CryptoStorm issues it: "10.10.1.2, fd00:10:10::1".
  # The tunnel is IPv4-only (IPv6 egress is denied or disabled), so keep the
  # IPv4 entry and drop the rest.
  local -a addrs
  local a v4=""
  IFS=',' read -r -a addrs <<< "$ADDRESS"
  for a in "${addrs[@]}"; do
    a="${a// /}"
    [[ -n $a ]] || continue
    if [[ $a =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(/[0-9]+)?$ ]]; then
      [[ $a == */* ]] || a="${a}/32"
      if [[ -z $v4 ]]; then
        v4="$a"
      else
        log_warn "ADDRESS: ignoring extra IPv4 entry ${a}"
      fi
    elif [[ $a == *:* ]]; then
      log_info "ADDRESS: ignoring IPv6 entry ${a} (tunnel is IPv4-only)"
    else
      die 10 "ADDRESS entry '${a}' is not an IP address"
    fi
  done
  [[ -n $v4 ]] || die 10 "ADDRESS '${ADDRESS}' contains no IPv4 address"
  ADDRESS="$v4"
  [[ $ADDRESS == 10.10.* ]] \
    || log_warn "ADDRESS '${ADDRESS}' is outside CryptoStorm's usual 10.10.0.0/16 WireGuard range"

  [[ $RECONNECT =~ ^[0-9]+$ ]]      || die 10 "RECONNECT must be a whole number of seconds"
  [[ $CHECK_INTERVAL =~ ^[0-9]+$ ]] || die 10 "CHECK_INTERVAL must be a whole number of seconds"

  # SERVER -> SERVERS[]
  local raw entry
  IFS='+' read -r -a raw <<< "$SERVER"
  for entry in "${raw[@]}"; do
    entry="${entry,,}"
    entry="${entry#cs-}"
    [[ -n $entry ]] || continue
    if [[ $entry != "auto" ]] && ! servers_exists "$entry"; then
      die 10 "unknown server '${entry}'. Known servers: $(servers_list | tr '\n' ' ')"
    fi
    SERVERS+=("$entry")
  done
  (( ${#SERVERS[@]} > 0 )) || die 10 "SERVER resolved to an empty list"

  # CANDIDATES -> CANDIDATE_LIST[]
  if [[ -n $CANDIDATES ]]; then
    IFS=',' read -r -a raw <<< "$CANDIDATES"
    for entry in "${raw[@]}"; do
      entry="${entry,,}"
      entry="${entry#cs-}"
      entry="${entry// /}"
      [[ -n $entry ]] || continue
      servers_exists "$entry" || die 10 "unknown candidate '${entry}'. Known servers: $(servers_list | tr '\n' ' ')"
      CANDIDATE_LIST+=("$entry")
    done
  else
    mapfile -t CANDIDATE_LIST < <(servers_list)
  fi

  # FORWARD_PORTS -> FORWARD_PORT_LIST[]
  if [[ -n $FORWARD_PORTS ]]; then
    IFS=',' read -r -a raw <<< "$FORWARD_PORTS"
    for entry in "${raw[@]}"; do
      entry="${entry// /}"
      [[ -n $entry ]] || continue
      [[ $entry =~ ^[0-9]+$ ]] || die 10 "FORWARD_PORTS entry '${entry}' is not a number"
      (( entry >= 30000 && entry <= 65535 )) \
        || die 10 "FORWARD_PORTS entry '${entry}' is outside CryptoStorm's allowed range 30000-65535"
      FORWARD_PORT_LIST+=("$entry")
    done
  fi

  export ADDRESS ALLOWED_IPS DNS LOCAL_SUBNETS NOTIFY_URL PING_TARGET RECONNECT CHECK_INTERVAL
}

config_print() {
  log_info "servers        : ${SERVERS[*]}"
  log_info "candidates     : ${CANDIDATE_LIST[*]}"
  log_info "address        : ${ADDRESS}"
  log_info "allowed ips    : ${ALLOWED_IPS}"
  log_info "local subnets  : ${LOCAL_SUBNETS:-<none>}"
  log_info "dns            : ${DNS}"
  log_info "reconnect      : ${RECONNECT}s"
  log_info "check interval : ${CHECK_INTERVAL}s"
  log_info "forward ports  : ${FORWARD_PORT_LIST[*]:-<none>}"
  if [[ -n $NOTIFY_URL ]]; then
    log_info "notify url     : <set>"
  else
    log_info "notify url     : <none>"
  fi
}
