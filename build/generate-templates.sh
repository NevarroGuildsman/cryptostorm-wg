#!/usr/bin/env bash
# Build-time only. Runs CryptoStorm's published WireGuard config generator with
# placeholder credentials and distils each generated file into a small
# KEY=VALUE template: NAME, ENDPOINT, PUBLIC_KEY.
#
# Usage: generate-templates.sh <output-dir>
set -euo pipefail

OUT="${1:?usage: generate-templates.sh <output-dir>}"
GEN_URL="https://cryptostorm.is/wg_confgen.txt"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

curl -fsSL --retry 3 --retry-delay 5 "$GEN_URL" -o "$work/confgen.sh"

# The generator expects to run as root inside /etc/wireguard with a privatekey
# file already present. Placeholders are fine: only Endpoint and PublicKey are kept.
mkdir -p /etc/wireguard
cd /etc/wireguard
echo "@@PRIVATE_KEY@@" > privatekey
echo "@@PUBLIC_KEY@@"  > publickey
bash "$work/confgen.sh" "@@PSK@@" "@@ADDRESS@@" > "$work/confgen.log" 2>&1 || {
  cat "$work/confgen.log" >&2
  echo "confgen failed" >&2
  exit 1
}
rm -f privatekey publickey

mkdir -p "$OUT"
count=0
for f in cs-*.conf; do
  [[ -f $f ]] || continue
  name="${f#cs-}"
  name="${name%.conf}"
  endpoint=$(awk -F' *= *' '/^Endpoint/ {print $2}' "$f" | tr -d '[:space:]')
  pubkey=$(awk -F' *= *' '/^PublicKey/ {print $2}' "$f" | tr -d '[:space:]')
  if [[ -z $endpoint || -z $pubkey ]]; then
    echo "skipping $f: missing Endpoint or PublicKey" >&2
    continue
  fi
  printf 'NAME=%s\nENDPOINT=%s\nPUBLIC_KEY=%s\n' "$name" "$endpoint" "$pubkey" > "$OUT/$name.conf"
  count=$((count + 1))
done
rm -f cs-*.conf

if (( count == 0 )); then
  echo "no server templates were generated; the upstream generator may have changed" >&2
  exit 1
fi
echo "generated $count server templates:"
for f in "$OUT"/*.conf; do printf '%s ' "$(basename "$f" .conf)"; done
echo
