# test/vsock_host.py -- the host end of the vsock check.
#
#   vsock_host.py <unix socket path> [bulk bytes]
#
# It serves exactly two connections, because two is what the check needs:
#
#   1. a short message. The reply is DERIVED from what arrived rather than
#      echoed -- an echo cannot tell "the bytes made the round trip" apart from
#      "the guest is looking at its own transmit buffer".
#   2. a bulk stream, if a size was given. One short message fits in a single
#      receive buffer and so never asks the device whether credit, refill or
#      ordering work. Every byte is transformed and every byte is checked; a
#      device that repeated a buffer or handed them over out of order moves
#      exactly the right NUMBER of bytes.
#
# Two connections also means the second one is a REUSE of a device that has
# already closed a stream, which is its own thing to get wrong.
import os, socket, sys

path = sys.argv[1]
bulk = int(sys.argv[2]) if len(sys.argv) > 2 else 0
try: os.unlink(path)
except FileNotFoundError: pass
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.bind(path); s.listen(2)
print("listening", flush=True)

def serve_message(c):
    data = c.recv(65536)
    c.sendall(("host saw %d bytes: %s"
               % (len(data), data.decode("utf-8", "replace").upper())).encode())

def serve_bulk(c, n):
    buf = bytearray()
    while len(buf) < n:
        b = c.recv(n - len(buf))
        if not b: break
        buf += b
    print("bulk received %d of %d" % (len(buf), n), flush=True)
    bad = next((i for i, v in enumerate(buf) if v != (i & 0xff)), -1)
    print("bulk content %s" % ("ok" if bad < 0 else "wrong at %d" % bad), flush=True)
    c.sendall(bytes(((v + 1) & 0xff) for v in buf))

for which in range(2 if bulk else 1):
    c, _ = s.accept()
    if which == 0: serve_message(c)
    else: serve_bulk(c, bulk)
    c.close()
s.close()
os.unlink(path)
