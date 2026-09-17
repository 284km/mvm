/* hv_shim.c — Hypervisor.framework, behind a flat integer API.
 *
 * WHY A SHIM AT ALL, when hv_* is already a C API: the FFI boundary's `int` is
 * C's `int`, 32 bits. A guest physical address fits in that only while the
 * guest is small, and a register VALUE never does. So 64-bit quantities cross
 * as hex strings, which are explicit, printable, and wrong in a way that shows
 * up immediately rather than as a silently truncated address.
 *
 * The vCPU belongs to the thread that created it, so every call here has to
 * happen on one thread. The caller keeps to that; nothing is checked.
 */
#include <Hypervisor/Hypervisor.h>
#include <inttypes.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <time.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <netdb.h>
#include <errno.h>
#include <poll.h>
#include <signal.h>

static hv_vcpu_t VCPU;
static hv_vcpu_exit_t *EXIT;
static void *RAM;            /* the host mapping backing the guest's memory */
static uint64_t RAM_GPA;
static size_t RAM_SIZE;
static _Thread_local char strbuf[128];

static uint64_t hex64(const char *s) {
    if (!s) return 0;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    return (uint64_t)strtoull(s, NULL, 16);
}
static const char *put64(uint64_t v) { snprintf(strbuf, sizeof strbuf, "0x%" PRIx64, v); return strbuf; }

/* Create the VM. 0 on success, the hv_return_t otherwise -- the number Apple's
 * header documents, not a -1 that loses which of eight things went wrong. */
int hv_up(void) { return (int)hv_vm_create(NULL); }

/* Allocate host memory and map it as the guest's physical memory at `gpa`. */
int hv_map(const char *gpa_hex, const char *size_hex) {
    if (RAM) return -2;
    /* The size crosses as hex for the same reason an address does: the FFI
     * boundary's int is C's int, and a guest with 4 GiB of memory does not fit
     * in one. It fitted while the guest was small, which is how a limit like
     * this stays invisible until the day it matters. */
    RAM_SIZE = (size_t)hex64(size_hex);
    RAM_GPA = hex64(gpa_hex);
    // No PROT_EXEC on the HOST mapping. On Apple Silicon an anonymous
    // executable mapping needs the JIT entitlement, and this one does not need
    // to be executable at all: the guest's permission to execute comes from
    // HV_MEMORY_EXEC in hv_vm_map, which is a property of the guest's view.
    RAM = mmap(NULL, RAM_SIZE, PROT_READ | PROT_WRITE,
               MAP_ANON | MAP_PRIVATE, -1, 0);
    if (RAM == MAP_FAILED) { RAM = NULL; return -3; }
    memset(RAM, 0, RAM_SIZE);
    return (int)hv_vm_map(RAM, RAM_GPA, RAM_SIZE,
                          HV_MEMORY_READ | HV_MEMORY_WRITE | HV_MEMORY_EXEC);
}

static void *at(uint64_t gpa, size_t len) {
    if (!RAM || gpa < RAM_GPA || gpa + len > RAM_GPA + RAM_SIZE) return NULL;
    return (char *)RAM + (gpa - RAM_GPA);
}

int hv_poke32(const char *gpa_hex, int val) {
    void *p = at(hex64(gpa_hex), 4);
    if (!p) return -1;
    uint32_t v = (uint32_t)val;
    memcpy(p, &v, 4);
    return 0;
}
int hv_peek32(const char *gpa_hex) {
    void *p = at(hex64(gpa_hex), 4);
    if (!p) return 0;
    uint32_t v; memcpy(&v, p, 4); return (int)v;
}

int hv_vcpu_new(void) { return (int)hv_vcpu_create(&VCPU, &EXIT, NULL); }

/* Registers by NUMBER: 0-30 are X0-X30, and PC and CPSR have their own calls,
 * because their enum values are not in that range and inventing a numbering
 * here would be a second mapping to get wrong. */
