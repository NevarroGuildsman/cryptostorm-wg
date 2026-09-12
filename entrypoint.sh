#!/usr/bin/env bash
# shellcheck disable=SC2154  # variables come from config.sh / the environment
# cryptostorm-wg entrypoint.
#
# Lifecycle:
#   config_load      parse and validate the environment, build the SERVERS list
#   firewall_init    install the kill switch before any tunnel exists
#   loop over SERVERS:
#     tunnel_session <name>   resolve 'auto', bring up wg0, register forwards,
#                             monitor until failure or RECONNECT expiry
#   a session returning 0 means "rotate to the next server" (timed reconnect);
#   non-zero means the server failed. When every server has failed in a row
#   the container exits so Docker's restart policy can back off.
#
# Flags:
#   --validate   load and print the configuration, then exit 0. Used by CI.
set -euo pipefail

CS_HOME="${CS_HOME:-/opt/cryptostorm}"
export CS_HOME

for f in "$CS_HOME"/lib/*.sh; do
  # shellcheck disable=SC1090
  source "$f"
done

main() {
  log_banner
  config_load

  if [[ ${1:-} == "--validate" ]]; then
    config_print
    log_info "configuration is valid"
    exit 0
  fi

  firewall_init

  local idx=0
  local failures=0
  local total=${#SERVERS[@]}

  while :; do
    if tunnel_session "${SERVERS[$idx]}"; then
      failures=0
    else
      failures=$((failures + 1))
      if (( failures >= total )); then
        notify_send "all-servers-failed" "every configured server failed (${total} tried)"
        die 30 "every configured server failed (${total} tried); exiting so the restart policy can back off"
      fi
      sleep 2
    fi
    idx=$(( (idx + 1) % total ))
  done
}

main "$@"
