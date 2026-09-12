#!/usr/bin/env bash
# CI smoke test. Runs the built image with placeholder credentials in
# --validate mode and checks that configuration parsing behaves.
#
# Usage: tests/smoke.sh <image>
set -euo pipefail

IMAGE="${1:?usage: smoke.sh <image>}"

run() {
  docker run --rm --entrypoint /opt/cryptostorm/entrypoint.sh "$@" "$IMAGE" --validate
}

echo "== bundled server templates"
docker run --rm --entrypoint sh "$IMAGE" -c 'ls /opt/cryptostorm/servers | sed "s/\.conf$//" | tr "\n" " "; echo'

echo "== valid configuration is accepted"
out=$(run \
  -e PRIVATE_KEY=placeholder \
  -e PSK=placeholder \
  -e ADDRESS=10.10.0.2 \
  -e SERVER=newyork+dc+auto \
  -e CANDIDATES=newyork,dc,chicago \
  -e FORWARD_PORTS=46805,48979)
echo "$out"
grep -q 'servers        : newyork dc auto' <<< "$out"
grep -q 'forward ports  : 46805 48979' <<< "$out"
grep -q 'address        : 10.10.0.2/32' <<< "$out"

echo "== legacy cs- prefix is stripped"
run -e PRIVATE_KEY=x -e PSK=x -e ADDRESS=10.10.0.2/32 -e SERVER=cs-montreal \
  | grep -q 'servers        : montreal'

echo "== unknown server is rejected"
if run -e PRIVATE_KEY=x -e PSK=x -e ADDRESS=10.10.0.2/32 -e SERVER=atlantis >/dev/null 2>&1; then
  echo "expected failure for unknown server" >&2; exit 1
fi

echo "== out-of-range forward port is rejected"
if run -e PRIVATE_KEY=x -e PSK=x -e ADDRESS=10.10.0.2/32 -e SERVER=newyork -e FORWARD_PORTS=8082 >/dev/null 2>&1; then
  echo "expected failure for port 8082" >&2; exit 1
fi

echo "== missing PRIVATE_KEY is rejected"
if run -e PSK=x -e ADDRESS=10.10.0.2/32 >/dev/null 2>&1; then
  echo "expected failure for missing PRIVATE_KEY" >&2; exit 1
fi

echo "smoke test passed"