int hv_set_x(int n, const char *val_hex) {
    if (n < 0 || n > 30) return -1;
    return (int)hv_vcpu_set_reg(VCPU, (hv_reg_t)(HV_REG_X0 + n), hex64(val_hex));
}
const char *hv_get_x(int n) {
    uint64_t v = 0;
    if (n >= 0 && n <= 30) hv_vcpu_get_reg(VCPU, (hv_reg_t)(HV_REG_X0 + n), &v);
    return put64(v);
}
int hv_set_pc(const char *val_hex) { return (int)hv_vcpu_set_reg(VCPU, HV_REG_PC, hex64(val_hex)); }
const char *hv_get_pc(void) { uint64_t v = 0; hv_vcpu_get_reg(VCPU, HV_REG_PC, &v); return put64(v); }

/* EL1h with interrupts masked. 0x3c5 is what a reset vector starts in, and
 * setting it explicitly is required: the value read back before any write is
 * the same number but the vCPU starts at EL0 without it. */
int hv_set_cpsr(const char *val_hex) { return (int)hv_vcpu_set_reg(VCPU, HV_REG_CPSR, hex64(val_hex)); }

int hv_run(void) { return (int)hv_vcpu_run(VCPU); }

int hv_exit_reason(void) { return EXIT ? (int)EXIT->reason : -1; }
const char *hv_exit_syndrome(void) { return put64(EXIT ? EXIT->exception.syndrome : 0); }
const char *hv_exit_va(void) { return put64(EXIT ? EXIT->exception.virtual_address : 0); }
/* EC is the top six bits of the syndrome: which KIND of exception this was. */
int hv_exit_ec(void) { return EXIT ? (int)((EXIT->exception.syndrome >> 26) & 0x3f) : -1; }

/* ---- the GIC ------------------------------------------------------------ */
/*
 * macOS provides the interrupt controller: hv_gic_create takes a config with
 * the distributor and redistributor base addresses and the framework emulates
 * GICv3 behind them. The alternative is several thousand lines of register
 * emulation, so the addresses in the device tree are chosen to match what is
 * passed here -- one file decides both, which is why the tree is generated
 * rather than compiled from a separate source.
 */
int hv_gic_up(const char *dist_hex, const char *redist_hex) {
    hv_gic_config_t cfg = hv_gic_config_create();
    if (!cfg) return -1;
    hv_return_t r = hv_gic_config_set_distributor_base(cfg, hex64(dist_hex));
    if (r != HV_SUCCESS) return (int)r;
    r = hv_gic_config_set_redistributor_base(cfg, hex64(redist_hex));
    if (r != HV_SUCCESS) return (int)r;
    return (int)hv_gic_create(cfg);
}

/* ---- loading ------------------------------------------------------------ */
long long hv_load_file(const char *path, const char *gpa_hex) {
    uint64_t gpa = hex64(gpa_hex);
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END); long sz = ftell(f); fseek(f, 0, SEEK_SET);
    void *p = at(gpa, (size_t)sz);
    if (!p) { fclose(f); return -2; }
    size_t got = fread(p, 1, (size_t)sz, f);
    fclose(f);
    return (long long)got;
}

/* ---- decoding an exit --------------------------------------------------- */
/* The instruction-specific syndrome, which for a data abort says which
 * register, how wide, and which direction. */
int hv_exit_iss(void) { return EXIT ? (int)(EXIT->exception.syndrome & 0x1ffffff) : 0; }

/* Step over the instruction that faulted. AArch64 instructions are four bytes;
 * a fault that is not retried has to be stepped past or the guest runs it
 * again forever. */
int hv_advance_pc(void) {
    uint64_t pc = 0;
    hv_return_t r = hv_vcpu_get_reg(VCPU, HV_REG_PC, &pc);
    if (r != HV_SUCCESS) return (int)r;
    return (int)hv_vcpu_set_reg(VCPU, HV_REG_PC, pc + 4);
}

/* HVF reports the virtual timer becoming active; masking it and continuing is
 * what a VMM with nothing else to do about it does. */
int hv_mask_vtimer(void) { return (int)hv_vcpu_set_vtimer_mask(VCPU, true); }

