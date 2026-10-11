// ELF TLS for guests that carry PT_TLS — see kl_tls.h.
//
// THE PROBLEM
//
// A bionic guest never needed this: Android before API 29 has no ELF TLS, so
// every __thread variable went through emutls (__emutls_get_address, a plain
// function import). A glibc guest is the other shape. Half-Life: Alyx's
// libraries are built with -mtls-dialect=desc and reach their thread-locals
// inline:
//
//     mrs  x1, tpidr_el0              // rewritten to tpidrro_el0 at load
//     adrp x0, :tlsdesc:var           // the descriptor: two GOT words
//     ldr  x2, [x0, :tlsdesc_lo12:var]
//     add  x0, x0, :tlsdesc_lo12:var
//     blr  x2                         // resolver(x0 = &desc) -> offset in x0
//     add  x0, x1, x0                 // &var = TP + offset
//
// and libmimalloc additionally uses the initial-exec model — an
// R_AARCH64_TLS_TPREL64 GOT word holding a CONSTANT offset from TP:
//
//     mrs  x0, tpidr_el0
//     ldr  x1, [got]                  // TLS_TPREL64
//     ldr  x2, [x0, x1]
//
// The thread pointer here is not a pointer we own. Klepton turns every guest
// `mrs tpidr_el0` into `mrs tpidrro_el0`, which on Darwin is the base of the
// pthread TSD array (struct _pthread's tsd[]), because TPIDR_EL0 itself is
// clobbered by the kernel on preemption. Linux (variant I) puts the static TLS
// blocks right after a 16-byte TCB at TP; on Darwin the bytes after TP are
// libpthread's own TSD slots and then the end of a structure whose placement
// relative to the stack differs between the main thread and every other one.
// So there is no "TP + constant" that lands in memory we allocated — with one
// exception, below.
//
// THE DESIGN
//
// 1. Modules. Every image with a PT_TLS segment is registered as a module with
//    an id (>= 1) and its template: .tdata (filesz bytes, relocated in place by
//    the image's own RELATIVE/ABS64 relocations before anything copies it) and
//    .tbss (memsz - filesz bytes of zero).
//
// 2. TLSDESC is answered DYNAMICALLY, which the ABI explicitly allows: the
//    resolver's contract is "return, in x0, the offset from TP of the variable
//    for the CURRENT thread", not "return a constant". glibc's own
//    _dl_tlsdesc_dynamic is exactly this. Every descriptor gets
//    { kl_tlsdesc_dynamic, &kl_tls_arg{modid, offset, name} }, and the resolver
//    returns  dtv[modid] + offset - TP,  where dtv is a per-thread vector of
//    block pointers kept in a pthread key (kl_tls_dtv_key). The fast path is a
//    dozen instructions in kl_tlsdesc.S and touches x0-x4 (x1-x4 saved and
//    restored); a missing dtv, a short one, or an unallocated block takes the
//    slow path, which saves every caller-saved register — x1-x17, x29, x30 and
//    all of q0-q31, since a callee only preserves the low halves of v8-v15 —
//    and calls kl_tls_get_addr_slow(). Blocks are allocated lazily, per thread,
//    on first touch, and freed by the key's destructor at thread exit.
//
//    The aarch64 TLSDESC calling convention: the resolver is entered with x0 =
//    the descriptor's address and x30 = the return address, and must preserve
//    EVERY other general and vector register — the call site does not treat
//    the blr as a call, so x1-x18 and v0-v31 are live across it. Only x0
//    (the result) and the condition flags may change (x30 is the link register
//    the blr itself wrote). The slow path is the one place this matters, and
//    the reason it is assembly.
//
// 3. TLS_TPREL64 needs a constant, and the one per-thread memory at a constant
//    distance from Darwin's TP is the TSD array itself: tsd[k] lives at
//    TP + 8*k for every key k, on every thread (kl_x18.c makes the same bet for
//    its veneer slot and checks it the same way). So the static area is a run
//    of KL_TLS_STATIC_KEYS consecutive pthread keys we create and never
//    release, and a module that any TPREL64 relocation names gets its block
//    carved out of it: offset 8*first_key + its place in the run. Its TLSDESC
//    descriptors keep the dynamic resolver, which then answers with that same
//    static address — one storage location per variable, whichever model the
//    access site used.
//
//    New threads start with those TSD slots zero, so the templates have to be
//    copied in before guest code runs there: kl_thread_init() (which every
//    guest thread already calls — the stack-guard canary needs it) calls
//    kl_tls_thread_init(), and so does the resolver's slow path. A per-thread
//    count in another key says how many static modules this thread has already
//    seeded, so a module loaded later is seeded on its next pass. A host thread
//    that never called kl_thread_init and reaches an IE access first sees .tbss
//    semantics (zeros) for .tdata — the same gap the canary has.
//
//    Limits, each failing BY NAME at relocation time rather than as a wrong
//    address later: the run is 512 bytes; a static module's alignment cannot
//    exceed 8 (Darwin's TSD base is only guaranteed 8-aligned); and a module
//    cannot become static once some thread has a dynamic block for it. Alyx's
//    only IE user is libmimalloc: 9 bytes, align 8.
//
// R_AARCH64_TLS_DTPMOD64/DTPREL64 (general-dynamic through __tls_get_addr)
// are not handled; no guest here emits them, and the loader still refuses an
// unknown relocation by type.
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include "klepton.h"
#include "kl_tls.h"

