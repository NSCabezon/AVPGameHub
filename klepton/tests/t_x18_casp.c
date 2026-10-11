// The casp pair veneer (KLX_HZ_CASP), EXECUTED. `make x18casp`, in `make check`.
//
// GCC-built glibc guests (Half-Life: Alyx: 14 sites across libscenesystem,
// libclient, libvstdlib, libengine2, ...) use x18 as the base of a casp
// register PAIR. Before KLX_HZ_CASP the decoder filed casp under load/store
// exclusive and saw one register, so the site got a single-register
// substitution: an odd scratch is an unallocated encoding (SIGILL), an even
// one pairs with scratch+1 instead of x19 (a silently wrong compare-and-swap).
//
// This runs the real instructions through the real emitter, in an executable
// mapping, with every core kept busy so the threads are preempted (the kernel
// zeroes x18 on exception return; a value parked in the architectural
// register would read back 0):
//   1. the decoder flags a pair site KLX_HZ_CASP and a base-only site not;
//   2. casp with Rs = x18:x19 (receives the old value) and with Rt = x18:x19
//      (written to memory) give the architectural results, 2000 times;
//   3. casp with x18 as the base address only goes through the general veneer.
//
// Adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox) tests/t_x18_shapes.c.
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include "../runtime/kl_x18.h"

extern char f_casp[], f_casp_end[], f_casp_rn[], f_casp_rn_end[];

static int g_fail;
static void ck(int ok, const char *what) {
    if (!ok) g_fail++;
    printf("  %-4s %s\n", ok ? "ok" : "FAIL", what);
}

static void *spin(void *a) { volatile uint64_t x = 0; for (;;) x++; return a; }

// Copy [s,e) into a fresh mapping with its veneer pool behind it, veneer it,
// and make it executable.
static void *install(const char *s, const char *e, kl_x18_stats *st) {
    size_t n = (size_t)(e - s), cap = 0x10000;
    uint8_t *m = mmap(NULL, cap * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (m == MAP_FAILED) { perror("mmap"); exit(2); }
    memcpy(m, s, n);
    size_t used = 0;
    memset(st, 0, sizeof *st);
    if (kl_x18_emit(m, n, (uint64_t)(uintptr_t)m, m + cap, cap,
                    (uint64_t)(uintptr_t)(m + cap), st, &used) != 0) {
        fprintf(stderr, "kl_x18_emit failed\n");
        exit(2);
    }
    if (mprotect(m, cap * 2, PROT_READ | PROT_EXEC) != 0) { perror("mprotect"); exit(2); }
    sys_icache_invalidate(m, cap * 2);
    return m;
}

static uint32_t first_casp(const char *s, const char *e) {
    for (const uint32_t *w = (const uint32_t *)s; w < (const uint32_t *)e; w++)
        if ((*w & 0xBFA07C00u) == 0x08207C00u) return *w;
    return 0;
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    printf("=== x18 casp pair veneer ===\n");
    if (kl_x18_init() != 0) { printf("FAIL: TSD slot %d could not be claimed\n", KLX_TSD_SLOT); return 1; }

    klx_info in;
    uint32_t pair = first_casp(f_casp, f_casp_end), base = first_casp(f_casp_rn, f_casp_rn_end);
    klx_decode(pair, &in);
    ck(in.ok && in.hazard == KLX_HZ_CASP && in.nfields == 1,
       "decoder: `caspal x18, x19, x4, x5, [x0]` is a pair site (KLX_HZ_CASP)");
    uint32_t sub = klx_substitute(pair, &in, 9);
    ck(((sub >> 16) & 31) == 8, "...substitution keeps the pair base even (x9 -> x8:x9)");
    klx_decode(base, &in);
    ck(in.ok && in.hazard == 0 && in.nfields == 1,
       "decoder: `casp x2, x3, x4, x5, [x18]` is an ordinary base-register site");

    long ncpu = sysconf(_SC_NPROCESSORS_ONLN);
    pthread_t t;
    for (long i = 0; i < ncpu * 2; i++) pthread_create(&t, NULL, spin, NULL);

    kl_x18_stats st;
    void (*casp)(uint64_t *, uint64_t *, uint64_t, uint64_t, uint64_t, uint64_t) =
        install(f_casp, f_casp_end, &st);
    char msg[160];
    snprintf(msg, sizeof msg, "f_casp: %u x18 sites, %u veneered, %u refused",
             st.sites, st.patched, st.refused);
    ck(st.sites > 0 && st.refused == 0 && st.patched == st.sites, msg);
    void (*casp_rn)(uint64_t *, uint64_t *, uint64_t, uint64_t, uint64_t, uint64_t) =
        install(f_casp_rn, f_casp_rn_end, &st);
    snprintf(msg, sizeof msg, "f_casp_rn: %u x18 sites, %u veneered, %u refused",
             st.sites, st.patched, st.refused);
    ck(st.sites > 0 && st.refused == 0 && st.patched == st.sites, msg);

    int bad = 0, bad_rn = 0;
    for (int i = 0; i < 2000; i++) {
        _Alignas(16) uint64_t mem[2] = {0x1111, 0x2222};
        uint64_t out[4] = {0};
        casp(mem, out, 0x1111, 0x2222, 0xaaaa + (uint64_t)i, 0xbbbb);
        // First: expected matches -> Rs (x18:x19) gets the old value, mem = new.
        // Second: Rs = new matches -> Rs gets new, mem = Rt (x18:x19) = expected.
        if (out[0] != 0x1111 || out[1] != 0x2222 || out[2] != 0xaaaa + (uint64_t)i ||
            out[3] != 0xbbbb || mem[0] != 0x1111 || mem[1] != 0x2222) {
            if (!bad++) printf("       iter %d: out %llx %llx %llx %llx mem %llx %llx\n", i,
                               out[0], out[1], out[2], out[3], mem[0], mem[1]);
        }
        _Alignas(16) uint64_t m2[2] = {5, 6};
        uint64_t o2[2] = {0};
        casp_rn(m2, o2, 5, 6, 7 + (uint64_t)i, 8);
        if (o2[0] != 5 || o2[1] != 6 || m2[0] != 7 + (uint64_t)i || m2[1] != 8) bad_rn++;
    }
    ck(!bad, "casp with Rs = x18:x19 and with Rt = x18:x19: right over 2000 preempted runs");
    ck(!bad_rn, "casp with x18 as the base address: right over 2000 preempted runs");
    printf("%s: x18 casp pair veneer\n", g_fail ? "FAIL" : "PASS");
    _exit(g_fail ? 1 : 0);
}
