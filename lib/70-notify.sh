#!/usr/bin/env bash
# Notifications. Posts a small JSON document to NOTIFY_URL; silent when unset.
# Works with n8n webhooks, ntfy, Discord and anything else that takes JSON.
#
# notify_send <event> <message> [key=value ...]
#   event    short machine-readable name, e.g. connected, failover,
#            portfwd-failed, all-servers-failed
#   message  human-readable text

notify_send() {
  local event="$1"
  local message="$2"
  shift 2
  [[ -n ${NOTIFY_URL:-} ]] || return 0

  local payload
  payload=$(jq -cn \
    --arg event "$event" \
    --arg message "$message" \
    --arg host "$(hostname)" \
    --arg ts "$(date -Iseconds)" \
    '{event: $event, message: $message, host: $host, time: $ts}')

  # Extra key=value pairs become top-level fields.
  local kv
  for kv in "$@"; do
    payload=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<< "$payload")
  done

  curl -fsS --max-time 10 -H 'Content-Type: application/json' -d "$payload" "$NOTIFY_URL" >/dev/null 2>&1 \
    || log_warn "notify_send: delivery to NOTIFY_URL failed (${event})"
}
