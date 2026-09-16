/* guest/vsock_client.c — the guest half of the vsock check.
 *
 * busybox's nc does not speak AF_VSOCK and the guest has no compiler, so this
 * is built for linux/arm64 in a container and put into the initramfs. It
 * connects to the host (CID 2), says something, reads the reply, and reports
 * through the exit status -- which is the channel that works before anything
 * else does.
 */
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <linux/vm_sockets.h>
#include <stdlib.h>

/* Exactly n bytes, however many reads it takes. A short read is the normal
 * case on a stream and treating it as the whole answer is how a test comes out
 * green on a device that delivered a fraction. */
static int read_n(int s, unsigned char *p, int n) {
    int off = 0;
    while (off < n) {
        ssize_t r = read(s, p + off, (size_t)(n - off));
        if (r <= 0) return off;
        off += (int)r;
    }
    return off;
}

static int bulk(int s, int n) {
    unsigned char *out = malloc((size_t)n), *in = malloc((size_t)n);
    if (!out || !in) return 20;
    for (int i = 0; i < n; i++) out[i] = (unsigned char)(i & 0xff);
    int off = 0;
    while (off < n) {
        ssize_t w = write(s, out + off, (size_t)(n - off));
        if (w <= 0) { printf("vsock-client: write stopped at %d\n", off); return 21; }
        off += (int)w;
    }
    int got = read_n(s, in, n);
    if (got != n) { printf("vsock-client: read %d of %d bytes\n", got, n); return 22; }
    /* The content, not the count. A device that repeated one buffer or handed
     * them over out of order moves exactly the right number of bytes. */
    for (int i = 0; i < n; i++)
        if (in[i] != (unsigned char)((i + 1) & 0xff)) {
            printf("vsock-client: byte %d is 0x%02x, expected 0x%02x\n",
                   i, in[i], (unsigned char)((i + 1) & 0xff));
            return 23;
        }
    printf("vsock-client: bulk ok %d bytes each way\n", n);
    return 0;
}

int main(int argc, char **argv) {
    unsigned port = argc > 1 ? (unsigned)atoi(argv[1]) : 1234;
    const char *msg = argc > 2 ? argv[2] : "hello from the guest";
    int s = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (s < 0) { perror("socket"); return 10; }
    struct sockaddr_vm a;
    memset(&a, 0, sizeof a);
    a.svm_family = AF_VSOCK;
    a.svm_cid = VMADDR_CID_HOST;      /* 2 */
    a.svm_port = port;
    if (connect(s, (struct sockaddr *)&a, sizeof a) != 0) { perror("connect"); return 11; }
    if (argc > 3 && !strcmp(msg, "bulk")) return bulk(s, atoi(argv[3]));
    if (write(s, msg, strlen(msg)) < 0) { perror("write"); return 12; }
    char buf[256];
    ssize_t n = read(s, buf, sizeof buf - 1);
    if (n < 0) { perror("read"); return 13; }
    buf[n] = 0;
    printf("vsock-client: got %zd bytes: %s\n", n, buf);
    return 0;
}
