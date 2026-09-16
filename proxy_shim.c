/* proxy_shim.c — the sockets mproxy needs.
 *
 * A CONNECT proxy is two sockets and a copy loop. The only part that is not
 * obvious is that it must not end the whole forward on the first end of file:
 * a client that has sent its request and shut down its write side is still
 * waiting for the answer. That is the same mistake this project already made
 * once, on the other side of the same wire, so each direction ends on its own
 * here and the loop runs until both are done.
 */
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>

int px_listen(int port) {
    /* A proxy that dies because a client hung up is no use to anyone. */
    signal(SIGPIPE, SIG_IGN);
    struct sockaddr_in in;
    memset(&in, 0, sizeof in);
    in.sin_family = AF_INET;
    /* Loopback only. What is on the other side of this is a virtual machine
     * asking to reach the internet, and that is not something to offer the
     * network this machine happens to be on. */
    in.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    in.sin_port = htons((unsigned short)port);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (bind(fd, (struct sockaddr *)&in, sizeof in) < 0) { close(fd); return -1; }
    if (listen(fd, 32) < 0) { close(fd); return -1; }
    return fd;
}

int px_accept(int fd) { int c = accept(fd, 0, 0); return c < 0 ? -1 : c; }
int px_close(int fd) { return close(fd); }

/* One line, without its newline. "" at end of file or after a wait. */
static _Thread_local char PX_LINE[2048];
const char *px_line(int fd) {
    size_t n = 0;
    while (n + 1 < sizeof PX_LINE) {
        struct pollfd pf; pf.fd = fd; pf.events = POLLIN; pf.revents = 0;
        if (poll(&pf, 1, 10000) <= 0) break;
        char c;
        if (read(fd, &c, 1) <= 0) break;
        if (c == '\n') break;
        if (c != '\r') PX_LINE[n++] = c;
    }
    PX_LINE[n] = 0;
    return PX_LINE;
}

int px_write(int fd, const char *s) {
    size_t len = strlen(s), off = 0;
    while (off < len) {
        ssize_t w = write(fd, s + off, len - off);
        if (w <= 0) return -1;
        off += (size_t)w;
    }
    return (int)off;
}

/* Connect to a name. This is the half the guest cannot do: it has no resolver
 * and no route, which is the whole reason it is asking. */
int px_connect(const char *host, int port) {
    char portstr[16];
    snprintf(portstr, sizeof portstr, "%d", port);
    struct addrinfo hints, *res = NULL, *ai;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, portstr, &hints, &res) != 0 || !res) return -2;
    int fd = -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd); fd = -1;
    }
    freeaddrinfo(res);
    return fd < 0 ? -1 : fd;
}

/* Copy until BOTH directions have ended. */
int px_pipe(int a, int b) {
    char buf[65536];
    int a_done = 0, b_done = 0;
    while (!a_done || !b_done) {
        struct pollfd pf[2];
        int n = 0, ia = -1, ib = -1;
        if (!a_done) { pf[n].fd = a; pf[n].events = POLLIN; pf[n].revents = 0; ia = n; n++; }
        if (!b_done) { pf[n].fd = b; pf[n].events = POLLIN; pf[n].revents = 0; ib = n; n++; }
        if (n == 0) break;
        if (poll(pf, (nfds_t)n, 120000) <= 0) break;
        for (int k = 0; k < n; k++) {
            if (!(pf[k].revents & (POLLIN | POLLHUP | POLLERR))) continue;
            int from = (k == ia) ? a : b;
            int to   = (k == ia) ? b : a;
            ssize_t r = read(from, buf, sizeof buf);
            if (r > 0) {
                ssize_t off = 0;
                while (off < r) {
                    ssize_t w = write(to, buf + off, (size_t)(r - off));
                    if (w <= 0) { a_done = b_done = 1; break; }
                    off += w;
                }
            } else {
                shutdown(to, SHUT_WR);
                if (k == ia) a_done = 1; else b_done = 1;
            }
        }
    }
    close(a); close(b);
    return 0;
}
