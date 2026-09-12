#!/usr/bin/env bash
# Connection monitor. Runs while a tunnel is up.
#
# monitor_loop <server-name>
#   Every CHECK_INTERVAL seconds ping PING_TARGET through the tunnel. Three
#   consecutive failures mean the server is dead: return 1 so the session
#   fails over. When RECONNECT is non-zero and has elapsed, return 0 so the
#   caller rotates to the next server cleanly.
#
# TODO(monitor): implement as described. Also refresh the status file that
# healthcheck.sh reads, and re-run portfwd_ensure periodically in case a
# forward was removed server-side.

monitor_loop() {
  log_warn "monitor_loop: not implemented yet"
  return 1
}