#define KL_TLS_MAX_MODS    256
#define KL_TLS_STATIC_KEYS 64          /* 512 bytes of static TLS */

typedef struct {
    const char    *name;
    const uint8_t *init;
    size_t         filesz, memsz, align;
    int            is_static;
    int64_t        static_off;         // from TP, when is_static
    volatile int   touched;            // some thread holds a dynamic block
    unsigned       descs;              // descriptors handed out, for the report
} tls_mod;

static tls_mod          g_mods[KL_TLS_MAX_MODS + 1];      // indexed by modid
static volatile size_t  g_nmods;
static pthread_mutex_t  g_mu = PTHREAD_MUTEX_INITIALIZER;

// Read by kl_tlsdesc.S: the key whose TSD slot holds this thread's dtv. A uint64_t
// rather than a pthread_key_t so the assembly's 64-bit load is the right size
// whatever the typedef is.
uint64_t kl_tls_dtv_key;
static int g_dtv_key_ok;

static int           g_static_ok;
static pthread_key_t g_static_first;
static size_t        g_static_used;                     // bytes of the run
static pthread_key_t g_static_done_key;                 // per-thread seed count
static size_t        g_static_mods[KL_TLS_MAX_MODS];
static volatile size_t g_nstatic;

void kl_unresolved_named(const char *name);   // kl_shim.c

static inline uint8_t *read_tp(void) {
    uint64_t tp;
    __asm__ volatile("mrs %0, tpidrro_el0" : "=r"(tp));
    return (uint8_t *)(uintptr_t)tp;
}

// The dtv: dtv[0] is the number of block slots, dtv[1 + m] is module m's block
// for this thread. kl_tlsdesc.S reads exactly this shape.
static void dtv_free(void *p) {
    uint64_t *dtv = p;
    if (!dtv) return;
    for (uint64_t m = 0; m < dtv[0]; m++) {
        void *b = (void *)(uintptr_t)dtv[1 + m];
        if (b && m <= KL_TLS_MAX_MODS && !g_mods[m].is_static) free(b);
    }
    free(dtv);
}

size_t kl_tls_register_module(const char *path, const void *init, size_t filesz,
                              size_t memsz, size_t align) {
    pthread_mutex_lock(&g_mu);
    if (!g_dtv_key_ok) {
        pthread_key_t k;
        if (pthread_key_create(&k, dtv_free) == 0) {
            kl_tls_dtv_key = (uint64_t)k;
            g_dtv_key_ok = 1;
        }
    }
    size_t id = 0;
    if (g_dtv_key_ok && g_nmods < KL_TLS_MAX_MODS) {
        id = g_nmods + 1;
        const char *b = path ? strrchr(path, '/') : NULL;
        g_mods[id] = (tls_mod){ .name = strdup(b ? b + 1 : (path ? path : "?")),
                                .init = init, .filesz = filesz, .memsz = memsz,
                                .align = align ? align : 1 };
        g_nmods = id;          // published last: the slow path reads it unlocked
    }
    pthread_mutex_unlock(&g_mu);
    if (kl_env_on("KL_TRACE_TLS", 0))
        fprintf(stderr, "  [tls] module %zu %s: tdata %zu, tbss %zu, align %zu\n",
                id, path ? path : "?", filesz, memsz - filesz, align);
    return id;
}

