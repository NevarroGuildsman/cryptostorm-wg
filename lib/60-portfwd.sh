#!/usr/bin/env bash
# shellcheck disable=SC2154  # variables come from config.sh / the environment
# Port-forward registrar for CryptoStorm.
#
# The endpoint at http://10.31.33.7/fwd is reachable only through the tunnel.
# Observed behaviour (September 2026):
#   GET with a non-browser user agent  -> plain text:
#       NO_ARGS_RECEIVED
#       Your current port forwardings:
#       146.70.154.70:46805 -> 10.10.199.104:46805
#   POST port=<n>        enable a forward (30000-65535); replies PORT_ADD_OK
#   POST delfwd=<n>      delete one forward
#   POST delallfwd=1     delete every forward on this server
# The reply text is logged but not relied on: success is confirmed by
# listing again.
# Forwards are isolated per server and, for WireGuard, persist until removed
# or the access token expires, so this routine is idempotent: list, add what
# is missing, list again to verify.
#
# A missing forward is degraded service, not a dead tunnel: portfwd_ensure
# notifies and returns 0 so the session continues.

PORTFWD_URL="${PORTFWD_URL:-http://10.31.33.7/fwd}"
# Seconds between re-checks of the forwards while a tunnel is up.
PORTFWD_REFRESH="${PORTFWD_REFRESH:-3600}"

portfwd_fetch() {
  curl -fsS --max-time 10 "$PORTFWD_URL"
}

# portfwd_parse
# Reads the plain-text listing on stdin and prints the public port of each
# forward, one per line, from lines shaped like "1.2.3.4:46805 -> 10.10.0.2:46805".
portfwd_parse() {
  awk '
    $2 == "->" {
      n = split($1, a, ":")
      if (n == 2 && a[2] ~ /^[0-9]+$/) print a[2]
    }'
}

# portfwd_exit_ip
# Prints the public address the forwards are bound to, from the same listing.
portfwd_exit_ip() {
  awk '$2 == "->" { split($1, a, ":"); print a[1]; exit }'
}

# portfwd_add <port>
portfwd_add() {
  curl -fsS --max-time 10 --data-urlencode "port=$1" "$PORTFWD_URL"
}

# portfwd_list
# Prints the ports currently forwarded on the connected server.
portfwd_list() {
  portfwd_fetch | portfwd_parse
}

# portfwd_ensure <server-name>
portfwd_ensure() {
  local server="$1"
  (( ${#FORWARD_PORT_LIST[@]} > 0 )) || return 0

  local body port resp exit_ip
  local -a have missing still
  if ! body=$(portfwd_fetch); then
    log_warn "[${server}] port-forward service ${PORTFWD_URL} is unreachable"
    notify_send portfwd-failed "port-forward service unreachable on ${server}" "server=${server}"
    return 0
  fi
  mapfile -t have < <(portfwd_parse <<< "$body")
  exit_ip=$(portfwd_exit_ip <<< "$body")

  missing=()
  for port in "${FORWARD_PORT_LIST[@]}"; do
    _portfwd_contains "$port" "${have[@]}" || missing+=("$port")
  done
  if (( ${#missing[@]} == 0 )); then
    log_info "[${server}] forwards already active${exit_ip:+ on ${exit_ip}}: ${FORWARD_PORT_LIST[*]}"
    return 0
  fi

  for port in "${missing[@]}"; do
    if resp=$(portfwd_add "$port"); then
      log_info "[${server}] requested forward for ${port}: ${resp%%$'\n'*}"
    else
      log_warn "[${server}] request to forward ${port} failed"
    fi
  done

  if ! body=$(portfwd_fetch); then
    log_warn "[${server}] could not verify forwards; service unreachable"
    notify_send portfwd-failed "could not verify forwards on ${server}" "server=${server}"
    return 0
  fi
  mapfile -t have < <(portfwd_parse <<< "$body")
  exit_ip=$(portfwd_exit_ip <<< "$body")
  still=()
  for port in "${missing[@]}"; do
    _portfwd_contains "$port" "${have[@]}" || still+=("$port")
  done
  if (( ${#still[@]} > 0 )); then
    log_error "[${server}] forwards not active after registration: ${still[*]}"
    notify_send portfwd-failed "could not register ${still[*]} on ${server}" "server=${server}" "ports=${still[*]}"
    return 0
  fi
  log_info "[${server}] forwards active${exit_ip:+ on ${exit_ip}}: ${FORWARD_PORT_LIST[*]}"
  return 0
}

# _portfwd_contains <needle> <haystack...>
_portfwd_contains() {
  local needle="$1" x
  shift
  for x in "$@"; do
    [[ $x == "$needle" ]] && return 0
  done
  return 1
}
