# syntax=docker/dockerfile:1
#
# cryptostorm-wg: CryptoStorm WireGuard gateway with server selection, failover,
# kill switch and port-forward registration.
#
# Base image: a Docker Hardened Image (Alpine, -dev variant). The -dev variant is
# required because this image needs apk to install wireguard-tools and iptables,
# and it must run as root for NET_ADMIN work (wg-quick, iptables, routes).
# Pulling from dhi.io requires `docker login dhi.io` with Docker Hub credentials;
# CI falls back to the public Alpine image when those secrets are absent.
ARG BASE_IMAGE=dhi.io/alpine-base:3.22-dev
FROM ${BASE_IMAGE}

ARG BUILD_DATE
ARG VCS_REF
ARG VERSION=dev
LABEL org.opencontainers.image.title="cryptostorm-wg" \
      org.opencontainers.image.description="CryptoStorm WireGuard gateway with server selection, failover, kill switch and port-forward registration" \
      org.opencontainers.image.source="https://github.com/NevarroGuildsman/cryptostorm-wg" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}"

USER root

# --upgrade so the weekly rebuild also picks up patched Alpine packages.
RUN apk add --no-cache --upgrade \
      bash \
      wireguard-tools \
      iptables \
      ip6tables \
      fping \
      curl \
      jq \
      bind-tools \
      ca-certificates \
      tzdata \
 # wg-quick insists on setting src_valid_mark itself, which fails inside a
 # container even when the sysctl is already 1. Compose sets the sysctl instead.
 && sed -i 's/^\([^#].*net\.ipv4\.conf\.all\.src_valid_mark.*\)/#\1/' /usr/bin/wg-quick

# Server templates are vendored in servers/ and refreshed with
# build/refresh-servers.sh from a home connection: cryptostorm.is refuses
# connections from datacenter ranges, including CI runners.
COPY servers/ /opt/cryptostorm/servers/
RUN set -- /opt/cryptostorm/servers/*.conf && test -f "$1"

COPY entrypoint.sh healthcheck.sh /opt/cryptostorm/
COPY lib/ /opt/cryptostorm/lib/
RUN chmod 0755 /opt/cryptostorm/entrypoint.sh /opt/cryptostorm/healthcheck.sh

ENV CS_HOME=/opt/cryptostorm \
    CS_VERSION=${VERSION}

HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
  CMD ["/opt/cryptostorm/healthcheck.sh"]

ENTRYPOINT ["/opt/cryptostorm/entrypoint.sh"]
