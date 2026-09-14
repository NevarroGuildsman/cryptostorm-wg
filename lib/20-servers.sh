#!/usr/bin/env bash
# shellcheck disable=SC2154  # variables come from config.sh / net.sh
# Server templates and selection. One file per server in $SERVER_DIR, each
# containing NAME, ENDPOINT, PUBLIC_KEY. Mount your own directory over
# $SERVER_DIR to change the available set.

SERVER_DIR="${SERVER_DIR:-${CS_HOME}/servers}"
PROBE_COUNT="${PROBE_COUNT:-5}"

servers_list() {
  local f
  for f in "$SERVER_DIR"/*.conf; do
    [[ -f $f ]] || continue
    basename "$f" .conf
  done
}

servers_exists() {
  [[ -f "$SERVER_DIR/$1.conf" ]]
}

# servers_load <name>
# Sets ENDPOINT, ENDPOINT_HOST, ENDPOINT_PORT and PUBLIC_KEY for the caller.
servers_load() {
  local name="$1"
  servers_exists "$name" || return 1
  # shellcheck disable=SC1090
  source "$SERVER_DIR/$name.conf"
  ENDPOINT_HOST="${ENDPOINT%%:*}"
  ENDPOINT_PORT="${ENDPOINT##*:}"
  [[ $ENDPOINT_PORT =~ ^[0-9]+$ ]] || ENDPOINT_PORT=443
  export ENDPOINT ENDPOINT_HOST ENDPOINT_PORT PUBLIC_KEY
}

# servers_rank
# Reads `fping -q -c N` summary lines on stdin and prints "avg_ms host",
# ascending, dropping hosts with more than 20% loss or no replies.
#   host : xmt/rcv/%loss = 5/5/0%, min/avg/max = 10.1/11.2/12.0
#   host : xmt/rcv/%loss = 5/0/100%
servers_rank() {
  awk '
    $3 == "xmt/rcv/%loss" {
      split($5, l, "/"); loss = l[3]; sub(/%.*/, "", loss)
      if (loss + 0 > 20 || NF < 8) next
      split($8, r, "/")
      printf "%s %s\n", r[2], $1
    }' | sort -n
}

# servers_select
# Prints the lowest-latency reachable server among CANDIDATE_LIST. Only ever
# called while the tunnel is down. Logs go to stderr because stdout is the
# return channel.
servers_select() {
  local name ip ranked="" avg host i winner=""
  local -a names=() ips=()

  firewall_allow_probe
  for name in "${CANDIDATE_LIST[@]}"; do
    servers_load "$name" || continue
    if ip=$(net_resolve "$ENDPOINT_HOST"); then
      names+=("$name")
      ips+=("$ip")
    else
      log_warn "auto: cannot resolve ${ENDPOINT_HOST}, skipping ${name}" >&2
    fi
  done
  if (( ${#ips[@]} > 0 )); then
    ranked=$(fping -q -c "$PROBE_COUNT" -p 250 -t 1500 "${ips[@]}" 2>&1 | servers_rank) || true
  fi
  firewall_revoke_probe

  [[ -n $ranked ]] || { log_warn "auto: no candidate answered pings (firewalled upstream?)" >&2; return 1; }

  while read -r avg host; do
    for i in "${!ips[@]}"; do
      [[ ${ips[$i]} == "$host" ]] || continue
      log_info "auto: ${names[$i]} ${avg} ms" >&2
      [[ -n $winner ]] || winner="${names[$i]}"
    done
  done <<< "$ranked"

  [[ -n $winner ]] || return 1
  echo "$winner"
}
