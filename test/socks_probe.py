#!/usr/bin/env python3
"""One SOCKS5 exchange, reported as two numbers: the method the proxy chose and
the reply code it gave. Written out rather than driven with printf because the
bytes are the point and an escape that the shell renders differently would be
measuring the shell."""
import socket, sys
host, port, cmd, target, tport = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4], int(sys.argv[5])
s = socket.create_connection((host, port), timeout=20)
s.sendall(b"\x05\x01\x00")
g = s.recv(2)
if len(g) < 2:
    print("nogreeting"); sys.exit(0)
name = target.encode()
s.sendall(bytes([5, cmd, 0, 3, len(name)]) + name + tport.to_bytes(2, "big"))
r = s.recv(10)
s.close()
if len(r) < 2:
    print("noreply"); sys.exit(0)
print("%d %d" % (g[1], r[1]))