/* Sys regs by name, so a caller does not carry Apple's enum values. */
int hv_set_sys(const char *name, const char *val_hex) {
    hv_sys_reg_t r;
    if (!strcmp(name, "CNTV_CTL_EL0")) r = HV_SYS_REG_CNTV_CTL_EL0;
    else if (!strcmp(name, "MIDR_EL1")) r = HV_SYS_REG_MIDR_EL1;
    // The framework places a vCPU's redistributor from its AFFINITY, and the
    // header says so: hv_gic_get_redistributor_base "must be called after the
    // affinity of the given vCPU has been set in its MPIDR_EL1 register".
    // Without that it answers HV_BAD_ARGUMENT and the redistributor is not
    // anywhere -- which the guest discovers as a data abort in the middle of
    // GIC initialisation.
    else if (!strcmp(name, "MPIDR_EL1")) r = HV_SYS_REG_MPIDR_EL1;
    else return -1;
    return (int)hv_vcpu_set_sys_reg(VCPU, r, hex64(val_hex));
}

/* The guest's PHYSICAL address for a fault. virtual_address is the address in
 * the guest's own page tables, which is where the kernel mapped the device --
 * not where the device is. Dispatching on it sends every MMIO access to
 * "unhandled", which is what it did. */
const char *hv_exit_pa(void) { return put64(EXIT ? EXIT->exception.physical_address : 0); }

/* ---- the GIC's own geometry -------------------------------------------- */
/*
 * Ask the framework how big its distributor and redistributor windows are,
 * rather than writing 0x10000 and 0x100000 into a device tree and hoping. The
 * kernel probes to the end of the window it is told about; a window described
 * larger than the one the framework answers for produces a data abort in the
 * middle of GIC initialisation, at an address that looks arbitrary
 * (0x80affe8 -- the PIDR2 register at the end of a frame that was not there).
 */
long long hv_gic_dist_size(void) { size_t v = 0; return hv_gic_get_distributor_size(&v) == HV_SUCCESS ? (long long)v : -1; }
long long hv_gic_redist_size(void) { size_t v = 0; return hv_gic_get_redistributor_size(&v) == HV_SUCCESS ? (long long)v : -1; }
long long hv_gic_dist_align(void) { size_t v = 0; return hv_gic_get_distributor_base_alignment(&v) == HV_SUCCESS ? (long long)v : -1; }
long long hv_gic_redist_align(void) { size_t v = 0; return hv_gic_get_redistributor_base_alignment(&v) == HV_SUCCESS ? (long long)v : -1; }
long long hv_gic_redist_region_size(void) { size_t v = 0; return hv_gic_get_redistributor_region_size(&v) == HV_SUCCESS ? (long long)v : -1; }

/* Where the framework actually put this vCPU's redistributor. It assigns them
 * itself from the region the config named; the device tree has to describe
 * where they ARE, not where the region started. */
const char *hv_gic_redist_base_of_vcpu(void) {
    hv_ipa_t b = 0;
    if (hv_gic_get_redistributor_base(VCPU, &b) != HV_SUCCESS) return put64(0);
    return put64(b);
}

/* ---- guest memory, by copy ---------------------------------------------- */
/*
 * A virtio queue lives in the guest's RAM: descriptors, the available and used
 * rings, and the buffers they point at. The VMM has to read and write all of
 * it, and the question is whether it does so through a window value or by
 * copying.
 *
 * These copy. Whether that is acceptable is a measurement, not an opinion, and
 * the answer is in bench/. A copy of the data buffer costs one memcpy per
 * request on top of the read that produced it.
 */
