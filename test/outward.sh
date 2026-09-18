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
# TWO THINGS, ASKED SEPARATELY. This was one line -- apk installs curl, curl
# fetches over TLS -- and when it failed it said "()" and could not say which
# half. They are also different kinds of failure: the second is this machine's
# way out, and the first is somebody's package mirror.
docker run --rm alpine:latest sh -c 'apk add --no-cache curl >/dev/null 2>&1 && command -v curl >/dev/null' 2>/dev/null
apk=$?
if [ "$apk" != 0 ]; then
  # WHOSE FAILURE IS IT. If this host cannot reach the mirror either, nothing
  # about the guest has been measured and calling it red would be a lie in the
  # more expensive direction.
  if curl -s -o /dev/null --max-time 10 https://dl-cdn.alpinelinux.org/alpine/ 2>/dev/null; then
    say 1 "apk could not reach a mirror through the proxy (this host can)"
  else
    echo "  SKIP  no route to the alpine mirror from this host either -- the TLS check needs one"
  fi
else
  say 0 "apk reached a mirror through the proxy and installed curl"
  o=$(docker run --rm alpine:latest sh -c 'apk add --no-cache curl >/dev/null 2>&1; curl -s -o /dev/null -w "%{http_code}" --max-time 20 https://example.com/' 2>/dev/null | tr -d '\r')
  [ "$o" = 200 ]; say $? "and https by CONNECT ($o)"
fi

echo "== and the same port answers SOCKS5, for what does not speak HTTP =="
# WHY THERE IS A SECOND PROTOCOL. The four *_PROXY names reach only clients
# that speak HTTP to a proxy. The guest has no resolver and no route, so
# everything else -- git over ssh, a database client, anything reading
# ALL_PROXY -- could not get out at all. A route would want NAT, and this
# guest's kernel has neither nf_nat nor a tun device (measured: /proc has the
# netfilter core and nothing that does address translation). SOCKS5 needs none
# of that: it is the same two sockets, and the first byte says which protocol
# is being spoken.
a=$(docker run --rm alpine:latest sh -c 'echo $ALL_PROXY' 2>/dev/null | tr -d '\r')
[ "$a" = "socks5h://$gw:$port" ]; say $? "a container is told the same address as SOCKS ($a)"
# socks5h, not socks5: the h is "the proxy resolves the name". Without it the
# client resolves first, and this guest cannot.
case "$a" in socks5h://*) true;; *) false;; esac
say $? "and with the h, so the name is resolved by the end that can"
# THREE ANSWERS, ASKED AS BYTES. A proxy that accepted everything and a proxy
# that worked would both pass a check that only fetched a page.
r=$(python3 "$here/test/socks_probe.py" 127.0.0.1 "$port" 1 example.com 443 2>/dev/null)
[ "$r" = "0 0" ]; say $? "CONNECT through it succeeds (method/reply: $r)"
r=$(python3 "$here/test/socks_probe.py" 127.0.0.1 "$port" 2 example.com 443 2>/dev/null)
[ "$r" = "0 7" ]; say $? "a command it does not implement is refused BY CODE, not by hanging ($r)"
r=$(python3 "$here/test/socks_probe.py" 127.0.0.1 "$port" 1 no-such-host.invalid 443 2>/dev/null)
[ "$r" = "0 4" ]; say $? "and a name that does not exist says so ($r)"
if [ "$apk" = 0 ]; then
  o=$(docker run --rm alpine:latest sh -c 'apk add --no-cache curl >/dev/null 2>&1;
      curl -s -o /dev/null -w "%{http_code}" --max-time 25 --socks5-hostname '"$gw"':'"$port"' https://example.com/' 2>/dev/null | tr -d '\r')
  [ "$o" = 200 ]; say $? "and a container reaches the world through SOCKS ($o)"
fi

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

echo "== and the same machine started with --proxy-everywhere =="
# WHAT THE DEFAULT COSTS, AND THE WAY OUT OF IT.
#
# A network somebody created is given no proxy, which is the right default for
# a network whose members were named on purpose -- but `docker compose` creates
# one for every project, so by default a compose service cannot reach anything
# outside. Measured on the default above: zero proxy variables and plain http
# fails. The daemon has always had the switch; nothing on the host could ask
# for it.
#
# The same machine, restarted: the default is not being changed, an option is
# being added, so this checks BOTH -- the lines above are the other half.
sh "$here/tools/mvm" stop --name "$M" >/dev/null 2>&1
sh "$here/tools/mvm" start --name "$M" --proxy-everywhere > "$out/outward-pe.log" 2>&1
say $? "mvm start --proxy-everywhere"
p2=$(sed -n 's/.*proxy on \([0-9][0-9]*\).*/\1/p' "$out/outward-pe.log" | head -1)
docker network create appnet2 >/dev/null 2>&1
n=$(docker run --rm --network appnet2 alpine:latest sh -c 'echo "[$http_proxy]"' 2>/dev/null | tr -d '\r')
[ "$n" != "[]" ]; say $? "now a container on a created network IS told where the proxy is ($n)"
o=$(docker run --rm --network appnet2 alpine:latest wget -q -T 10 -O- http://example.com/ 2>&1 | head -c 12)
[ -n "$o" ]; say $? "and plain http from it reaches the world"
o=$(docker run --rm --network none alpine:latest sh -c 'echo "[$http_proxy]"' 2>/dev/null | tr -d '\r')
[ "$o" = "[]" ]; say $? "--network none still has nowhere to send anything ($o)"

[ "$fail" = 0 ] && echo "outward PASS" || echo "outward FAIL"
exit "$fail"
