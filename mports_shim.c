/* mports_shim.c — the two sockets mports talks on, and nothing else.
 *
 * One is the Docker API socket the VMM carries into the guest; the other is
 * the VMM's own control socket. Both are AF_UNIX on this machine, so this is
 * connect, send, read-to-end, close -- not a socket layer.
 */
#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <sys/socket.h>
#include <sys/un.h>

int mp_connect(const char *path) {
    /* A daemon that dies because a peer hung up is no use to anyone, and this
     * one writes to sockets whose far end is a VM. */
    signal(SIGPIPE, SIG_IGN);
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    if (strlen(path) >= sizeof a.sun_path) return -2;
    strcpy(a.sun_path, path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    return fd;
}

int mp_send(int fd, const char *s) {
    size_t len = strlen(s), off = 0;
    while (off < len) {
        ssize_t n = write(fd, s + off, len - off);
        if (n <= 0) return -1;
        off += (size_t)n;
    }
    return (int)off;
}

/* Everything the peer sends, up to a bound, with a deadline. Returns "" rather
 * than blocking forever: this runs in a loop that has to keep running. */
#define MP_MAX (256 * 1024)
static char MP_BUF[MP_MAX + 1];
const char *mp_recv(int fd, int timeout_ms) {
    size_t n = 0;
    for (;;) {
        struct pollfd pf; pf.fd = fd; pf.events = POLLIN; pf.revents = 0;
        if (poll(&pf, 1, timeout_ms) <= 0) break;
        ssize_t r = read(fd, MP_BUF + n, MP_MAX - n);
        if (r <= 0) break;
        n += (size_t)r;
        if (n >= MP_MAX) break;
    }
    MP_BUF[n] = 0;
    return MP_BUF;
}

int mp_close(int fd) { return close(fd); }
