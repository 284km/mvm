#!/bin/sh
# test/app.sh — an application, not a feature.
#
# Every other check here asks whether one thing works. This one asks the
# question the whole project exists to answer: can somebody put a small
# application on this and use it, the way they would with the thing it
# replaces? So it uses the pieces TOGETHER, in the order a person would:
#
#   compose up           a service whose image came from a Dockerfile
#   two services         talking to each other by name
#   a named volume       that survives the container that wrote it
#   a published port     reached from macOS with curl
#   docker exec          to look inside while it runs
#   docker cp            to take something out
#   docker compose down  and nothing left behind
#
# None of that is new here. What is new is that it is one story: a feature that
# works alone and breaks in company is a feature nobody can use, and only this
# shape of check can see it.
#
# It reuses what stack.sh built -- run that first.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/.build"
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
command -v docker >/dev/null 2>&1 || { echo "needs a docker client" >&2; exit 2; }
for f in mvm-boot stack.dtb rootfs.img Image alpine.tar; do
  [ -r "$out/$f" ] || { echo "no $out/$f -- run test/stack.sh first" >&2; exit 2; }
done
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }
SECS="${SECS:-240}"
SOCK="$out/app.sock"
rm -f "$SOCK" "$out/app.ctl"
cp "$out/rootfs.img" "$out/rootfs-app.img"

MVM_VSOCK_IN="$SOCK=1024,tcp:18099=18099" \
MVM_CONTROL="$out/app.ctl" \
MVM_TIMEOUT_MS=$((SECS * 1000)) \
    "$out/mvm-boot" "$out/Image" "$out/stack.dtb" "" "$out/rootfs-app.img" \
    > "$out/app-console.txt" 2> "$out/app-vmm.txt" &
VMPID=$!
i=0; while [ "$i" -lt 240 ]; do
  grep -qa "listening on" "$out/app-console.txt" 2>/dev/null && break
  sleep 0.5; i=$((i + 1))
done
grep -qa "listening on" "$out/app-console.txt"; say $? "the machine is up"
export DOCKER_HOST=
d() { docker -H "unix://$SOCK" "$@"; }

d load -i "$out/alpine.tar" >/dev/null 2>&1; say $? "the base image is there"

# THE IMAGE IS BUILT HERE, NOT THROUGH THE VM, and that is a limit of the
# CLIENT rather than of this stack. Measured: on this macOS docker CLI
# (29.8.0), `DOCKER_BUILDKIT=0 docker build` and `docker compose build` hang
# forever -- against the REAL docker as well, with no output and no image --
# while the same build with BuildKit finishes instantly. BuildKit needs
# /session and a builder container, which is a different daemon feature.
#
# So the build itself is checked where the client is Linux and the legacy
# builder works: mengd's own gate does COPY, ADD, the cache and one layer per
# step. What this file is for is the REST of the story, and it still gets an
# image that came out of a Dockerfile.
app="$out/app"; rm -rf "$app"; mkdir -p "$app/web"
# A service built here, from a Dockerfile, with a file copied into it -- the
# ordinary way an application arrives.
cat > "$app/web/Dockerfile" <<'DF'
FROM alpine:latest
COPY index.txt /srv/index.txt
CMD ["sh","-c","n=$(wc -c < /srv/index.txt | tr -d ' \\n'); while true; do { printf 'HTTP/1.1 200 OK\r\nContent-Length: %s\r\n\r\n' \"$n\"; cat /srv/index.txt; } | nc -l -p 80; done"]
DF
printf 'hello-from-the-app' > "$app/web/index.txt"
# A healthcheck and a dependency on it, because that is how a real compose file
# says "not until the other one is up" -- and the alternative, sleeping and
# hoping, is what makes a stack that works on one machine and not on another.
cat > "$app/compose.yaml" <<'YAML'
services:
  web:
    image: app-web:v1
    ports: ["18099:80"]
    healthcheck:
      test: ["CMD", "sh", "-c", "echo x | nc -w 1 127.0.0.1 80"]
      interval: 2s
      retries: 5
  worker:
    image: alpine:latest
    depends_on:
      web:
        condition: service_healthy
    volumes: ["work:/data"]
    command: ["sh","-c","(echo probe | nc -w 3 web 80 | tail -1) > /data/seen.txt; sleep 300"]