int hv_read_u32(const char *gpa_hex) {
    void *p = at(hex64(gpa_hex), 4);
    if (!p) return 0;
    uint32_t v; memcpy(&v, p, 4); return (int)v;
}
int hv_read_u16(const char *gpa_hex) {
    void *p = at(hex64(gpa_hex), 2);
    if (!p) return 0;
    uint16_t v; memcpy(&v, p, 2); return (int)v;
}
int hv_write_u32(const char *gpa_hex, int v) {
    void *p = at(hex64(gpa_hex), 4);
    if (!p) return -1;
    uint32_t x = (uint32_t)v; memcpy(p, &x, 4); return 0;
}
int hv_write_u16(const char *gpa_hex, int v) {
    void *p = at(hex64(gpa_hex), 2);
    if (!p) return -1;
    uint16_t x = (uint16_t)v; memcpy(p, &x, 2); return 0;
}
int hv_write_u64(const char *gpa_hex, const char *val_hex) {
    void *p = at(hex64(gpa_hex), 8);
    if (!p) return -1;
    uint64_t v = hex64(val_hex); memcpy(p, &v, 8); return 0;
}
const char *hv_read_u64(const char *gpa_hex) {
    void *p = at(hex64(gpa_hex), 8);
    if (!p) return put64(0);
    uint64_t v; memcpy(&v, p, 8); return put64(v);
}

/* Bulk: guest RAM to a file and back, which is what a block device moves.
 * Returns the number of bytes, or -1. */
/* Bulk: guest RAM to a file and back, which is what a block device moves.
 *
 * The disk is opened ONCE. Opening it per request cost 53 microseconds and made
 * the copy look expensive: the first measurement reported the same per-request
 * time for a 4 KiB transfer and a 64 KiB one, which is the shape of a fixed
 * cost and not of a copy.
 */
static int DISK_FD = -1;
static char DISK_PATH[1024];

static int disk_open(const char *path) {
    if (DISK_FD >= 0 && !strcmp(DISK_PATH, path)) return DISK_FD;
    if (DISK_FD >= 0) close(DISK_FD);
    DISK_FD = open(path, O_RDWR);
    if (DISK_FD < 0) DISK_FD = open(path, O_RDONLY);
    if (DISK_FD >= 0) snprintf(DISK_PATH, sizeof DISK_PATH, "%s", path);
    return DISK_FD;
}

long long hv_file_to_guest(const char *path, long long off, const char *gpa_hex, int len) {
    void *p = at(hex64(gpa_hex), (size_t)len);
    if (!p) return -1;
    int fd = disk_open(path);
    if (fd < 0) return -1;
    ssize_t n = pread(fd, p, (size_t)len, (off_t)off);
    if (n < 0) return -1;
    memset((char *)p + n, 0, (size_t)len - (size_t)n);   /* a short read is zeroes */
    return (long long)n;
}

long long hv_guest_to_file(const char *gpa_hex, int len, const char *path, long long off) {
    void *p = at(hex64(gpa_hex), (size_t)len);
    if (!p) return -1;
    int fd = disk_open(path);
    if (fd < 0) return -1;
    ssize_t n = pwrite(fd, p, (size_t)len, (off_t)off);
    return n < 0 ? -1 : (long long)n;
}

/* ---- injecting an interrupt -------------------------------------------- */
/*
 * Level, not edge. The specification allows either and an edge is one pulse:
 * if the driver is not looking when it arrives, it is gone. A level stays up
 * until the driver acknowledges, so a driver that was busy still finds it.
 */
int hv_spi(int intid, int level) { return (int)hv_gic_set_spi((uint32_t)intid, level != 0); }

/* ---- a deadline the vCPU cannot ignore ---------------------------------- */
/*
 * hv_vcpu_run BLOCKS. A guest waiting for an interrupt that a broken device
 * never raises sits in WFI, the framework does not return, and a deadline
 * checked between exits is never reached -- the loop is not running. Checking
 * the clock in the same thread is checking it in the one place that is not
 * executing.
 *
 * hv_vcpus_exit forces the vCPU out of run() from ANOTHER thread, which is
 * what this is for. Without it a device bug hangs the VMM, and a test for that
 * bug hangs with it.
 */
#include <pthread.h>
static int DEADLINE_MS = 0;
static volatile int DEADLINE_FIRED = 0;

static void *deadline_thread(void *arg) {
    (void)arg;
    struct timespec ts = { DEADLINE_MS / 1000, (long)(DEADLINE_MS % 1000) * 1000000L };
    nanosleep(&ts, NULL);
    DEADLINE_FIRED = 1;
    hv_vcpu_t v = VCPU;
    hv_vcpus_exit(&v, 1);
    return NULL;
}

