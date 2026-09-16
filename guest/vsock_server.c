/* guest/vsock_server.c — the guest half of the inward check.
 *
 * A server INSIDE the VM, which is the direction a container daemon needs: the
 * host connects to a socket on the host's filesystem and reaches this. The
 * reply is derived from what arrived rather than echoed, for the same reason
 * it is on the other side -- an echo cannot tell "the bytes crossed" apart
 * from "the caller is looking at its own buffer".
 *
 *   vsock_server <port> <how many connections to serve>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>
#include <sys/socket.h>
#include <linux/vm_sockets.h>

int main(int argc, char **argv) {
    unsigned port = argc > 1 ? (unsigned)atoi(argv[1]) : 1024;
    int want = argc > 2 ? atoi(argv[2]) : 1;
    int s = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 10; }
    struct sockaddr_vm a;
    memset(&a, 0, sizeof a);
    a.svm_family = AF_VSOCK;
    a.svm_cid = VMADDR_CID_ANY;
    a.svm_port = port;
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0) { perror("bind"); return 11; }
    if (listen(s, 8) != 0) { perror("listen"); return 12; }
    printf("vsock-server: listening on port %u\n", port);
    fflush(stdout);
    for (int i = 0; i < want; i++) {
        int c = accept(s, NULL, NULL);
        if (c < 0) { perror("accept"); return 13; }
        char buf[4096];
        ssize_t n = read(c, buf, sizeof buf - 1);
        if (n < 0) { perror("read"); return 14; }
        buf[n] = 0;
        for (char *p = buf; *p; p++) *p = (char)toupper((unsigned char)*p);
        char out[4200];
        int m = snprintf(out, sizeof out, "guest saw %zd bytes: %s", n, buf);
        if (write(c, out, (size_t)m) < 0) { perror("write"); return 15; }
        close(c);
        printf("vsock-server: served %zd bytes\n", n);
        fflush(stdout);
    }
    close(s);
    return 0;
}
