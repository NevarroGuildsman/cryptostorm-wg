#!/usr/bin/env bash
# shellcheck disable=SC2154  # variables come from config.sh / the environment
# Port-forward registrar for CryptoStorm.
#
# Facts (from https://cryptostorm.is/portfwd):
#   * Requests are made from inside the tunnel to http://10.31.33.7/fwd
#     (IPv6: http://[2001:db8::7]/fwd) through a plain web form, no API.
#   * Ports must be 30000-65535, at most 100 per internal IP per server.
#   * Forwards are isolated per server, so every server we land on needs
#     its own registration.
#   * WireGuard forwards persist until removed or the token expires, so the
#     routine is idempotent: read what exists, add what is missing.
#
# Contract:
#   portfwd_ensure <server-name>   make every FORWARD_PORT_LIST entry active on
#                                  this server; notify on any failure. Never
#                                  fails the session: a missing forward is
#                                  degraded service, not a dead tunnel.
#   portfwd_list                   print currently registered ports
#
# TODO(portfwd): capture the form's HTML into tests/fixtures/ from a live
# session first, then implement the parser and the enable request against
# that fixture so a page change is caught by CI.

# shellcheck disable=SC2034
PORTFWD_URL="${PORTFWD_URL:-http://10.31.33.7/fwd}"

portfwd_ensure() {
  local server="$1"
  (( ${#FORWARD_PORT_LIST[@]} > 0 )) || return 0
  log_warn "portfwd_ensure: not implemented yet (would register ${FORWARD_PORT_LIST[*]} on ${server})"
  return 0
}

portfwd_list() {
  return 1
}