int hv_start_deadline(int ms) {
    if (ms <= 0) return 0;
    DEADLINE_MS = ms;
    pthread_t t;
    if (pthread_create(&t, NULL, deadline_thread, NULL) != 0) return -1;
    pthread_detach(t);
    return 0;
}
int hv_deadline_fired(void) { return DEADLINE_FIRED; }

/* Seconds since the epoch, for the guest's clock.
 *
 * Seconds rather than milliseconds because the FFI boundary's int is C's int:
 * 32 bits. Seconds fit until 2038 and milliseconds do not fit at all, and an
 * RTC that silently wrapped would be worse than none. */
int hv_now_secs(void) { return (int)time(NULL); }

/* ---- vsock's host end ----------------------------------------------------
 *
 * A vsock stream has two halves. The guest's is a virtio queue; the host's is
 * an ordinary socket, because reaching something outside the VM is the entire
 * purpose of the device. Bytes move between guest RAM and that socket here,
 * for the same reason the block device's do: Mere drives the protocol, C moves
 * the bulk.
 *
 * Non-blocking, and asked rather than waited on. A VMM that blocks in a host
 * read has stopped being a VMM -- the vCPU is not running while it waits, and
 * a guest that is not running cannot be the one that fills the queue.
 */
/* Streams. Eight was enough for one client at a time; a forwarded port holds
 * one open for the life of every connection through it, and `docker compose
 * up` with published ports has several at once.
 *
 * 256 because 32 was a ceiling a real burst reached: forty `docker run` at
 * once filled it, this function then stopped accepting, the backlog behind it
 * filled, and eleven clients were told the daemon was not running. Must match
 * vs_smax in vsock.mere -- the table is the same table, counted on both
 * sides. */
#define VS_MAX 256
static int VS_FD[VS_MAX];
/* "The peer will send no more." Not the same as "the connection is over":
 * a host program that closes its write side is still waiting to READ, and
 * closing the socket because read() returned 0 throws away the answer. */
static int VS_MUTE[VS_MAX];
static int VS_INIT;
/* Inward listeners. More than one, because a VMM that can carry a docker
 * socket in can carry a forwarded port in the same way, and the two have to be
 * told apart by WHICH guest port they arrive at. */
#define VS_LMAX 8
static int VS_LFD[VS_LMAX];
static int VS_LPORT[VS_LMAX];
static int VS_LN;
static int VS_LAST_PORT;

static void vs_init(void) {
    if (VS_INIT) return;
    /* Writing to a socket whose peer has gone raises SIGPIPE, and the default
     * action is to kill the process. A VMM that dies because a CLIENT hung up
     * takes the guest and every other connection with it -- and it looks from
     * outside like the daemon inside the VM crashed, which is where two hours
     * went: `docker compose up` abandons its /events connection when it
     * exits, the guest wrote to that stream a moment later, and this process
     * was killed by the write.
     *
     * The daemon in the guest already does this for the same reason. So does
     * every server that has met a client that hangs up. */
    signal(SIGPIPE, SIG_IGN);
    for (int i = 0; i < VS_MAX; i++) { VS_FD[i] = -1; VS_MUTE[i] = 0; }
    VS_INIT = 1;
}
static int vs_ok(int h) { vs_init(); return h >= 0 && h < VS_MAX && VS_FD[h] >= 0; }

/* Connect to something on the host: a filesystem path, or "tcp:<port>" on the
 * loopback. Both are places a host program is listening; which one a route
 * uses is the caller's fact, and a registry is naturally the second. */
