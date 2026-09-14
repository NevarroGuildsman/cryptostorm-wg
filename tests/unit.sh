#!/usr/bin/env bash
# Unit tests for pure functions. Runs on any host with bash; no Docker needed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
export CS_HOME="$PWD"
for f in lib/*.sh; do
  # shellcheck disable=SC1090
  source "$f"
done

fail() { echo "FAIL: $*" >&2; exit 1; }

# servers_rank: sorts by average RTT, drops lossy and silent hosts
fixture='10.0.0.1 : xmt/rcv/%loss = 5/5/0%, min/avg/max = 31.2/33.9/40.1
10.0.0.2 : xmt/rcv/%loss = 5/5/0%, min/avg/max = 12.0/12.8/14.2
10.0.0.3 : xmt/rcv/%loss = 5/3/40%, min/avg/max = 9.0/9.5/10.0
10.0.0.4 : xmt/rcv/%loss = 5/0/100%
10.0.0.5 : xmt/rcv/%loss = 5/4/20%, min/avg/max = 20.0/21.5/25.0'
expected='12.8 10.0.0.2
21.5 10.0.0.5
33.9 10.0.0.1'
actual=$(servers_rank <<< "$fixture")
[[ $actual == "$expected" ]] || fail "servers_rank produced:"$'\n'"$actual"
echo "ok servers_rank"

# servers_rank: empty input yields empty output, not an error
[[ -z $(servers_rank < /dev/null) ]] || fail "servers_rank should print nothing for empty input"
echo "ok servers_rank empty"

echo "unit tests passed"
