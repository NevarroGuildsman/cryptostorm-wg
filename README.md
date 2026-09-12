# cryptostorm-wg

A small, rebuilt-weekly Docker image that keeps a [CryptoStorm](https://cryptostorm.is)
WireGuard tunnel up for other containers to share, with:

- **Server selection**: an ordered list of servers, plus an `auto` entry that
  ranks a shortlist by latency each time it comes around.
- **Failover and rotation**: a dead server is skipped; an optional timer
  rotates to the next one while healthy.
- **Kill switch**: nothing leaves the container except WireGuard traffic to the
  active endpoint and your LAN.
- **Port-forward registration**: the listen ports you publish are registered
  on every server the tunnel lands on, with a webhook notification when that
  is not possible.

Built on a Docker Hardened Image (Alpine) and rebuilt every Monday so base
packages stay current. The CryptoStorm server list is vendored in `servers/`
and refreshed with a script, because cryptostorm.is refuses connections from
datacenter address ranges such as CI runners.

> **Status: scaffold.** Configuration parsing, the vendored server list,
> CI and the image build work. Tunnel bring-up, kill switch, monitoring and
> port forwarding are stubs marked `TODO(...)` in `lib/`. Do not run this in
> front of real traffic yet.

## Why

CryptoStorm has no official container. The community image that handled
multiple servers was last built in 2023, and "fastest" there meant lowest ping,
which always picks the geographically nearest server even when it is the
congested one. This project keeps the useful ideas, drops the unmaintained
parts, and adds the port-forward registrar.

## Usage

See [`examples/docker-compose.yml`](examples/docker-compose.yml) for a full
stack with two qBittorrent instances sharing the tunnel's network namespace.

Minimum:

```yaml
services:
  cryptostorm:
    image: ghcr.io/nevarroguildsman/cryptostorm-wg:latest
    cap_add: [NET_ADMIN]
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
    environment:
      PRIVATE_KEY: ${WIREGUARD_PRIVATE_KEY}
      PSK: ${WIREGUARD_PRESHARED_KEY}
      ADDRESS: ${WIREGUARD_ADDRESSES}
      SERVER: newyork+dc+auto
      CANDIDATES: newyork,dc,chicago
      FORWARD_PORTS: 46805,48979
```

Get your key material from <https://cryptostorm.is/wireguard> with your access
token; it returns the pre-shared key and your tunnel address for a public key
you generate with `wg genkey | tee private | wg pubkey`.

## Environment

| Variable         | Default          | Meaning |
|------------------|------------------|---------|
| `PRIVATE_KEY`    | required         | WireGuard private key |
| `PSK`            | required         | Pre-shared key issued by CryptoStorm |
| `ADDRESS`        | required         | Tunnel address, e.g. `10.10.17.119/32` |
| `SERVER`         | `auto`           | Ordered `+`-joined list, e.g. `newyork+dc+auto`. A legacy `cs-` prefix is accepted. |
| `CANDIDATES`     | all bundled      | Comma list restricting what `auto` may pick |
| `RECONNECT`      | `0`              | Seconds before rotating to the next entry while healthy; `0` disables |
| `ALLOWED_IPS`    | `0.0.0.0/0`      | Peer AllowedIPs |
| `LOCAL_SUBNETS`  | none             | Comma list of LAN subnets kept reachable outside the tunnel |
| `DNS`            | `10.31.33.8`     | Resolver used while connected |
| `FORWARD_PORTS`  | none             | Comma list of ports (30000-65535) to register on each server |
| `NOTIFY_URL`     | none             | Webhook receiving JSON events |
| `PING_TARGET`    | `1.1.1.1`        | Connectivity check target |
| `CHECK_INTERVAL` | `120`            | Seconds between connectivity checks |

Run the image with `--validate` to parse and print the configuration without
touching the network.

### Available servers

The image bundles one template per CryptoStorm server from `servers/`. List
them with:

```bash
docker run --rm --entrypoint sh ghcr.io/nevarroguildsman/cryptostorm-wg ls /opt/cryptostorm/servers
```

Mount your own directory over `/opt/cryptostorm/servers` to restrict or
override the set. Each file is `NAME=`, `ENDPOINT=`, `PUBLIC_KEY=`.

To pick up new servers or rotated keys, run this from a home connection and
commit the result; the next push rebuilds the image:

```bash
build/refresh-servers.sh
```

It parses CryptoStorm's published config generator and reports what was
added, changed or removed.

### Port forwarding

CryptoStorm forwards are requested from inside the tunnel through a web form,
are isolated per server, and for WireGuard persist until removed or your token
expires. The registrar therefore runs on every connect and is idempotent.
A container cannot read its own compose `ports:` block, so list the same
ports in `FORWARD_PORTS`.

### Notifications

When `NOTIFY_URL` is set, events are POSTed as JSON:

```json
{"event":"portfwd-failed","message":"...","host":"cryptostorm","time":"2026-09-12T18:00:00-03:00","server":"newyork"}
```

Events: `connected`, `failover`, `rotated`, `portfwd-failed`,
`all-servers-failed`.

## Building

```bash
docker build -t cryptostorm-wg .
```

The base image defaults to `dhi.io/alpine-base:3.22-dev`. Docker Hardened
Images are free but dhi.io requires `docker login dhi.io` with Docker Hub
credentials. Override the base for an unauthenticated build:

```bash
docker build --build-arg BASE_IMAGE=alpine:3.22 -t cryptostorm-wg .
```

### CI

`.github/workflows/build.yml` lints with shellcheck, builds, runs
`tests/smoke.sh`, and pushes to GHCR on `main` and on the weekly schedule.
Add repository secrets `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` (a Docker
Hub personal access token with read scope) to build on the hardened base;
without them CI falls back to public Alpine and prints a warning.

## Roadmap

1. Kill switch (`lib/30-firewall.sh`)
2. Tunnel session and monitor (`lib/40-tunnel.sh`, `lib/50-monitor.sh`)
3. Latency ranking for `auto` (`lib/20-servers.sh`)
4. Port-forward registrar with fixture-based tests (`lib/60-portfwd.sh`)
5. Optional throughput probe so a congested nearby server loses to a faster
   distant one

## License

MIT. See [LICENSE](LICENSE).
