/* guest/fwd_shim.c — the sockets mfwd needs, and nothing else.
 *
 * One end is an AF_VSOCK port the VMM delivers host connections to; the other
 * is an ordinary TCP port on the guest's loopback, where the container is
 * listening. Between them this copies bytes, which is all a forwarder is.
 */
#define _GNU_SOURCE
#include <sched.h>
#include <stdio.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <linux/vm_sockets.h>

int fw_listen(int port) {
    struct sockaddr_vm a;
    memset(&a, 0, sizeof a);
    a.svm_family = AF_VSOCK;
    a.svm_cid = VMADDR_CID_ANY;
    a.svm_port = (unsigned)port;
    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (bind(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    if (listen(fd, 16) < 0) { close(fd); return -1; }
    return fd;
}

int fw_accept(int fd) { int c = accept(fd, 0, 0); return c < 0 ? -1 : c; }

/* The other direction. Something in this guest wants to reach the host -- a
 * registry, say -- and has no network to do it on. It connects to a port on
 * this machine's loopback, which is here, and this carries it out on vsock.
 *
 * The VMM decides where a vsock port leads; this only says which one. */
int fw_listen_local(int port) {
    struct sockaddr_in in;
    memset(&in, 0, sizeof in);
    in.sin_family = AF_INET;
    in.sin_addr.s_addr = htonl(INADDR_ANY);   /* the guest's own, not the world's */
    in.sin_port = htons((unsigned short)port);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (bind(fd, (struct sockaddr *)&in, sizeof in) < 0) { close(fd); return -1; }
    if (listen(fd, 16) < 0) { close(fd); return -1; }
    return fd;
}

int fw_connect_vsock(int port) {
    struct sockaddr_vm a;
    memset(&a, 0, sizeof a);
    a.svm_family = AF_VSOCK;
    a.svm_cid = VMADDR_CID_HOST;      /* 2 */
    a.svm_port = (unsigned)port;
    int fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&a, sizeof a) < 0) { close(fd); return -1; }
    return fd;
}
static int fw_connect_local(int port);
int fw_close(int fd) { return close(fd); }

/* The container's port, inside the container's own network namespace.
 *
 * ONE CALL, because setns and connect have to happen on the SAME THREAD --
 * setns moves the calling thread and nothing else. Two calls from Mere would
 * be two calls the runtime is free to schedule anywhere, and the connect would
 * then be made from the guest's namespace, where nothing is listening. The
 * invariant is enforced here rather than written down.
 *
 * pid <= 0 means the guest's own namespace, which is where a container started
 * with --network host is listening.
 */
int fw_connect_in(int pid, int port) {
    if (pid > 0) {
        char p[64];
        snprintf(p, sizeof p, "/proc/%d/ns/net", pid);
        int nsfd = open(p, O_RDONLY);
        if (nsfd < 0) return -2;                 /* no such container any more */
        int r = setns(nsfd, CLONE_NEWNET);
        close(nsfd);
        if (r != 0) return -3;                   /* named: not the same as "refused" */
    }
    return fw_connect_local(port);
}

int fw_connect_local(int port) {
    struct sockaddr_in in;
    memset(&in, 0, sizeof in);
    in.sin_family = AF_INET;
    in.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    in.sin_port = htons((unsigned short)port);
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    if (connect(fd, (struct sockaddr *)&in, sizeof in) < 0) { close(fd); return -1; }
    return fd;
}

/* Copy until BOTH directions have ended.
 *
 * A half-close is not a close: a client that has sent its request and shut
 * down its write side is still waiting for the answer. Ending the whole
 * forward on the first end-of-file is the bug this project already found once,
 * on the other side of the same wire, so it is not repeated here -- each
 * direction is shut down on its own and the loop runs until both are done.
 */
int fw_pipe(int a, int b) {
    char buf[65536];
    int a_done = 0, b_done = 0;
    while (!a_done || !b_done) {
        struct pollfd pf[2];
        int n = 0;
        int ia = -1, ib = -1;
        if (!a_done) { pf[n].fd = a; pf[n].events = POLLIN; pf[n].revents = 0; ia = n; n++; }
        if (!b_done) { pf[n].fd = b; pf[n].events = POLLIN; pf[n].revents = 0; ib = n; n++; }
        if (n == 0) break;
        if (poll(pf, (nfds_t)n, 60000) <= 0) break;
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
