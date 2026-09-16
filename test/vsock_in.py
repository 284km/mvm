# test/vsock_in.py -- the host half of the inward check.
#
#   vsock_in.py <unix socket path> <message> [retry seconds]
#
# It RETRIES. The VMM's listening socket exists from startup, but the server
# inside the guest does not: a connection that arrives first is refused by the
# guest with an RST, which reaches the host as an empty stream. That is the
# correct behaviour of both ends and it is indistinguishable from failure in a
# single attempt, so the attempt is what has to be repeated.
import socket, sys, time

path, msg = sys.argv[1], sys.argv[2]
limit = float(sys.argv[3]) if len(sys.argv) > 3 else 20.0
deadline = time.time() + limit
attempts = 0
while time.time() < deadline:
    attempts += 1
    try:
        c = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        c.settimeout(2.0)
        c.connect(path)
        c.sendall(msg.encode())
        data = c.recv(65536)
        c.close()
        if data:
            print("host got %d bytes after %d attempts: %s"
                  % (len(data), attempts, data.decode("utf-8", "replace")), flush=True)
            sys.exit(0)
    except (FileNotFoundError, ConnectionRefusedError, socket.timeout, OSError):
        pass
    time.sleep(0.25)
print("host gave up after %d attempts" % attempts, flush=True)
sys.exit(1)
