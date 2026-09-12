#!/usr/bin/env bash
# Server templates. One file per server in $SERVER_DIR, generated at build time
# by build/generate-templates.sh, each containing NAME, ENDPOINT, PUBLIC_KEY.
# Mount your own directory over $SERVER_DIR to change the available set.

SERVER_DIR="${SERVER_DIR:-${CS_HOME}/servers}"

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

# servers_select
# Prints the name of the best server among CANDIDATE_LIST.
# TODO(selection): fping every candidate endpoint (temporarily allowing ICMP
# through the kill switch), discard candidates with packet loss, sort by
# average RTT and print the winner. Later: optional short throughput probe.
servers_select() {
  log_warn "servers_select: latency ranking is not implemented yet"
  return 1
}