int hv_vs_connect(const char *path) {
    vs_init();
    int h = -1;
    for (int i = 0; i < VS_MAX; i++) if (VS_FD[i] < 0) { h = i; break; }
    if (h < 0) return -1;
    int fd;
    if (!strncmp(path, "tcp:", 4)) {
        /* "tcp:<port>" is this machine's loopback; "tcp:<host>:<port>" is
         * wherever that name leads. The second exists because the guest has no
         * resolver and no route: it asks for a vsock port, and the side that
         * has a network turns that into a name and a connection. */
        const char *rest = path + 4;
        const char *colon = strrchr(rest, ':');
        char host[256];
        int port;
        if (colon) {
            size_t n = (size_t)(colon - rest);
            if (n == 0 || n >= sizeof host) return -4;
            memcpy(host, rest, n);
            host[n] = 0;
            port = atoi(colon + 1);
        } else {
            host[0] = 0;
            port = atoi(rest);
        }
        if (port <= 0 || port > 65535) return -4;
        if (host[0] == 0) {
            fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) return -1;
            struct sockaddr_in in;
            memset(&in, 0, sizeof in);
            in.sin_family = AF_INET;
            in.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
            in.sin_port = htons((uint16_t)port);
            if (connect(fd, (struct sockaddr *)&in, sizeof in) != 0) { close(fd); return -1; }
        } else {
            char portstr[16];
            snprintf(portstr, sizeof portstr, "%d", port);
            struct addrinfo hints, *res = NULL, *ai;
            memset(&hints, 0, sizeof hints);
            hints.ai_family = AF_UNSPEC;
            hints.ai_socktype = SOCK_STREAM;
            if (getaddrinfo(host, portstr, &hints, &res) != 0 || !res) return -5;
            fd = -1;
            for (ai = res; ai; ai = ai->ai_next) {
                fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
                if (fd < 0) continue;
                if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
                close(fd); fd = -1;
            }
            freeaddrinfo(res);
            if (fd < 0) return -1;
        }
    } else {
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof a.sun_path, "%s", path);
    if (connect(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    }
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    VS_FD[h] = fd;
    return h;
}

/* The other direction: the HOST connects in, to something listening in the
 * guest. This is the direction a daemon inside the VM needs, and it is not the
 * same code with the arguments swapped -- the VMM is the one that has to start
 * the handshake, on a queue the guest fills for it.
 *
 * The listening socket is the VMM's, on the host's filesystem, so an ordinary
 * host program connects to an ordinary path and does not know a VM is involved.
 */
/* `path` is a filesystem path, or "tcp:<port>" for a loopback TCP port. Both
 * are places a host program connects to; which one a mapping uses is the
 * caller's fact, and a published container port is naturally the second. */
int hv_vs_listen(const char *path, int gport) {
    vs_init();
    if (VS_LN >= VS_LMAX) return -2;
    int fd;
    if (!strncmp(path, "tcp:", 4)) {
        int port = atoi(path + 4);
        if (port <= 0 || port > 65535) return -4;
        fd = socket(AF_INET, SOCK_STREAM, 0);
        if (fd < 0) return -1;
        int one = 1;
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in in;
        memset(&in, 0, sizeof in);
        in.sin_family = AF_INET;
        in.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        in.sin_port = htons((uint16_t)port);
        if (bind(fd, (struct sockaddr *)&in, sizeof in) != 0) { close(fd); return -1; }
        if (listen(fd, 128) != 0) { close(fd); return -1; }
    } else {
    unlink(path);
    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof a.sun_path, "%s", path);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    /* 128, like every other listening socket here: the backlog is what holds
     * a connection while the accept loop is busy, and when it overflows the
     * client is REFUSED rather than delayed. */
    if (listen(fd, 128) != 0) { close(fd); return -1; }
    }
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    VS_LFD[VS_LN] = fd; VS_LPORT[VS_LN] = gport; VS_LN++;
    return 0;
}

/* One waiting connection, or -1 for none. Never blocks: this is called from
 * the vCPU's thread, where blocking means the guest is not running. */
int hv_vs_accept(void) {
    vs_init();
    if (VS_LN == 0) return -1;
    int h = -1;
    for (int i = 0; i < VS_MAX; i++) if (VS_FD[i] < 0) { h = i; break; }
    if (h < 0) return -2;               /* no room: a refusal, not "none waiting" */
    for (int k = 0; k < VS_LN; k++) {
        int fd = accept(VS_LFD[k], NULL, NULL);
        if (fd < 0) continue;
        int fl = fcntl(fd, F_GETFL, 0);
        fcntl(fd, F_SETFL, fl | O_NONBLOCK);
        VS_FD[h] = fd; VS_MUTE[h] = 0;
        VS_LAST_PORT = VS_LPORT[k];
        return h;
    }
    return -1;
}