// Claim KL_TLS_STATIC_KEYS consecutive keys. Darwin hands keys out upward, so
// the walk normally ends after exactly that many; anything collected on the way
// that is not part of the run is released again.
static int reserve_static(char *err, size_t cap) {
    if (g_static_ok) return 0;
    static pthread_key_t got[512];
    unsigned n = 0, run = 0;
    pthread_key_t start = 0, prev = 0;
    while (n < 512) {
        pthread_key_t k;
        if (pthread_key_create(&k, NULL) != 0) break;
        got[n++] = k;
        if (run && k == prev + 1) run++;
        else { start = k; run = 1; }
        prev = k;
        if (run == KL_TLS_STATIC_KEYS) break;
    }
    for (unsigned i = 0; i < n; i++)
        if (run < KL_TLS_STATIC_KEYS || got[i] < start ||
            got[i] >= start + KL_TLS_STATIC_KEYS)
            pthread_key_delete(got[i]);
    if (run < KL_TLS_STATIC_KEYS) {
        snprintf(err, cap, "static TLS: no run of %d consecutive pthread keys "
                 "(longest %u)", KL_TLS_STATIC_KEYS, run);
        return -1;
    }
    // The access sites read [TP + 8*k] directly, so prove that is where the API
    // keeps key k on this OS before handing out offsets that assume it.
    pthread_setspecific(start, (void *)(uintptr_t)0x5A5A5A5AU);
    int ok = ((void **)read_tp())[start] == (void *)(uintptr_t)0x5A5A5A5AU;
    pthread_setspecific(start, NULL);
    if (!ok || ((uintptr_t)read_tp() & 7)) {
        snprintf(err, cap, "static TLS: TSD key %lu is not at tsd[%lu] on this OS",
                 (unsigned long)start, (unsigned long)start);
        return -1;
    }
    if (pthread_key_create(&g_static_done_key, NULL) != 0) {
        snprintf(err, cap, "static TLS: no pthread key for the seed count");
        return -1;
    }
    g_static_first = start;
    g_static_ok = 1;
    return 0;
}

int kl_tls_make_static(size_t modid, char *err, size_t cap) {
    if (!modid || modid > g_nmods) {
        snprintf(err, cap, "static TLS: no module %zu", modid);
        return -1;
    }
    pthread_mutex_lock(&g_mu);
    tls_mod *m = &g_mods[modid];
    int rc = 0;
    if (m->is_static) goto out;
    if (m->touched) {
        snprintf(err, cap, "static TLS: %s already has dynamic blocks — an "
                 "initial-exec access after first use cannot be honoured", m->name);
        rc = -1; goto out;
    }
    if (m->align > 8) {
        snprintf(err, cap, "static TLS: %s wants %zu-byte alignment; Darwin's TSD "
                 "base is only 8-aligned", m->name, m->align);
        rc = -1; goto out;
    }
    if ((rc = reserve_static(err, cap)) != 0) goto out;
    size_t off = (g_static_used + m->align - 1) & ~(m->align - 1);
    if (off + m->memsz > (size_t)KL_TLS_STATIC_KEYS * 8) {
        snprintf(err, cap, "static TLS: %s needs %zu bytes, %zu of %d left",
                 m->name, m->memsz, (size_t)KL_TLS_STATIC_KEYS * 8 - off,
                 KL_TLS_STATIC_KEYS * 8);
        rc = -1; goto out;
    }
    g_static_used = off + m->memsz;
    m->static_off = (int64_t)g_static_first * 8 + (int64_t)off;
    m->is_static = 1;
    g_static_mods[g_nstatic] = modid;
    g_nstatic = g_nstatic + 1;
out:
    pthread_mutex_unlock(&g_mu);
    return rc;
}

