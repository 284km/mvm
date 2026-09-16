#!/bin/sh
# test/two.sh — two machines at once.
#
# Everything this project has built so far assumed one: one VM, one docker
# socket, one control socket, one set of published ports. The note that planned
# it said the second machine would need the control socket to say WHICH machine
# it meant -- the first place where a number is not enough and a name is.
#
# It turned out not to. Every path is already an argument or an environment
# variable, so a second machine is a second set of them. That is worth a check
# rather than a claim: "it should work" and "it works" differ exactly here, and
# a shared path that nobody noticed would show up as two guests writing to one
# disk, or one answering for the other.
#
# WHAT IS BEING JUDGED: that the two are SEPARATE. Both answering is not
# enough -- one VM answering on two sockets would do that. A container made in
# one must not be visible in the other, their published ports must reach their
# own guest, and killing one must leave the other alone.
#
# It reuses what stack.sh built: run that first.
set -u
here="$(cd "$(dirname "$0")/.." && pwd)"
out="$here/.build"
case "$(uname -sm)" in "Darwin arm64") ;; *) echo "needs macOS on Apple silicon" >&2; exit 2;; esac
command -v docker >/dev/null 2>&1 || { echo "needs a docker client as the oracle" >&2; exit 2; }
for f in mvm-boot stack.dtb rootfs.img Image alpine.tar; do
  [ -r "$out/$f" ] || { echo "no $out/$f -- run test/stack.sh first" >&2; exit 2; }
done
fail=0
say() { [ "$1" = 0 ] && echo "  ok    $2" || { echo "  FAIL  $2"; fail=1; }; }
# A name that cannot be left over. The disks keep whatever a previous run put
# in them, so a fixed name made this check answer "the second can see it" --
# about a container the PREVIOUS run had created, in a disk image that was
# copied afterwards. The state is real; the name has to be new.
RID="$$"
SECS="${SECS:-150}"

# Its own disk. Two guests writing to one image is the first thing that would
# go wrong, and it would go wrong quietly.
cp "$out/rootfs.img" "$out/rootfs-b.img"
rm -f "$out/a.sock" "$out/b.sock" "$out/a.ctl" "$out/b.ctl"

boot() {  # boot <letter> <disk> <docker port> <published port>
  MVM_VSOCK_IN="$out/$1.sock=1024,tcp:$4=$4" \
  MVM_CONTROL="$out/$1.ctl" \
  MVM_TIMEOUT_MS=$((SECS * 1000)) \
      "$out/mvm-boot" "$out/Image" "$out/stack.dtb" "" "$2" \
      > "$out/$1-console.txt" 2> "$out/$1-vmm.txt" &
  eval "PID_$1=\$!"
  i=0
  while [ "$i" -lt 240 ]; do
    grep -qa "listening on" "$out/$1-console.txt" 2>/dev/null && return 0
    sleep 0.5; i=$((i + 1))
  done
  return 1
}

echo "== two machines =="
boot a "$out/rootfs.img"   1024 18091; say $? "the first came up"
boot b "$out/rootfs-b.img" 1024 18092; say $? "the second came up beside it"

da() { docker -H "unix://$out/a.sock" "$@"; }
db() { docker -H "unix://$out/b.sock" "$@"; }
export DOCKER_HOST=

va=$(da version --format '{{.Server.Version}}' 2>/dev/null)
vb=$(db version --format '{{.Server.Version}}' 2>/dev/null)
[ -n "$va" ] && [ "$va" = "$vb" ]; say $? "both answer their own socket ($va, $vb)"

echo "== they are not the same machine =="
# By NAME, not by count. Both disks are copies of one image that a previous run
# left images and containers in, so counting says they are sharing when they
# are not -- the first version of this check did exactly that and called it a
# failure. What separateness means is that a thing made HERE is not THERE.
da load -i "$out/alpine.tar" >/dev/null 2>&1; say $? "an image loaded into the first"
da tag alpine:latest only-in-a-$RID:v1 >/dev/null 2>&1 || da image tag alpine:latest only-in-a-$RID:v1 >/dev/null 2>&1
db load -i "$out/alpine.tar" >/dev/null 2>&1; say $? "and into the second"

da run -d --name "only-in-a-$RID" alpine:latest sh -c 'sleep 60' >/dev/null 2>&1
say $? "a container named only-in-a-$RID, in the first"
da ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^only-in-a-$RID$"
say $? "the first can see it"
db ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^only-in-a-$RID$"
[ $? != 0 ]; say $? "the second cannot"
db run -d --name "only-in-b-$RID" alpine:latest sh -c 'sleep 60' >/dev/null 2>&1
da ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^only-in-b-$RID$"
[ $? != 0 ]; say $? "and the reverse is true as well"

echo "== each published port reaches its own guest =="
# The host's end of each was opened by its own VMM, from its own environment.
# Answering on the wrong one would mean the two VMMs share a mapping.
da run -d --name web-a -p 18091:80 alpine:latest \
   sh -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nFIRST" | nc -l -p 80; done' >/dev/null 2>&1
db run -d --name web-b -p 18092:80 alpine:latest \
   sh -c 'while true; do printf "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nSECOND" | nc -l -p 80; done' >/dev/null 2>&1
sleep 6
oa=$(curl -s --max-time 8 http://127.0.0.1:18091/ 2>/dev/null)
ob=$(curl -s --max-time 8 http://127.0.0.1:18092/ 2>/dev/null)
[ "$oa" = "FIRST" ]; say $? "18091 reaches the first guest ($oa)"
[ "$ob" = "SECOND" ]; say $? "18092 reaches the second ($ob)"

echo "== one stops, the other does not =="
kill "$PID_a" 2>/dev/null; wait "$PID_a" 2>/dev/null
i=0; while [ "$i" -lt 20 ] && curl -s --max-time 1 http://127.0.0.1:18091/ >/dev/null 2>&1; do sleep 0.5; i=$((i + 1)); done
curl -s --max-time 3 http://127.0.0.1:18091/ >/dev/null 2>&1
[ $? != 0 ]; say $? "the first is gone"
ob2=$(curl -s --max-time 8 http://127.0.0.1:18092/ 2>/dev/null)
[ "$ob2" = "SECOND" ]; say $? "and the second still answers ($ob2)"
vb2=$(db version --format '{{.Server.Version}}' 2>/dev/null)
[ "$vb2" = "$vb" ]; say $? "including on its docker socket ($vb2)"

kill "$PID_b" 2>/dev/null; wait "$PID_b" 2>/dev/null
rm -f "$out/rootfs-b.img" "$out/a.sock" "$out/b.sock" "$out/a.ctl" "$out/b.ctl"
[ "$fail" = 0 ] && echo "two PASS" || echo "two FAIL"
exit "$fail"