/* Which mapping the last accepted connection came in on. Two values cannot
 * cross the FFI boundary in one call, and the guest port is the half that
 * decides who in the guest answers. */
int hv_vs_accepted_port(void) { return VS_LAST_PORT; }

/* ---- the control socket -------------------------------------------------
 *
 * A published port's host end has to be OPENED, and only the host can open it,
 * and nothing knows which port until a container asks for it. So there is a
 * socket to ask on: one line in, one line out.
 *
 *   LISTEN <port>    open host TCP <port>, delivering to guest vsock <port>
 *   UNLISTEN <port>  close it
 *   PORTS            what is open
 *
 * The protocol is parsed in Mere; this is the socket underneath it. The port
 * numbers are the same on both sides for the reason the rest of this file
 * gives: whoever opened the host end already chose the number, so there is
 * nothing for the two ends to agree about.
 */
static int CTL_FD = -1;

int hv_ctl_listen(const char *path) {
    if (CTL_FD >= 0) return -2;
    unlink(path);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un a;
    memset(&a, 0, sizeof a);
    a.sun_family = AF_UNIX;
    snprintf(a.sun_path, sizeof a.sun_path, "%s", path);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    if (listen(fd, 8) != 0) { close(fd); return -1; }
    int fl = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, fl | O_NONBLOCK);
    CTL_FD = fd;
    return 0;
}

int hv_ctl_accept(void) {
    if (CTL_FD < 0) return -1;
    int c = accept(CTL_FD, NULL, NULL);
    return c < 0 ? -1 : c;
}

/* One line, without its newline. "" for end of file or nothing within the
 * timeout -- a caller that connected and said nothing must not stop the vCPU.
 */
static _Thread_local char CTL_LINE[512];
const char *hv_ctl_line(int fd) {
    size_t n = 0;
    while (n + 1 < sizeof CTL_LINE) {
        struct pollfd pf; pf.fd = fd; pf.events = POLLIN; pf.revents = 0;
        if (poll(&pf, 1, 200) <= 0) break;
        char c;
        ssize_t r = read(fd, &c, 1);
        if (r <= 0) break;
        if (c == '\n') break;
        if (c != '\r') CTL_LINE[n++] = c;
    }
    CTL_LINE[n] = 0;
    return CTL_LINE;
}

int hv_ctl_reply(int fd, const char *s) {
    size_t len = strlen(s);
    if (write(fd, s, len) < 0) return -1;
    if (write(fd, "\n", 1) < 0) return -1;
    return 0;
}

int hv_ctl_close(int fd) { return close(fd); }

/* Close the listener that delivers to this guest port. Returns 0, or -1 when
 * there was no such listener -- which the caller reports rather than swallows,
 * because "closed it" and "there was nothing to close" are different answers.
 */
int hv_vs_unlisten(int gport) {
    vs_init();
    for (int k = 0; k < VS_LN; k++) {
        if (VS_LPORT[k] != gport) continue;
        close(VS_LFD[k]);
        for (int j = k; j + 1 < VS_LN; j++) { VS_LFD[j] = VS_LFD[j + 1]; VS_LPORT[j] = VS_LPORT[j + 1]; }
        VS_LN--;
        return 0;
    }
    return -1;
}

int hv_vs_listener_count(void) { vs_init(); return VS_LN; }

/* Stop reading from this end without closing it. An fd at end of file stays
 * readable forever, so a poll that still watched it would spin, and a close
 * would take the write direction with it. */
int hv_vs_mute(int h) {
    if (!vs_ok(h)) return -1;
    VS_MUTE[h] = 1;
    return 0;
}

int hv_vs_close(int h) {
    if (!vs_ok(h)) return -1;
    close(VS_FD[h]); VS_FD[h] = -1; VS_MUTE[h] = 0; return 0;
}

