#!/usr/bin/env bash
# Logging helpers. Everything goes to stdout/stderr so `docker logs` has it all.

_ts() { date -Iseconds; }

log_info()  { printf '[%s] INFO  %s\n' "$(_ts)" "$*"; }
log_warn()  { printf '[%s] WARN  %s\n' "$(_ts)" "$*"; }
log_error() { printf '[%s] ERROR %s\n' "$(_ts)" "$*" >&2; }

log_banner() {
  log_info "cryptostorm-wg ${CS_VERSION:-dev} starting"
}

# die <exit-code> <message>
# Sleeps briefly before exiting so a misconfigured container does not spin
# through Docker's restart policy at full speed.
die() {
  local code="$1"
  shift
  log_error "$*"
  sleep 5
  exit "$code"
}
