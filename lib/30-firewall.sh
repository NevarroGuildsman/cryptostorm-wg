#!/usr/bin/env bash
# Kill switch. Default-deny on the physical interface so nothing leaves the
# container except WireGuard traffic to the active endpoint and LOCAL_SUBNETS.
#
# Contract:
#   firewall_init                         baseline rules, once, before any tunnel
#   firewall_allow_endpoint <ip> <port>   permit UDP to the peer about to be used
#   firewall_revoke_endpoint <ip> <port>  remove that permit on teardown
#   firewall_allow_probe                  short-lived ICMP allowance for ranking
#   firewall_revoke_probe                 remove it again
#
# TODO(firewall): implement with iptables (fall back to iptables-legacy when the
# host kernel lacks nf_tables). Always keep loopback, established/related and
# LOCAL_SUBNETS open so published ports and LAN access keep working.

firewall_init() {
  log_warn "firewall_init: kill switch is not implemented yet"
}

firewall_allow_endpoint()  { :; }
firewall_revoke_endpoint() { :; }
firewall_allow_probe()     { :; }
firewall_revoke_probe()    { :; }
