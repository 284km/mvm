#!/bin/sh
# test/outward.sh — a container that can reach the world, and one that must not
# be given the way to.
#
# WHY THIS EXISTS. This guest has no network interface: the VMM shows it a
# block device and vsock and nothing else. Everything that leaves goes through
# a proxy on the host, and until now only BUILD STEPS were told about it -- a
# `docker run` got nothing, so `wget http://...` inside a container failed and
# the reason was three layers away.
#
# TWO THINGS ARE CHECKED, and the second is the one that is easy to get wrong:
#
#   1. a container on the default bridge reaches the world
#   2. a container on a NETWORK SOMEBODY CREATED does not get a proxy, and
#      still reaches the service next to it by name
#
# (2) is not caution, it is a measurement. A network somebody created resolves
# container names; an HTTP client with a proxy in its environment stops
# resolving names itself and asks the proxy, which is outside this machine and
# has never heard of them. The usual escape is no_proxy, and the client in the
# commonest base image does not have one:
#
#   busybox wget 1.37, no_proxy=peer / * / <ip> / <name>,<ip>  -> all time out
#
# So the rule is "the default bridge, where no names resolve", and this checks
# both halves of it. MENGD_CONTAINER_PROXY=all overrides it for someone whose
# clients honour no_proxy.
#
#   MERE=<mere> MENGD_SRC=<mengd> MRUN_SRC=<mrun> sh test/outward.sh
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
command -v docker >/dev/null 2>&1 || { echo "needs a docker client as the oracle" >&2; exit 2; }
[ -n "${MENGD_SRC:-}" ] && [ -n "${MRUN_SRC:-}" ] || { echo "set MENGD_SRC and MRUN_SRC" >&2; exit 2; }
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }
M="out$$"
export MVM_HOME="${MVM_HOME:-$HOME/.mvm}"
D="$MVM_HOME/$M"
out="$here/.build"; mkdir -p "$out"
cleanup() {
  [ -d "$D" ] && { cp "$D/mproxy.log" "$out/outward-$M-mproxy.log" 2>/dev/null
                   cp "$D/console.log" "$out/outward-$M-console.log" 2>/dev/null; }
  sh "$here/tools/mvm" stop --name "$M" >/dev/null 2>&1
  rm -rf "$D"; docker context rm "mvm-$M" >/dev/null 2>&1
}
trap cleanup EXIT

echo "== a machine, with a way out =="
MPROXY_TRACE=1 sh "$here/tools/mvm" start --name "$M" --disk-size 4096 > "$out/outward-start.log" 2>&1
say $? "mvm start"
grep -q "is up" "$out/outward-start.log"; say $? "it is up"
# The three facts that have to agree, read off the machine rather than assumed.
port=$(grep -ao "MENGD_PROXY=127.0.0.1:[0-9]*" "$D/console.log" | head -1 | sed 's/.*://')
[ -n "$port" ]; say $? "the guest was told where the proxy is (port $port)"
grep -qa "mfwd: 0.0.0.0:$port out to vsock port $port" "$D/console.log"
say $? "and a forwarder inside it listens where a CONTAINER can reach it (0.0.0.0, not 127.0.0.1)"

export DOCKER_HOST="unix://$D/docker.sock"
export DOCKER_CONTEXT=
DOCKER_HOST= docker save alpine:latest -o "$out/outward-alpine.tar" 2>/dev/null
docker load -i "$out/outward-alpine.tar" >/dev/null 2>&1; say $? "an image loads"

echo "== on the default bridge =="
e=$(docker run --rm alpine:latest sh -c 'echo $http_proxy' 2>/dev/null | tr -d '\r')
gw=$(docker run --rm alpine:latest sh -c 'ip route | awk "/^default/{print \$3}"' 2>/dev/null | tr -d '\r')
# THE GATEWAY, NOT THE LOOPBACK. 127.0.0.1 inside a container is its own, and
# naming it would send the container's traffic to itself.
[ "$e" = "http://$gw:$port" ]; say $? "it is told the GATEWAY, not 127.0.0.1 ($e, gateway $gw)"
o=$(docker run --rm alpine:latest wget -q -T 20 -O- http://example.com/ 2>&1 | tr -d '\r' | head -c 200)
echo "$o" | grep -q "Example Domain"; say $? "plain http through the proxy reaches the world"
o=$(docker run --rm alpine:latest sh -c 'apk add --no-cache curl >/dev/null 2>&1 && curl -s -o /dev/null -w "%{http_code}" https://example.com/' 2>/dev/null | tr -d '\r')
[ "$o" = 200 ]; say $? "and https by CONNECT ($o) -- which also means apk reached a mirror"

echo "== on a network somebody created =="
docker network create appnet >/dev/null 2>&1; say $? "a network"
docker run -d --name peer --network appnet alpine:latest \
  sh -c 'while true; do printf "HTTP/1.0 200 OK\r\nContent-Length: 3\r\n\r\nhi\n" | nc -l -p 80; done' >/dev/null 2>&1
sleep 2
n=$(docker run --rm --network appnet alpine:latest sh -c 'echo "[$http_proxy]"' 2>/dev/null | tr -d '\r')
[ "$n" = "[]" ]; say $? "a container on it is given NO proxy ($n)"
o=$(docker run --rm --network appnet alpine:latest wget -q -T 5 -O- http://peer/ 2>&1 | tr -d '\r\n')
[ "$o" = "hi" ]; say $? "and still reaches the service next to it by name ($o)"

echo "== the other two namespaces =="
o=$(docker run --rm --network host alpine:latest sh -c 'echo $http_proxy' 2>/dev/null | tr -d '\r')
[ "$o" = "http://127.0.0.1:$port" ]; say $? "--network host IS the machine's namespace, so 127.0.0.1 ($o)"
o=$(docker run --rm --network none alpine:latest sh -c 'echo "[$http_proxy]"' 2>/dev/null | tr -d '\r')
[ "$o" = "[]" ]; say $? "--network none has nowhere to send anything ($o)"

echo "== what the proxy will not do =="
# Not a limitation to work around: terminating TLS on this side would leave the
# caller verifying nothing. Said out loud so that "it did not work" has a name.
o=$(docker run --rm alpine:latest sh -c "wget -q -T 10 -O- 'https://example.com/' 2>&1" | tr -d '\r' | head -c 80)
echo "  note  busybox wget cannot CONNECT, so https from it fails by design: ${o:-<nothing>}"

[ "$fail" = 0 ] && echo "outward PASS" || echo "outward FAIL"
exit "$fail"
