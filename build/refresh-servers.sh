#!/usr/bin/env bash
# Refresh the vendored server list in servers/ from CryptoStorm's published
# WireGuard config generator.
#
# Run this from a home connection and commit the result: cryptostorm.is
# refuses connections from datacenter ranges, including GitHub Actions
# runners, which is why the list is committed rather than fetched at build.
#
# Usage: build/refresh-servers.sh [path-to-local-wg_confgen.txt]
set -euo pipefail

GEN_URL="https://cryptostorm.is/wg_confgen.txt"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO_ROOT/servers"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [[ -n ${1:-} ]]; then
  cp "$1" "$work/confgen.sh"
else
  curl -fsSL --max-time 60 --retry 2 "$GEN_URL" -o "$work/confgen.sh"
fi

# Entries in the generator's node array look like: "newyork:BASE64KEY="
mapfile -t nodes < <(grep -oE '^"[a-z0-9-]+:[A-Za-z0-9+/]{43}="' "$work/confgen.sh" | tr -d '"')
if (( ${#nodes[@]} == 0 )); then
  echo "no nodes found; the generator's format may have changed" >&2
  exit 1
fi

# Endpoint pattern from the generator's template, e.g. ${host}.cstorm.is:443
endpoint_tpl=$(grep -oE '^Endpoint = .*$' "$work/confgen.sh" | head -1 | sed 's/^Endpoint = //' | tr -d '[:space:]')
# shellcheck disable=SC2016  # literal ${host} placeholder, substituted below
[[ -n $endpoint_tpl ]] || endpoint_tpl='${host}.cstorm.is:443'

mkdir -p "$OUT" "$work/new"
for node in "${nodes[@]}"; do
  host="${node%%:*}"
  pubk="${node#*:}"
  endpoint="${endpoint_tpl//\$\{host\}/$host}"
  printf 'NAME=%s\nENDPOINT=%s\nPUBLIC_KEY=%s\n' "$host" "$endpoint" "$pubk" > "$work/new/$host.conf"
done

added=(); changed=(); removed=()
for f in "$work/new"/*.conf; do
  n=$(basename "$f")
  if [[ ! -f "$OUT/$n" ]]; then
    added+=("${n%.conf}")
  elif ! cmp -s "$f" "$OUT/$n"; then
    changed+=("${n%.conf}")
  fi
done
for f in "$OUT"/*.conf; do
  [[ -f $f ]] || continue
  n=$(basename "$f")
  [[ -f "$work/new/$n" ]] || removed+=("${n%.conf}")
done

rm -f "$OUT"/*.conf
cp "$work/new"/*.conf "$OUT/"

echo "servers: ${#nodes[@]} total, ${#added[@]} added, ${#changed[@]} changed, ${#removed[@]} removed"
(( ${#added[@]} ))   && echo "  added:   ${added[*]}"
(( ${#changed[@]} )) && echo "  changed: ${changed[*]}"
(( ${#removed[@]} )) && echo "  removed: ${removed[*]}"
exit 0