int64_t kl_tls_static_offset(size_t modid) {
    return (modid && modid <= g_nmods) ? g_mods[modid].static_off : 0;
}

const kl_tls_arg *kl_tls_desc_arg(size_t modid, uint64_t off, const char *name) {
    kl_tls_arg *a = malloc(sizeof *a);
    if (!a) return NULL;
    a->modid = modid;
    a->off   = off;
    a->name  = name ? strdup(name) : NULL;
    if (modid && modid <= g_nmods) g_mods[modid].descs++;
    return a;
}

void kl_tls_thread_init(void) {
    size_t n = g_nstatic;
    if (!n || !g_static_ok) return;
    size_t done = (size_t)(uintptr_t)pthread_getspecific(g_static_done_key);
    if (done >= n) return;
    uint8_t *tp = read_tp();
    for (size_t i = done; i < n; i++) {
        const tls_mod *m = &g_mods[g_static_mods[i]];
        uint8_t *b = tp + m->static_off;
        if (m->filesz) memcpy(b, m->init, m->filesz);
        memset(b + m->filesz, 0, m->memsz - m->filesz);
    }
    pthread_setspecific(g_static_done_key, (void *)(uintptr_t)n);
}

void *kl_tls_get_addr_slow(const kl_tls_arg *a) {
    size_t m = a ? (size_t)a->modid : 0;
    if (!m || m > g_nmods) {
        char nm[200];
        snprintf(nm, sizeof nm, "%s (a thread-local variable)",
                 a && a->name ? a->name : "?");
        kl_unresolved_named(nm);           // does not return
        return NULL;
    }
    kl_tls_thread_init();

    pthread_key_t key = (pthread_key_t)kl_tls_dtv_key;
    uint64_t *dtv = pthread_getspecific(key);
    uint64_t cap = dtv ? dtv[0] : 0;
    if (m >= cap) {
        uint64_t ncap = ((uint64_t)g_nmods + 16) & ~(uint64_t)15;
        uint64_t *nd = realloc(dtv, (size_t)(ncap + 1) * sizeof *nd);
        if (!nd) { kl_unresolved_named("(out of memory growing a TLS dtv)"); return NULL; }
        memset(nd + 1 + cap, 0, (size_t)(ncap - cap) * sizeof *nd);
        nd[0] = ncap;
        dtv = nd;
        pthread_setspecific(key, dtv);
    }
    if (!dtv[1 + m]) {
        tls_mod *md = &g_mods[m];
        void *blk;
        if (md->is_static) {
            blk = read_tp() + md->static_off;
        } else {
            md->touched = 1;
            size_t al = md->align < sizeof(void *) ? sizeof(void *) : md->align;
            size_t sz = md->memsz ? md->memsz : 1;
            if (posix_memalign(&blk, al, (sz + al - 1) & ~(al - 1)) != 0) {
                kl_unresolved_named("(out of memory allocating a TLS block)");
                return NULL;
            }
            if (md->filesz) memcpy(blk, md->init, md->filesz);
            memset((uint8_t *)blk + md->filesz, 0, md->memsz - md->filesz);
        }
        dtv[1 + m] = (uint64_t)(uintptr_t)blk;
    }
    return (uint8_t *)(uintptr_t)dtv[1 + m] + a->off;
}

void kl_tls_report(FILE *out) {
    if (!out) return;
    size_t n = g_nmods;
    if (!n) return;
    fprintf(out, "  TLS modules: %zu (static area %zu/%d bytes)\n", n,
            g_static_used, KL_TLS_STATIC_KEYS * 8);
    for (size_t i = 1; i <= n; i++) {
        const tls_mod *m = &g_mods[i];
        fprintf(out, "    %3zu %-28s tdata %5zu tbss %5zu align %2zu  %-7s %u desc\n",
                i, m->name, m->filesz, m->memsz - m->filesz, m->align,
                m->is_static ? "static" : "dynamic", m->descs);
    }
}