volumes:
  work:
YAML

echo "== the image the application is made of =="
DOCKER_HOST= docker build -q -t app-web:v1 "$app/web" >/dev/null 2>&1
say $? "built from its Dockerfile"
DOCKER_HOST= docker save app-web:v1 -o "$out/app-web.tar" 2>/dev/null
d load -i "$out/app-web.tar" >/dev/null 2>&1; say $? "and loaded into the machine"

echo "== compose up =="
( cd "$app" && docker -H "unix://$SOCK" compose -p app up -d ) > "$out/app-up.log" 2>&1
say $? "docker compose up"
grep -q "Healthy" "$out/app-up.log"
say $? "it waited for the first service to be HEALTHY before starting the second"
sleep 6

echo "== the application answers =="
o=$(curl -s --max-time 10 http://127.0.0.1:18099/ 2>/dev/null)
[ "$o" = "hello-from-the-app" ]; say $? "macOS reaches the published port ($o)"

echo "== the other service reached it by name, and kept what it saw =="
w=$(d exec app-worker-1 cat /data/seen.txt 2>/dev/null | tr -d '\r\n')
[ "$w" = "hello-from-the-app" ]; say $? "the worker got the same answer over the network ($w)"

echo "== looking inside while it runs =="
o=$(d exec app-web-1 cat /srv/index.txt 2>/dev/null | tr -d '\r\n')
[ "$o" = "hello-from-the-app" ]; say $? "docker exec sees the file COPY put in the image ($o)"
rm -f "$out/from-app.txt"
d cp app-worker-1:/data/seen.txt "$out/from-app.txt" >/dev/null 2>&1
[ "$(cat "$out/from-app.txt" 2>/dev/null | tr -d '\r\n')" = "hello-from-the-app" ]
say $? "docker cp takes it out to macOS"

echo "== the volume outlives the container that wrote it =="
d rm -f app-worker-1 >/dev/null 2>&1
d run --rm -v app_work:/data alpine:latest cat /data/seen.txt > "$out/vol.txt" 2>/dev/null
[ "$(tr -d '\r\n' < "$out/vol.txt")" = "hello-from-the-app" ]
say $? "a new container on the same volume finds it ($(tr -d '\r\n' < "$out/vol.txt"))"

echo "== and it all goes away =="
( cd "$app" && docker -H "unix://$SOCK" compose -p app down -v ) >> "$out/app-up.log" 2>&1
say $? "docker compose down -v"
# THIS PROJECT'S, not the machine's. The disk image carries whatever earlier
# runs left in it, and counting everything says the cleanup failed when what it
# found was history. `down` is responsible for what `up` made and nothing else.
n=$(d ps -a --format '{{.Names}}' 2>/dev/null | grep -c "^app-" || true)
[ "$n" = 0 ]; say $? "no container of this project is left ($n)"
nn=$(d network ls --format '{{.Name}}' 2>/dev/null | grep -c "^app_default$" || true)
[ "$nn" = 0 ]; say $? "its network is gone ($nn)"
nb=$(d network ls --format '{{.Name}}' 2>/dev/null | grep -c "^bridge$" || true)
[ "$nb" = 1 ]; say $? "and the default bridge is NOT, which down tried to remove ($nb)"
curl -s --max-time 3 http://127.0.0.1:18099/ >/dev/null 2>&1
[ $? != 0 ]; say $? "and the published port stopped answering"

kill "$VMPID" 2>/dev/null; wait "$VMPID" 2>/dev/null
rm -f "$out/rootfs-app.img" "$SOCK" "$out/app.ctl"
[ "$fail" = 0 ] && echo "app PASS" || echo "app FAIL"
exit "$fail"