/* Guest RAM -> the host socket. All of it, or -1. */
int hv_vs_send(int h, const char *gpa_hex, int len) {
    if (!vs_ok(h) || len < 0) return -1;
    const char *p = at(hex64(gpa_hex), (size_t)len);
    if (!p) return -1;
    int off = 0;
    while (off < len) {
        ssize_t n = write(VS_FD[h], p + off, (size_t)(len - off));
        if (n > 0) { off += (int)n; continue; }
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
            struct pollfd pf; pf.fd = VS_FD[h]; pf.events = POLLOUT; pf.revents = 0;
            if (poll(&pf, 1, 1000) <= 0) return -1;
            continue;
        }
        return -1;
    }
    return off;
}

/* The host socket -> guest RAM. 0 when nothing is ready yet, -2 at end of
 * file. Those are three different answers and the caller needs all three:
 * "nothing yet" means wait, "end of file" means tell the guest so. */
int hv_vs_recv(int h, const char *gpa_hex, int max) {
    if (!vs_ok(h) || max <= 0) return -1;
    void *p = at(hex64(gpa_hex), (size_t)max);
    if (!p) return -1;
    ssize_t n = read(VS_FD[h], p, (size_t)max);
    if (n > 0) return (int)n;
    if (n == 0) return -2;
    if (errno == EAGAIN || errno == EWOULDBLOCK) return 0;
    return -1;
}

/* Is there anything to read? Asked on every WFI, so it may not block. */
int hv_vs_ready(int h) {
    if (!vs_ok(h) || VS_MUTE[h]) return 0;
    struct pollfd pf; pf.fd = VS_FD[h]; pf.events = POLLIN; pf.revents = 0;
    if (poll(&pf, 1, 0) <= 0) return 0;
    return (pf.revents & (POLLIN | POLLHUP)) ? 1 : 0;
}

/* A thread that wakes the vCPU when the host end has something to say.
 *
 * WHY A THREAD. The same reason the deadline needs one: hv_vcpu_run blocks,
 * and a guest blocked in read() on a vsock stream is idle, so the loop that
 * would poll the host socket is not running. Masking the virtual timer -- what
 * this VMM does on every timer exit -- removes the last thing that was waking
 * it, and the measurement said so: 4 polls in 52,189 exits, then eight seconds
 * of nothing.
 *
 * It signals rather than copies: everything about the queue still happens on
 * the vCPU's thread, and this only decides WHEN.
 */
static volatile int VS_WATCH_RUN;

static void *vs_watch_thread(void *arg) {
    (void)arg;
    while (VS_WATCH_RUN) {
        struct pollfd pf[VS_MAX + VS_LMAX + 1];
        int n = 0;
        for (int k = 0; k < VS_LN; k++) {
            pf[n].fd = VS_LFD[k]; pf[n].events = POLLIN; pf[n].revents = 0; n++;
        }
        if (CTL_FD >= 0) { pf[n].fd = CTL_FD; pf[n].events = POLLIN; pf[n].revents = 0; n++; }
        for (int i = 0; i < VS_MAX; i++)
            if (VS_FD[i] >= 0 && !VS_MUTE[i]) { pf[n].fd = VS_FD[i]; pf[n].events = POLLIN; pf[n].revents = 0; n++; }
        if (n == 0) {
            struct timespec ts = { 0, 5 * 1000 * 1000L }; nanosleep(&ts, NULL);
            continue;
        }
        if (poll(pf, (nfds_t)n, 20) > 0) {
            hv_vcpu_t v = VCPU;
            hv_vcpus_exit(&v, 1);
            /* Whatever it was stays readable until the vCPU's thread takes it,
             * so without a pause this spins on the same readiness. */
            struct timespec ts = { 0, 2 * 1000 * 1000L }; nanosleep(&ts, NULL);
        }
    }
    return NULL;
}

int hv_vs_wake(void) {
    if (VS_WATCH_RUN) return 0;
    VS_WATCH_RUN = 1;
    pthread_t t;
    if (pthread_create(&t, NULL, vs_watch_thread, NULL) != 0) { VS_WATCH_RUN = 0; return -1; }
    pthread_detach(t);
    return 0;
}
