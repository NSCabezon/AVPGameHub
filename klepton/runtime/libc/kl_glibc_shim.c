// The glibc ABI tier — consulted BEFORE the bionic shim table, and only when the
// glibc door installed it (kl_glibc_configure -> kl_set_abi_lookup), so no
// Android guest ever binds a name here.
//
// Three kinds of entry:
//
//   - glibc-only names with no bionic counterpart: __errno_location, the
//     __ctype_*_loc tables, _dl_find_object, __libc_start_main, the extra
//     fortify entry points, __isoc23_*/*64 spellings.
//   - names BOTH libcs export whose LAYOUT differs, so the bionic answer is
//     wrong for a glibc caller: sigaction (152 bytes, 128-byte sigset_t),
//     sigset_t operations, the locale objects libstdc++ reads directly,
//     setlocale's category numbering.
//   - names nothing here implements and nothing in Alyx is expected to need
//     (xattr, SysV shm, mount, posix_spawn, ...). They bind to a stub that names
//     itself on every call (rate-limited) and answers ENOSYS, rather than to the
//     abort-by-name stub, so an optional probe does not end the run.
//
// What the bionic shims already serve and glibc agrees with, layout for layout,
// is NOT repeated here — verified per struct:
//   struct stat / stat64   asm-generic, 128 bytes, identical (klb_stat writes it)
//   struct statfs          120 bytes, identical (klb_statfs)
//   struct dirent64        d_ino, d_off, d_reclen, d_type, d_name[256] (klb_readdir)
//   pthread mutex/cond/rwlock/sem   address-keyed side tables (kl_pthread.c),
//                          so the guest's 48/48/56/32-byte objects only have to
//                          be large enough to have an address; attr objects are
//                          written through bionic's 56-byte layout, inside glibc's
//                          64; pthread_once_t / pthread_key_t are both 4 bytes
//   struct timespec / tm   identical (tm_gmtoff, tm_zone in the same order)
//   stdin/stdout/stderr    data objects holding a FILE *, answered with the
//                          address of Darwin's own (kl_host_file passes a real
//                          FILE * through). Code that inlines glibc's
//                          getc_unlocked/putc_unlocked bodies and reads
//                          _IO_read_ptr out of the FILE would NOT survive this;
//                          nothing found so far does.
#include <complex.h>
#include <ctype.h>
#include <fenv.h>
#include <inttypes.h>
#include <libgen.h>
#include <sys/time.h>
#include <syslog.h>
#include <dirent.h>
#include <dlfcn.h>
#include <errno.h>
#include <execinfo.h>
#include <fcntl.h>
#include <limits.h>
#include <locale.h>
#include <math.h>
#include <netinet/in.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mount.h>
#include <sys/socket.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>
#include <wchar.h>
#include <wctype.h>
#include <xlocale.h>

#include "klepton.h"
#include "kl_va.h"
#include "kl_glibc_shim.h"
#include "kl_glibc_sdl.h"
#include "kl_steam.h"
#include "kl_openvr.h"

#define LX_ENOSYS 38
#define LX_ENOENT 2

// ---------- the ENOSYS family ----------
// Reached through kl_named_stub, so x0 is the NAME and the guest's arguments
// are gone — fine for a refusal. One line per name for the first few calls.
static int stub_said(const char *nm) {
    static struct { const char *n; unsigned c; } seen[256];
    static unsigned ns;
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&mu);
    unsigned i = 0;
    for (; i < ns; i++) if (seen[i].n == nm) break;
    if (i == ns && ns < 256) { seen[ns].n = nm; seen[ns].c = 0; ns++; }
    unsigned c = i < 256 ? seen[i].c++ : 99;
    pthread_mutex_unlock(&mu);
    return c < 3;
}
static long st_m1(const char *nm) {         // int/ssize_t: -1, errno ENOSYS
    if (stub_said(nm)) fprintf(stderr, "  [glibc] %s: not implemented -> -1/ENOSYS\n", nm);
    errno = ENOSYS;
    return -1;
}
static long st_null(const char *nm) {       // pointer-returning: NULL, errno ENOSYS
    if (stub_said(nm)) fprintf(stderr, "  [glibc] %s: not implemented -> NULL/ENOSYS\n", nm);
    errno = ENOSYS;
    return 0;
}
static long st_err(const char *nm) {        // returns an error NUMBER (pthread/posix_spawn)
    if (stub_said(nm)) fprintf(stderr, "  [glibc] %s: not implemented -> ENOSYS\n", nm);
    return LX_ENOSYS;
}
static long st_zero(const char *nm) {       // harmless to accept: 0
    if (stub_said(nm)) fprintf(stderr, "  [glibc] %s: accepted as a no-op\n", nm);
    return 0;
}

// ---------- process identity, set by __libc_start_main ----------
char *klg_program_invocation_name = (char *)"hlvr";
char *klg_program_invocation_short_name = (char *)"hlvr";
void *klg_libc_stack_end;
char  klg_libc_single_threaded;              // 0: never claim single-threaded
static char g_exe_path[PATH_MAX];

void kl_glibc_set_exe_path(const char *p) {
    if (!realpath(p, g_exe_path)) snprintf(g_exe_path, sizeof g_exe_path, "%s", p);
}

typedef int (*main_fn)(int, char **, char **);
static int klg___libc_start_main(main_fn main, int argc, char **argv,
                                 void (*init)(int, char **, char **), void (*fini)(void),
                                 void (*rtld_fini)(void), void *stack_end) {
    (void)fini; (void)rtld_fini;
    extern char **environ;
    klg_libc_stack_end = stack_end;
    if (argc > 0 && argv[0]) {
        klg_program_invocation_name = argv[0];
        const char *b = strrchr(argv[0], '/');
        klg_program_invocation_short_name = (char *)(b ? b + 1 : argv[0]);
    }
    char **envp = argv + argc + 1;
    // glibc >= 2.34 passes NULL here: the executable's init_array already ran
    // (kl_glibc ran it, as ld.so would have). Honour a non-NULL one anyway.
    if (init) init(argc, argv, envp);
    fprintf(stderr, "  [glibc] __libc_start_main: entering main(%d, ...)\n", argc);
    fflush(NULL);
    int r = main(argc, argv, environ);
    fprintf(stderr, "  [glibc] main returned %d\n", r);
    fflush(NULL);
    exit(r);
}

// ---------- errno, auxv, misc internals ----------
int *klb_errno(void);                           // kl_libc.c
unsigned long klb_getauxval(unsigned long);     // kl_libc_slink.c
char *klb_realpath(const char *, char *);
char *klb_getcwd(char *, size_t);
int  klb_stat(const char *, void *);
int  klb_lstat(const char *, void *);
int  klb_fstat(int, void *);
int  klb_sigaction(int, const void *, void *);
int  klb_pthread_sigmask(int, const uint64_t *, uint64_t *);
void klb__exit(int);                            // kl_libc.c: reports, runs the exit hooks

static int h_errno_v;
static int *klg___h_errno_location(void) { return &h_errno_v; }

static void klg___assert_fail(const char *a, const char *file, unsigned line,
                              const char *fn) {
    fprintf(stderr, "[klepton] fatal: guest assertion `%s' failed at %s:%u (%s)\n",
            a ? a : "?", file ? file : "?", line, fn ? fn : "?");
    kl_fatal_prepare();
    abort();
}
static char *klg_secure_getenv(const char *n) { return getenv(n); }
static ssize_t klg___getdelim(char **l, size_t *n, int d, void *f) {
    return getdelim(l, n, d, kl_host_file(f));
}
static char *klg___xpg_basename(char *p) { return basename(p); }
static int klg___xpg_strerror_r(int e, char *buf, size_t n) {
    return strerror_r(kl_errno_from_linux(e), buf, n) ? 34 /* ERANGE */ : 0;
}
static char *klg_strerror_l(int e, void *l) { (void)l; return strerror(kl_errno_from_linux(e)); }
static void *klg___sched_cpualloc(size_t count) { return calloc(1, (count + 63) / 64 * 8); }
static void klg___sched_cpufree(void *p) { free(p); }
static size_t klg___fpending(void *f) { (void)f; return 0; }
// sysconf: glibc numbers its names differently from bionic (bits/confname.h:
// _SC_PAGESIZE is 30 here, 0x27 there), so klb_sysconf would answer the wrong
// question. The names a game engine asks, mapped to Darwin's.
static long klg_sysconf(int n) {
    switch (n) {
    case 0:  return sysconf(_SC_ARG_MAX);
    case 1:  return sysconf(_SC_CHILD_MAX);
    case 2:  return 100;                               // _SC_CLK_TCK, Linux's HZ
    case 3:  return sysconf(_SC_NGROUPS_MAX);
    case 4:  return sysconf(_SC_OPEN_MAX);
    case 5:  return sysconf(_SC_STREAM_MAX);
    case 29: return 200809L;                           // _SC_VERSION
    case 30: return getpagesize();                     // _SC_PAGESIZE
    case 69: case 70: return 16384;                    // _SC_GETGR/GETPW_R_SIZE_MAX
    case 71: return sysconf(_SC_LOGIN_NAME_MAX);
    case 72: return sysconf(_SC_TTY_NAME_MAX);
    case 73: return 4;                                 // THREAD_DESTRUCTOR_ITERATIONS
    case 74: return 1024;                              // THREAD_KEYS_MAX
    case 75: return 16384;                             // THREAD_STACK_MIN (glibc arm64: 128K? Linux min)
    case 76: return -1;                                // THREAD_THREADS_MAX: no limit
    case 83: return sysconf(_SC_NPROCESSORS_CONF);
    case 84: return sysconf(_SC_NPROCESSORS_ONLN);
    case 85: return sysconf(_SC_PHYS_PAGES);
    case 86: return (long)(kl_mem_available_bytes() / (uint64_t)getpagesize());
    case 149: return 200809L;                          // _SC_MONOTONIC_CLOCK
    case 188: case 190: case 191: case 194: return 64; // L1 cache line sizes
    default:
        fprintf(stderr, "  [glibc] sysconf(%d): not mapped -> -1/EINVAL\n", n);
        errno = EINVAL;
        return -1;
    }
}
static long klg___sysconf(int n) { return klg_sysconf(n); }

// The executable's own path. hlvr derives its whole install from
// readlink("/proc/self/exe") (the libraries live beside it), and Darwin has no
// /proc, so this one path is answered here; anything else goes to Darwin.
static ssize_t klg_readlink(const char *p, char *buf, size_t n) {
    if (p && !strcmp(p, "/proc/self/exe") && g_exe_path[0]) {
        size_t l = strlen(g_exe_path);
        if (l > n) l = n;
        memcpy(buf, g_exe_path, l);
        return (ssize_t)l;
    }
    return readlink(p, buf, n);
}

// ...and lstat of the same link, which tier0's Plat_GetExecutablePathUTF8 asks
// first to size its buffer (st_size of a symlink is the target's length).
typedef struct {
    uint64_t st_dev, st_ino;
    uint32_t st_mode, st_nlink, st_uid, st_gid;
    uint64_t st_rdev, pad1;
    int64_t  st_size;
    int32_t  st_blksize, pad2;
    int64_t  st_blocks;
    int64_t  times[6];
    uint32_t unused[2];
} klg_stat;
_Static_assert(sizeof(klg_stat) == 128, "glibc aarch64 struct stat");
static int klg_lstat(const char *p, klg_stat *b) {
    if (p && !strcmp(p, "/proc/self/exe") && g_exe_path[0]) {
        // The executable need not exist: on device (and in the simulator) every
        // library, hlvr included, is a framework in the bundle and the libdir
        // only names where they "live". The link itself is ours, so it is
        // answered whether or not its target is there — tier0 treats a failed
        // lstat here as a fatal "Unable to get executable filename".
        if (klb_lstat(g_exe_path, b) != 0) memset(b, 0, sizeof *b);
        b->st_mode = (b->st_mode & ~0170000u) | 0120000u | 0777u;      // S_IFLNK
        b->st_nlink = b->st_nlink ? b->st_nlink : 1;
        b->st_size = (int64_t)strlen(g_exe_path);
        return 0;
    }
    return klb_lstat(p, b);
}
static int klg___lxstat(int v, const char *p, void *b) { (void)v; return klg_lstat(p, b); }

// ---------- _dl_find_object (glibc 2.35) ----------
// libgcc's unwinder asks this, not dl_iterate_phdr, for the PT_GNU_EH_FRAME of
// the object containing a pc — so without it no C++ exception can be caught.
// struct dl_find_object on aarch64: flags, map_start, map_end, link_map,
// eh_frame, then 7 reserved words.
struct klg_dl_find_object {
    unsigned long long flags;
    void *map_start, *map_end, *link_map, *eh_frame;
    unsigned long long reserved[7];
};
typedef struct { uint32_t p_type, p_flags; uint64_t p_offset, p_vaddr, p_paddr,
                 p_filesz, p_memsz, p_align; } klg_phdr;
#define PT_GNU_EH_FRAME 0x6474e550

static int klg__dl_find_object(void *pc, struct klg_dl_find_object *r) {
    int n = kl_dl_image_count();
    for (int i = 0; i < n; i++) {
        kl_image *img = kl_dl_image_at(i, NULL);
        uint8_t *b = kl_base(img);
        if (!b || (uint8_t *)pc < b || (uint8_t *)pc >= b + kl_span(img)) continue;
        unsigned np = 0;
        const klg_phdr *ph = kl_phdrs(img, &np);
        void *eh = NULL;
        for (unsigned k = 0; ph && k < np; k++)
            if (ph[k].p_type == PT_GNU_EH_FRAME) eh = b + ph[k].p_vaddr;
        memset(r, 0, sizeof *r);
        r->map_start = b;
        r->map_end   = b + kl_span(img);
        r->link_map  = img;
        r->eh_frame  = eh;
        return 0;
    }
    return -1;
}

static void *klg_dlmopen(long ns, const char *p, int f) { (void)ns; (void)p; (void)f; return NULL; }

// ---------- ctype ----------
// glibc's <ctype.h> indexes these tables directly (c in [-128, 255]), through
// a pointer it fetches once per call from __ctype_b_loc(). The bit order is
// glibc's little-endian _ISbit(): bits 0-7 of the class number land in the
// HIGH byte.
#define ISBIT(b) ((unsigned short)((b) < 8 ? ((1u << (b)) << 8) : ((1u << (b)) >> 8)))
enum { I_UPPER = 0, I_LOWER, I_ALPHA, I_DIGIT, I_XDIGIT, I_SPACE, I_PRINT, I_GRAPH,
       I_BLANK, I_CNTRL, I_PUNCT, I_ALNUM };
static unsigned short g_ctb[384];
static int32_t g_ctlower[384], g_ctupper[384];
static const unsigned short *g_ctb_p = g_ctb + 128;
static const int32_t *g_ctlower_p = g_ctlower + 128, *g_ctupper_p = g_ctupper + 128;

static void ctype_init(void) {
    static int done;
    if (done) return;
    for (int i = -128; i < 256; i++) {
        unsigned short v = 0;
        int c = i;
        if (c >= 0 && c < 128) {
            if (c >= 'A' && c <= 'Z') v |= ISBIT(I_UPPER) | ISBIT(I_ALPHA) | ISBIT(I_ALNUM);
            if (c >= 'a' && c <= 'z') v |= ISBIT(I_LOWER) | ISBIT(I_ALPHA) | ISBIT(I_ALNUM);
            if (c >= '0' && c <= '9') v |= ISBIT(I_DIGIT) | ISBIT(I_ALNUM) | ISBIT(I_XDIGIT);
            if ((c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) v |= ISBIT(I_XDIGIT);
            if (c == ' ' || (c >= '\t' && c <= '\r')) v |= ISBIT(I_SPACE);
            if (c == ' ' || c == '\t') v |= ISBIT(I_BLANK);
            if (c < 32 || c == 127) v |= ISBIT(I_CNTRL);
            if (c >= 32 && c < 127) v |= ISBIT(I_PRINT);
            if (c > 32 && c < 127) v |= ISBIT(I_GRAPH);
            if (c > 32 && c < 127 && !isalnum(c)) v |= ISBIT(I_PUNCT);
        }
        g_ctb[i + 128] = v;
        g_ctlower[i + 128] = (c >= 'A' && c <= 'Z') ? c + 32 : c;
        g_ctupper[i + 128] = (c >= 'a' && c <= 'z') ? c - 32 : c;
    }
    done = 1;
}
static const unsigned short **klg___ctype_b_loc(void) { ctype_init(); return &g_ctb_p; }
static const int32_t **klg___ctype_tolower_loc(void) { ctype_init(); return &g_ctlower_p; }
static const int32_t **klg___ctype_toupper_loc(void) { ctype_init(); return &g_ctupper_p; }

// ---------- locales ----------
// libstdc++ (the "gnu" locale model) does not treat locale_t as opaque: its
// ctype<char> reads __ctype_b / __ctype_tolower / __ctype_toupper straight out
// of the struct __newlocale returned. So the object has glibc's layout, the
// tables are the C locale's above, and every _l function ignores it — the only
// locale a glibc guest gets here is "C", which is also all Alyx asks for.
typedef struct {
    void *locales[13];
    const unsigned short *ctype_b;
    const int32_t *ctype_tolower, *ctype_toupper;
    const char *names[13];
} klg_locale;
static klg_locale g_c_locale;
static _Thread_local void *g_cur_locale = (void *)-1;    // LC_GLOBAL_LOCALE

static klg_locale *c_locale(void) {
    ctype_init();
    if (!g_c_locale.ctype_b) {
        g_c_locale.ctype_b = g_ctb_p;
        g_c_locale.ctype_tolower = g_ctlower_p;
        g_c_locale.ctype_toupper = g_ctupper_p;
        for (int i = 0; i < 13; i++) g_c_locale.names[i] = "C";
    }
    return &g_c_locale;
}
static void *klg_newlocale(int mask, const char *name, void *base) {
    (void)mask;
    if (name && *name && strcmp(name, "C") && strcmp(name, "POSIX") &&
        strncmp(name, "C.", 2) && strncmp(name, "en_US", 5)) {
        errno = ENOENT;              // an unknown locale, as glibc says it
        return NULL;
    }
    if (base && base != (void *)c_locale()) return base;
    klg_locale *l = malloc(sizeof *l);
    if (l) *l = *c_locale();
    return l;
}
static void *klg_duplocale(void *l) {
    if (l == (void *)-1 || !l) l = c_locale();
    klg_locale *d = malloc(sizeof *d);
    if (d) *d = *(klg_locale *)l;
    return d;
}
static void klg_freelocale(void *l) { if (l && l != (void *)-1 && l != &g_c_locale) free(l); }
static void *klg_uselocale(void *l) {
    void *old = g_cur_locale;
    if (l) g_cur_locale = l;
    return old;
}
// glibc numbers categories CTYPE=0 ... ALL=6; Darwin ALL=0 ... — and the host
// process's locale is not the guest's to change. Everything is "C".
static char *klg_setlocale(int cat, const char *name) {
    (void)cat;
    if (!name || !*name || !strcmp(name, "C") || !strcmp(name, "POSIX") ||
        !strncmp(name, "C.", 2))
        return (char *)"C";
    return NULL;
}
// nl_langinfo items are _NL_ITEM(category, index); CODESET is (LC_CTYPE, 14).
static char *klg_nl_langinfo(int item) {
    if (item == 14) return (char *)"ANSI_X3.4-1968";
    return (char *)"";
}
static char *klg_nl_langinfo_l(int item, void *l) { (void)l; return klg_nl_langinfo(item); }
static int klg_strcoll_l(const char *a, const char *b, void *l) { (void)l; return strcmp(a, b); }
static size_t klg_strxfrm_l(char *d, const char *s, size_t n, void *l) {
    (void)l; size_t len = strlen(s);
    if (n) { strncpy(d, s, n); if (len >= n) d[n - 1] = 0; }
    return len;
}
static int klg_wcscoll_l(const wchar_t *a, const wchar_t *b, void *l) { (void)l; return wcscmp(a, b); }
static size_t klg_wcsxfrm_l(wchar_t *d, const wchar_t *s, size_t n, void *l) {
    (void)l; size_t len = wcslen(s);
    if (n) { wcsncpy(d, s, n); if (len >= n) d[n - 1] = 0; }
    return len;
}
static wint_t klg_towlower_l(wint_t c, void *l) { (void)l; return towlower(c); }
static wint_t klg_towupper_l(wint_t c, void *l) { (void)l; return towupper(c); }
static wctype_t klg_wctype_l(const char *n, void *l) { (void)l; return wctype(n); }
static int klg_iswctype_l(wint_t c, wctype_t t, void *l) { (void)l; return iswctype(c, t); }
static size_t klg_strftime_l(char *s, size_t m, const char *f, const struct tm *t, void *l) {
    (void)l; return strftime(s, m, f, t);
}
static size_t klg_wcsftime_l(wchar_t *s, size_t m, const wchar_t *f, const struct tm *t, void *l) {
    (void)l; return wcsftime(s, m, f, t);
}
static double klg_strtod_l(const char *s, char **e, void *l) { (void)l; return strtod(s, e); }
static float  klg_strtof_l(const char *s, char **e, void *l) { (void)l; return strtof(s, e); }
static long long klg_strtoll_l(const char *s, char **e, int b, void *l) { (void)l; return strtoll(s, e, b); }
static unsigned long long klg_strtoull_l(const char *s, char **e, int b, void *l) { (void)l; return strtoull(s, e, b); }

// Every other *_l a glibc library calls directly (pango's strtod_l among them):
// the locale_t it passes is OURS (the glibc-shaped struct above), so it must
// never reach Darwin's *_l functions, which validate it and trap.
static long klg_strtol_l(const char *s, char **e, int b, void *l) { (void)l; return strtol(s, e, b); }
static unsigned long klg_strtoul_l(const char *s, char **e, int b, void *l) { (void)l; return strtoul(s, e, b); }
#define CT_L(fn) static int klg_##fn##_l(int c, void *l) { (void)l; return fn(c); }
CT_L(isalnum) CT_L(isalpha) CT_L(isblank) CT_L(iscntrl) CT_L(isdigit) CT_L(isgraph)
CT_L(islower) CT_L(isprint) CT_L(ispunct) CT_L(isspace) CT_L(isupper) CT_L(isxdigit)
CT_L(tolower) CT_L(toupper)
#undef CT_L
static int klg_strcasecmp_l(const char *a, const char *b, void *l) { (void)l; return strcasecmp(a, b); }
static int klg_strncasecmp_l(const char *a, const char *b, size_t n, void *l) { (void)l; return strncasecmp(a, b, n); }

// gettext: no catalogues, so every message is its own translation.
static char *klg_gettext(const char *m) { return (char *)m; }
static char *klg_dgettext(const char *d, const char *m) { (void)d; return (char *)m; }
static char *klg_dcgettext(const char *d, const char *m, int c) { (void)d; (void)c; return (char *)m; }
static char *klg_dcngettext(const char *d, const char *m1, const char *m2, unsigned long n, int c) {
    (void)d; (void)c; return (char *)(n == 1 ? m1 : m2);
}
static char *klg_textdomain(const char *d) { return (char *)(d ? d : "messages"); }
static char *klg_bindtextdomain(const char *d, const char *dir) { (void)d; return (char *)dir; }
static char *klg_bind_textdomain_codeset(const char *d, const char *c) { (void)d; return (char *)c; }

// ---------- signals: glibc's 128-byte sigset_t and 152-byte sigaction ----------
// The bionic shims (klb_sigaction / klb_pthread_sigmask) take a 64-bit mask, bit
// (signo-1), Linux numbering; glibc's sigset_t is 16 such words. Only the first
// word means anything below signal 65, so the ops below keep the whole set and
// the translations hand the first word on.
typedef struct { uint64_t w[16]; } klg_sigset;
typedef struct { void *handler; klg_sigset mask; int32_t flags; int32_t pad; void *restorer; } klg_sigaction_t;
typedef struct { int32_t flags; int32_t pad; void *handler; uint64_t mask; void *restorer; } klb_sigaction_t;
_Static_assert(sizeof(klg_sigaction_t) == 152, "glibc aarch64 struct sigaction");

static int bad_sig(int s) { return s < 1 || s > 1024; }
static int klg_sigemptyset(klg_sigset *s) { memset(s, 0, sizeof *s); return 0; }
static int klg_sigfillset(klg_sigset *s)  { memset(s, 0xff, sizeof *s); return 0; }
static int klg_sigaddset(klg_sigset *s, int n) {
    if (bad_sig(n)) { errno = EINVAL; return -1; }
    s->w[(n - 1) / 64] |= 1ull << ((n - 1) % 64); return 0;
}
static int klg_sigdelset(klg_sigset *s, int n) {
    if (bad_sig(n)) { errno = EINVAL; return -1; }
    s->w[(n - 1) / 64] &= ~(1ull << ((n - 1) % 64)); return 0;
}
static int klg_sigismember(const klg_sigset *s, int n) {
    if (bad_sig(n)) { errno = EINVAL; return -1; }
    return (s->w[(n - 1) / 64] >> ((n - 1) % 64)) & 1;
}
static int klg_sigisemptyset(const klg_sigset *s) {
    for (int i = 0; i < 16; i++) if (s->w[i]) return 0;
    return 1;
}
static int klg_sigaction(int sig, const klg_sigaction_t *in, klg_sigaction_t *old) {
    klb_sigaction_t bi, bo;
    if (in) {
        memset(&bi, 0, sizeof bi);
        bi.handler = in->handler; bi.flags = in->flags;
        bi.mask = in->mask.w[0]; bi.restorer = in->restorer;
    }
    int r = klb_sigaction(sig, in ? &bi : NULL, old ? &bo : NULL);
    if (r == 0 && old) {
        memset(old, 0, sizeof *old);
        old->handler = bo.handler; old->flags = bo.flags;
        old->mask.w[0] = bo.mask; old->restorer = bo.restorer;
    }
    return r;
}
// Adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox)
// runtime/linux/kl_glibc.c (unblock_fatal).
//
// A synchronous fault raised in a thread that has its signal BLOCKED is not
// queued: the kernel kills the process outright, with no handler and so no
// report from kl_fault.c. Engine worker threads routinely block "all signals"
// (sigfillset + pthread_sigmask) — Source 2's job threads, SDL's, V8's — so a
// fault in one used to end the run silently. Keep the fault signals deliverable
// whatever the guest asks: SIGILL 4, SIGTRAP 5, SIGABRT 6, SIGBUS 7, SIGFPE 8,
// SIGSEGV 11 (Linux numbering, bit signo-1 of the first word). One more bit,
// and it is ours rather than Glovebox's: klb_pthread_sigmask hands the word to
// Darwin WITHOUT renumbering, and Darwin's SIGBUS is 10 — the bit a guest sets
// for Linux SIGUSR1, and the one sigfillset sets anyway — while Darwin raises
// SIGBUS for most bad accesses. So bit 9 is cleared too; a guest that really
// blocks Linux SIGUSR1 loses that block (it was blocking Darwin SIGBUS).
// SIG_UNBLOCK (Linux 1) cannot block anything and passes through untouched.
// The old mask handed back is what is really in force. glibc personality only;
// Android guests keep the raw klb_pthread_sigmask.
#define KLG_FATAL_SIGS ((1ull << (4 - 1)) | (1ull << (5 - 1)) | (1ull << (6 - 1)) | \
                        (1ull << (7 - 1)) | (1ull << (8 - 1)) | (1ull << (11 - 1)) | \
                        (1ull << (10 - 1)) /* Darwin SIGBUS, see above */)
static int klg_pthread_sigmask(int how, const klg_sigset *s, klg_sigset *o) {
    uint64_t ow = 0, w0 = 0;
    if (s) { w0 = s->w[0]; if (how != 1) w0 &= ~KLG_FATAL_SIGS; }
    int r = klb_pthread_sigmask(how, s ? &w0 : NULL, o ? &ow : NULL);
    if (!r && o) { memset(o, 0, sizeof *o); o->w[0] = ow; }
    return r;
}
static int klg_sigprocmask(int how, const klg_sigset *s, klg_sigset *o) {
    int r = klg_pthread_sigmask(how, s, o);
    if (r) { errno = r; return -1; }
    return 0;
}

// ---------- fortify / C23 / LFS spellings that need an argument shift ----------
int klh_printf(const char *fmt, kl_va *va);
int klh_fprintf(void *f, const char *fmt, kl_va *va);
int klh_asprintf(char **out, const char *fmt, kl_va *va);
int klh_dprintf(int fd, const char *fmt, kl_va *va);
int klh_syslog(int pri, const char *fmt, kl_va *va);
int klh_fscanf(void *f, const char *fmt, kl_va *va);

int klg___printf_chk(int flag, const char *fmt, kl_va *va) { (void)flag; return klh_printf(fmt, va); }
int klg___fprintf_chk(void *f, int flag, const char *fmt, kl_va *va) { (void)flag; return klh_fprintf(f, fmt, va); }
int klg___asprintf_chk(char **o, int flag, const char *fmt, kl_va *va) { (void)flag; return klh_asprintf(o, fmt, va); }
int klg___dprintf_chk(int fd, int flag, const char *fmt, kl_va *va) { (void)flag; return klh_dprintf(fd, fmt, va); }
int klg___syslog_chk(int pri, int flag, const char *fmt, kl_va *va) { (void)flag; return klh_syslog(pri, fmt, va); }
void klg_err(int ev, const char *fmt, kl_va *va) {
    fprintf(stderr, "%s: ", klg_program_invocation_short_name);
    if (fmt) klh_fprintf(stderr, fmt, va);
    fprintf(stderr, ": %s\n", strerror(errno));
    exit(ev);
}
void klg_errx(int ev, const char *fmt, kl_va *va) {
    fprintf(stderr, "%s: ", klg_program_invocation_short_name);
    if (fmt) klh_fprintf(stderr, fmt, va);
    fputc('\n', stderr);
    exit(ev);
}
void klg_warn(const char *fmt, kl_va *va) {
    fprintf(stderr, "%s: ", klg_program_invocation_short_name);
    if (fmt) klh_fprintf(stderr, fmt, va);
    fprintf(stderr, ": %s\n", strerror(errno));
}
extern char klv___printf_chk[], klv___fprintf_chk[], klv___asprintf_chk[],
            klv___dprintf_chk[], klv___syslog_chk[], klv_g_err[], klv_g_errx[],
            klv_g_warn[], klg_setjmp[];

// The va_list consumers: a guest va_list arrives as a pointer (AAPCS64 passes
// the 32-byte struct by reference), i.e. a kl_va *.
static void *shim_fn(const char *n) { return kl_shim_lookup_base(n); }
static int klg___vfprintf_chk(void *f, int flag, const char *fmt, void *va) {
    (void)flag; return ((int (*)(void *, const char *, void *))shim_fn("vfprintf"))(f, fmt, va);
}
static int klg___vprintf_chk(int flag, const char *fmt, void *va) {
    (void)flag; return ((int (*)(const char *, void *))shim_fn("vprintf"))(fmt, va);
}
static int klg___vasprintf_chk(char **o, int flag, const char *fmt, void *va) {
    (void)flag; return ((int (*)(char **, const char *, void *))shim_fn("vasprintf"))(o, fmt, va);
}
static int klg_vfscanf(void *f, const char *fmt, kl_va *va) { return klh_fscanf(f, fmt, va); }
static void klg___explicit_bzero_chk(void *p, size_t n, size_t d) {
    (void)d; memset(p, 0, n); __asm__ volatile("" ::: "memory");
}
static long klg___fdelt_chk(long d) { return d / 64; }
static char *klg___realpath_chk(const char *p, char *r, size_t n) { (void)n; return klb_realpath(p, r); }
static size_t klg___mbstowcs_chk(wchar_t *d, const char *s, size_t n, size_t dl) { (void)dl; return mbstowcs(d, s, n); }

static int klg___xstat(int v, const char *p, void *b)  { (void)v; return klb_stat(p, b); }
static int klg___fxstat(int v, int fd, void *b)        { (void)v; return klb_fstat(fd, b); }

// fstatat / fstatfs, which bionic's table never needed. AT_FDCWD is -100 on
// Linux and -2 on Darwin; AT_SYMLINK_NOFOLLOW is 0x100 vs 0x20.
static int klg_fstatat(int dfd, const char *p, void *b, int fl) {
    if ((dfd == -100 || (p && p[0] == '/')))
        return (fl & 0x100) ? klb_lstat(p, b) : klb_stat(p, b);
    if (p && !*p && (fl & 0x1000 /* AT_EMPTY_PATH */)) return klb_fstat(dfd, b);
    errno = ENOSYS;                     // a relative path under a real dirfd
    return -1;
}
int klb_statfs(const char *path, void *out);
static int klg_fstatfs(int fd, void *out) {
    char p[PATH_MAX];
    if (fcntl(fd, F_GETPATH, p) != 0) return -1;
    return klb_statfs(p, out);
}
static int klg_faccessat(int dfd, const char *p, int mode, int fl) {
    (void)fl;
    if (dfd == -100 || (p && p[0] == '/'))
        return ((int (*)(const char *, int))shim_fn("access"))(p, mode);
    errno = ENOSYS;
    return -1;
}
static int klg_posix_fadvise(int fd, long o, long l, int a) { (void)fd; (void)o; (void)l; (void)a; return 0; }
static int klg_posix_fallocate(int fd, long o, long l) {
    struct stat st;
    if (fstat(fd, &st) != 0) return 9;   /* EBADF */
    if (st.st_size < o + l && ftruncate(fd, o + l) != 0) return 28; /* ENOSPC */
    return 0;
}
static int klg_eaccess(const char *p, int m) { return ((int (*)(const char *, int))shim_fn("access"))(p, m); }
static int klg_creat(const char *p, int m) {
    char kp[1024];
    return open(kl_guest_path(p, kp, sizeof kp), O_CREAT | O_WRONLY | O_TRUNC, m);
}
static char *klg_get_current_dir_name(void) { return klb_getcwd(NULL, 0); }

// qsort_r: glibc's comparator takes the context LAST, Darwin's FIRST.
struct qr { int (*cmp)(const void *, const void *, void *); void *arg; };
static int qr_tramp(void *c, const void *a, const void *b) {
    struct qr *q = c; return q->cmp(a, b, q->arg);
}
static void klg_qsort_r(void *b, size_t n, size_t sz,
                        int (*cmp)(const void *, const void *, void *), void *arg) {
    struct qr q = { cmp, arg };
    qsort_r(b, n, sz, &q, qr_tramp);
}
static int klg_strverscmp(const char *a, const char *b) { return strcmp(a, b); }
static int klg_versionsort(const void *a, const void *b) {
    return strcmp((*(const char *const *)a) + 19, (*(const char *const *)b) + 19);  // d_name
}
static void klg_malloc_stats(void) {}
static int klg_bcmp(const void *a, const void *b, size_t n) { return memcmp(a, b, n); }
static int klg___fsetlocking(void *f, int t) { (void)f; (void)t; return 1; /* FSETLOCKING_INTERNAL */ }
static int klg_fileno_unlocked(void *f) { return fileno(kl_host_file(f)); }
static char *klg_fgets_unlocked(char *s, int n, void *f) { return fgets(s, n, kl_host_file(f)); }
static size_t klg___mbrlen(const char *s, size_t n, mbstate_t *ps) { return mbrlen(s, n, ps); }
static int klg___open64_2(const char *p, int fl) {
    return ((int (*)(const char *, int))shim_fn("__open_2"))(p, fl);
}
static int klg___openat_2(int d, const char *p, int fl) {
    return ((int (*)(int, const char *, int, int))shim_fn("openat"))(d, p, fl, 0);
}
static int klg_sched_getcpu(void) { return 0; }
static int klg_pthread_getaffinity_np(pthread_t t, size_t sz, void *set) {
    (void)t;
    memset(set, 0, sz);
    long n = sysconf(_SC_NPROCESSORS_ONLN);
    for (long i = 0; i < n && (size_t)(i / 8) < sz; i++) ((uint8_t *)set)[i / 8] |= 1u << (i % 8);
    return 0;
}
static int klg_pthread_getname_np(pthread_t t, char *b, size_t n) { return pthread_getname_np(t, b, n); }
static int klg_getresuid(uid_t *r, uid_t *e, uid_t *s) {
    if (r) *r = getuid(); if (e) *e = geteuid(); if (s) *s = geteuid(); return 0;
}
static int klg_getresgid(gid_t *r, gid_t *e, gid_t *s) {
    if (r) *r = getgid(); if (e) *e = getegid(); if (s) *s = getegid(); return 0;
}
static int klg_get_nprocs(void) { return (int)sysconf(_SC_NPROCESSORS_ONLN); }

// ---------- eventfd, with the counter ----------
// The bionic shim's eventfd is a self-connected datagram socket that queues one
// datagram per write, and refuses EFD_SEMAPHORE — enough for Qt's wakeup
// channel. Source 2's tier0 builds its semaphores out of eventfd(0,
// EFD_SEMAPHORE|EFD_NONBLOCK|EFD_CLOEXEC) and waits on them with poll, so it
// needs the real thing: a 64-bit counter, read returning 1 (semaphore) or the
// whole count, write adding. The socket stays as the pollable object, with one
// invariant: a token datagram is queued iff the counter is non-zero. read and
// write on such an fd come here; every other fd goes straight on.
#define EFD_MAX 4096
typedef struct { int live, sem, nonblock; uint64_t count; pthread_mutex_t mu; } efd_t;
static efd_t *g_efd[EFD_MAX];
static pthread_mutex_t g_efd_mu = PTHREAD_MUTEX_INITIALIZER;

static int efd_token(int fd, int on) {
    char b = 1;
    if (on) return send(fd, &b, 1, 0) == 1 ? 0 : -1;
    return recv(fd, &b, 1, MSG_DONTWAIT) == 1 ? 0 : -1;
}
static int klg_eventfd(unsigned initval, int flags) {
    int sv[2];
    // A connected pair, not one self-connected socket: we hold the write end
    // privately, the guest's fd is the read end it polls.
    if (socketpair(AF_UNIX, SOCK_DGRAM, 0, sv) != 0) return -1;
    if (sv[0] >= EFD_MAX) { close(sv[0]); close(sv[1]); errno = EMFILE; return -1; }
    if (flags & 0x80000) { fcntl(sv[0], F_SETFD, FD_CLOEXEC); fcntl(sv[1], F_SETFD, FD_CLOEXEC); }
    efd_t *e = calloc(1, sizeof *e);
    pthread_mutex_init(&e->mu, NULL);
    e->sem = flags & 1;
    e->nonblock = (flags & 0x800) != 0;
    e->count = initval;
    e->live = sv[1];                    // the private write end
    pthread_mutex_lock(&g_efd_mu);
    g_efd[sv[0]] = e;
    pthread_mutex_unlock(&g_efd_mu);
    if (initval) efd_token(sv[1], 1);
    return sv[0];
}
static ssize_t efd_write(efd_t *e, const void *buf, size_t n) {
    if (n < 8) { errno = EINVAL; return -1; }
    uint64_t v;
    memcpy(&v, buf, 8);
    if (v == UINT64_MAX) { errno = EINVAL; return -1; }
    pthread_mutex_lock(&e->mu);
    if (!e->count && v) efd_token(e->live, 1);
    e->count += v;
    pthread_mutex_unlock(&e->mu);
    return 8;
}
static ssize_t efd_read(int fd, efd_t *e, void *buf, size_t n) {
    if (n < 8) { errno = EINVAL; return -1; }
    for (;;) {
        pthread_mutex_lock(&e->mu);
        if (e->count) {
            uint64_t v = e->sem ? 1 : e->count;
            e->count -= v;
            if (!e->count) efd_token(fd, 0);
            pthread_mutex_unlock(&e->mu);
            memcpy(buf, &v, 8);
            return 8;
        }
        pthread_mutex_unlock(&e->mu);
        if (e->nonblock) { errno = EAGAIN; return -1; }
        char b;
        if (recv(fd, &b, 1, MSG_PEEK) < 0 && errno != EINTR) return -1;
    }
}
static efd_t *efd_of(int fd) { return (fd >= 0 && fd < EFD_MAX) ? g_efd[fd] : NULL; }
static ssize_t klg_read(int fd, void *buf, size_t n) {
    efd_t *e = efd_of(fd);
    if (e) return efd_read(fd, e, buf, n);
    return ((ssize_t (*)(int, void *, size_t))shim_fn("read"))(fd, buf, n);
}
static ssize_t klg_write(int fd, const void *buf, size_t n) {
    efd_t *e = efd_of(fd);
    if (e) return efd_write(e, buf, n);
    return write(fd, buf, n);
}
static int klg_eventfd_read(int fd, uint64_t *v) { return klg_read(fd, v, 8) == 8 ? 0 : -1; }
static int klg_eventfd_write(int fd, uint64_t v) { return klg_write(fd, &v, 8) == 8 ? 0 : -1; }
static int klg_close(int fd) {
    efd_t *e = efd_of(fd);
    if (e) {
        pthread_mutex_lock(&g_efd_mu);
        g_efd[fd] = NULL;
        pthread_mutex_unlock(&g_efd_mu);
        close(e->live);
        pthread_mutex_destroy(&e->mu);
        free(e);
    }
    return ((int (*)(int))shim_fn("close"))(fd);
}

// mmap, traced (KL_TRACE_MMAP=1): hint, size, flags and what came back.
void *klb_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off);
static void *klg_mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off) {
    void *p = klb_mmap(addr, len, prot, flags, fd, off);
    static int tr = -1;
    if (tr < 0) tr = kl_env_on("KL_TRACE_MMAP", 0);
    if (tr) {
        size_t o = 0;
        const char *img = kl_addr_image(__builtin_return_address(0), &o);
        fprintf(stderr, "  [glibc] mmap(%p, %#zx, prot %d, flags %#x, fd %d) -> %p  [%s+%#zx]\n",
                addr, len, prot, flags, fd, p, img ? img : "?", o);
    }
    return p;
}

// ---------- 4 KB pages on a 16 KB host ----------
// The guest was built for 4 KB pages and several Source 2 allocators hard-code
// that rather than ask sysconf: panorama's arenas reserve 64 KB and then commit
// 4 KB at a time, which tier0's Plat_VirtualAlloc turns into mprotect(RW) on a
// 4 KB-aligned address. Darwin arm64 pages are 16 KB and mprotect refuses an
// unaligned start (EINVAL), so the second commit into every arena failed and the
// engine reported "OUT OF MEMORY ... 4096" right as the main menu came up.
// Granting access rounds OUTWARD to whole host pages — the neighbours are part
// of the same reservation (a host mapping never shares a host page) and being
// readable early costs nothing. Taking access away, unmapping or discarding
// rounds INWARD: a neighbour still in use must never lose its page or its data,
// so only host pages wholly inside the range are touched and the rest is left
// committed (a little memory kept, never a fault).
static int host_span(void *addr, size_t len, int outward, uintptr_t *a, size_t *n) {
    uintptr_t pg = (uintptr_t)getpagesize(), s = (uintptr_t)addr, e = s + len;
    if (outward) { s &= ~(pg - 1); e = (e + pg - 1) & ~(pg - 1); }
    else         { s = (s + pg - 1) & ~(pg - 1); e &= ~(pg - 1); }
    if (e <= s) return 0;
    *a = s; *n = e - s;
    return 1;
}
int klb_mprotect(void *addr, size_t len, int prot);
int klb_madvise(void *a, size_t n, int advice);
static int klg_mprotect(void *addr, size_t len, int prot) {
    uintptr_t a; size_t n;
    if (!host_span(addr, len, prot != PROT_NONE, &a, &n)) return 0;
    return klb_mprotect((void *)a, n, prot);
}
static int klg_munmap(void *addr, size_t len) {
    uintptr_t a; size_t n;
    if ((uintptr_t)addr & ((uintptr_t)getpagesize() - 1)) {
        if (!host_span(addr, len, 0, &a, &n)) return 0;
        return munmap((void *)a, n);
    }
    return munmap(addr, len);                    // aligned start: Darwin rounds the length
}
static int klg_madvise(void *addr, size_t len, int advice) {
    uintptr_t a; size_t n;
    if (!host_span(addr, len, 0, &a, &n)) return 0;
    return klb_madvise((void *)a, n, advice);
}

// Plat_VirtualAlloc(addr, size, type, access, maxAddress) — tier0's, interposed
// on its importers. vscript asks it for LuaJIT's heap below 2 GB (a leftover of
// the x86-64 non-GC64 build), which tier0 serves by probing hints upward from
// 64 KB. On arm64 Darwin the first 4 GB is __PAGEZERO and an executable may not
// shrink it, so nothing below 4 GB can ever be mapped and the Lua VM is never
// created. LuaJIT on ARM64 is GC64-only and takes any 47-bit address, so the
// bound is dropped (once, by name) and the real allocator runs unbounded.
static void *klg_plat_virtualalloc(void *addr, size_t size, uint32_t type, uint32_t access,
                                   uintptr_t max) {
    static void *(*real)(void *, size_t, uint32_t, uint32_t, uintptr_t);
    if (!real) real = (void *(*)(void *, size_t, uint32_t, uint32_t, uintptr_t))
                      kl_guest_sym_global("Plat_VirtualAlloc");
    if (max && max <= 0x100000000ull) {
        static int said;
        if (!said++)
            fprintf(stderr, "  [glibc] Plat_VirtualAlloc below %#lx requested (%#zx bytes) — "
                            "nothing below 4 GB is mappable here; bound dropped\n",
                    (unsigned long)max, size);
        max = 0;
    }
    // ...and it commits that arena read-write-EXECUTE (access 7), because the
    // same allocator serves LuaJIT's machine code on x86-64. No guest may map
    // executable memory here (kl_libc.c refuses it), so the commit failed and
    // vscript retried with a fresh arena forever. The heap only needs RW; a
    // trace LuaJIT then fails to compile simply runs in the interpreter.
    if (access == 7) {
        static int said;
        if (!said++)
            fprintf(stderr, "  [glibc] Plat_VirtualAlloc: RWX commit requested — committing "
                            "RW (no executable memory for guests)\n");
        access = 3;
    }
    void *r = real ? real(addr, size, type, access, max) : NULL;
    if (kl_env_on("KL_TRACE_MMAP", 0)) {
        size_t o = 0;
        const char *img = kl_addr_image(__builtin_return_address(0), &o);
        fprintf(stderr, "  [glibc] Plat_VirtualAlloc(%p, %#zx, type %u, access %u) -> %p  [%s+%#zx]\n",
                addr, size, type, access, r, img ? img : "?", o);
    }
    return r;
}

// ---------- SysV semaphores ----------
// Adapted from Glovebox (MIT, github.com/glovebox-vr/glovebox)
// runtime/linux/kl_glibc.c (g_semget/g_semctl/g_semtimedop).
//
// tier0's CThreadSyncObject (and libvideo) build named semaphores on
// semget/semctl/semop. These used to forward to Darwin, with semctl translated
// command by command — glibc numbers GETPID 11 ... SETALL 17 where Darwin has
// 3 ... 9, and the fourth argument is VARIADIC (the guest passes it in x3,
// Darwin's semctl reads it from the stack, so Darwin's IPC_STAT once wrote a
// semid_ds through the guest's frame record). IPC_STAT itself could not be
// answered (the structs differ) and came back EINVAL. Forwarding is also wrong
// on the device: the visionOS sandbox does not grant SysV IPC at all.
//
// So the glibc personality gets an in-process implementation with Linux
// semantics, layouts and command numbers. Android guests are unaffected: their
// semget/semctl/semop still go through kl_libc_table.h. Within one process
// "system-wide" and "process-wide" are the same thing, which is all a guest
// that never forks can observe. SEM_UNDO is accepted and ignored (it only acts
// at process exit).
#define KLG_IPC_CREAT   01000
#define KLG_IPC_EXCL    02000
#define KLG_IPC_NOWAIT  04000
#define KLG_SEMVMX      32767
#define KLG_SEMMSL      64
#define KLG_SEMMNI      256
typedef struct {
    int used, key, nsems, mode;
    unsigned gen;                         // bumps on IPC_RMID: wakes waiters with EIDRM
    long otime, ctime;
    unsigned short vals[KLG_SEMMSL];
    int pids[KLG_SEMMSL];
    unsigned short ncnt[KLG_SEMMSL], zcnt[KLG_SEMMSL];
} klg_semset;
static klg_semset g_sems[KLG_SEMMNI];
static pthread_mutex_t g_sem_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t  g_sem_cond = PTHREAD_COND_INITIALIZER;

static klg_semset *klg_sem_get(int id) {
    return (id >= 0 && id < KLG_SEMMNI && g_sems[id].used) ? &g_sems[id] : NULL;
}

static int klg_semget(int key, int nsems, int flags) {
    if (nsems < 0 || nsems > KLG_SEMMSL) { errno = EINVAL; return -1; }
    pthread_mutex_lock(&g_sem_lock);
    int id = -1;
    for (int i = 0; key != 0 && i < KLG_SEMMNI; i++)        // key 0 = IPC_PRIVATE
        if (g_sems[i].used && g_sems[i].key == key) { id = i; break; }
    if (id >= 0) {
        int e = 0;
        if ((flags & KLG_IPC_CREAT) && (flags & KLG_IPC_EXCL)) e = EEXIST;
        else if (nsems > g_sems[id].nsems) e = EINVAL;
        pthread_mutex_unlock(&g_sem_lock);
        if (e) { errno = e; return -1; }
        return id;
    }
    if (key != 0 && !(flags & KLG_IPC_CREAT)) { pthread_mutex_unlock(&g_sem_lock); errno = ENOENT; return -1; }
    if (nsems == 0) { pthread_mutex_unlock(&g_sem_lock); errno = EINVAL; return -1; }
    for (int i = 0; i < KLG_SEMMNI; i++) if (!g_sems[i].used) { id = i; break; }
    if (id < 0) { pthread_mutex_unlock(&g_sem_lock); errno = ENOSPC; return -1; }
    unsigned gen = g_sems[id].gen;
    memset(&g_sems[id], 0, sizeof g_sems[id]);
    g_sems[id].used = 1; g_sems[id].key = key; g_sems[id].nsems = nsems;
    g_sems[id].mode = flags & 0777; g_sems[id].gen = gen + 1;
    g_sems[id].ctime = (long)time(NULL);
    pthread_mutex_unlock(&g_sem_lock);
    return id;
}

// glibc/aarch64 struct semid_ds (asm-generic semid64_ds): ipc_perm is 48 bytes,
// then otime, ctime, nsems and two reserved words — 88 in all.
typedef struct {
    int32_t key; uint32_t uid, gid, cuid, cgid, mode;
    uint16_t seq, pad2; uint64_t res1, res2;
    int64_t otime, ctime; uint64_t nsems, res3, res4;
} klg_semid_ds;
_Static_assert(sizeof(klg_semid_ds) == 88, "glibc aarch64 struct semid_ds");

// arg is the union semun, which the guest passes by value in x3.
static int klg_semctl(int id, int num, int cmd, uintptr_t arg) {
    cmd &= ~0x100;                                   // IPC_64 means nothing here
    pthread_mutex_lock(&g_sem_lock);
    klg_semset *S = klg_sem_get(id);
    if (!S) { pthread_mutex_unlock(&g_sem_lock); errno = EINVAL; return -1; }
    int r = 0, e = 0;
    int in_range = num >= 0 && num < S->nsems;
    switch (cmd) {
    case 0:                                          // IPC_RMID
        S->used = 0; S->gen++;
        pthread_cond_broadcast(&g_sem_cond);
        break;
    case 1: {                                        // IPC_SET: mode only
        const klg_semid_ds *d = (const klg_semid_ds *)arg;
        if (!d) { e = EFAULT; break; }
        S->mode = (int)(d->mode & 0777); S->ctime = (long)time(NULL);
        break;
    }
    case 2: {                                        // IPC_STAT
        klg_semid_ds *d = (klg_semid_ds *)arg;
        if (!d) { e = EFAULT; break; }
        memset(d, 0, sizeof *d);
        d->key = S->key;
        d->uid = d->cuid = (uint32_t)getuid();
        d->gid = d->cgid = (uint32_t)getgid();
        d->mode = (uint32_t)S->mode;
        d->otime = S->otime; d->ctime = S->ctime;
        d->nsems = (uint64_t)S->nsems;
        break;
    }
    case 11: if (in_range) r = S->pids[num]; else e = EINVAL; break;   // GETPID
    case 12: if (in_range) r = S->vals[num]; else e = EINVAL; break;   // GETVAL
    case 13: {                                                         // GETALL
        unsigned short *a = (unsigned short *)arg;
        if (!a) { e = EFAULT; break; }
        memcpy(a, S->vals, (size_t)S->nsems * sizeof *a);
        break;
    }
    case 14: if (in_range) r = S->ncnt[num]; else e = EINVAL; break;   // GETNCNT
    case 15: if (in_range) r = S->zcnt[num]; else e = EINVAL; break;   // GETZCNT
    case 16: {                                                         // SETVAL
        int v = (int)(uint32_t)arg;                  // semun.val: the low word of x3
        if (!in_range) { e = EINVAL; break; }
        if (v < 0 || v > KLG_SEMVMX) { e = ERANGE; break; }
        S->vals[num] = (unsigned short)v; S->pids[num] = 0;
        S->ctime = (long)time(NULL);
        pthread_cond_broadcast(&g_sem_cond);
        break;
    }
    case 17: {                                                         // SETALL
        const unsigned short *a = (const unsigned short *)arg;
        if (!a) { e = EFAULT; break; }
        for (int i = 0; i < S->nsems; i++) if (a[i] > KLG_SEMVMX) e = ERANGE;
        if (e) break;
        memcpy(S->vals, a, (size_t)S->nsems * sizeof *a);
        memset(S->pids, 0, sizeof S->pids);
        S->ctime = (long)time(NULL);
        pthread_cond_broadcast(&g_sem_cond);
        break;
    }
    default: {
        // IPC_INFO / SEM_INFO / SEM_STAT: nothing in the corpus asks.
        static int said;
        if (!said++) fprintf(stderr, "  [glibc] semctl cmd %d not implemented -> EINVAL\n", cmd);
        e = EINVAL;
    }
    }
    pthread_mutex_unlock(&g_sem_lock);
    if (e) { errno = e; return -1; }
    return r;
}

// Linux struct sembuf: sem_num, sem_op, sem_flg — 6 bytes.
typedef struct { unsigned short num; short op; short flg; } klg_sembuf;

static int klg_semtimedop(int id, klg_sembuf *ops, size_t n, const struct timespec *to) {
    if (n == 0) { errno = EINVAL; return -1; }
    if (n > 500) { errno = E2BIG; return -1; }       // SEMOPM
    if (!ops) { errno = EFAULT; return -1; }
    struct timespec deadline;
    if (to) {
        if (to->tv_sec < 0 || to->tv_nsec < 0 || to->tv_nsec >= 1000000000L) { errno = EINVAL; return -1; }
        clock_gettime(CLOCK_REALTIME, &deadline);
        deadline.tv_sec += to->tv_sec; deadline.tv_nsec += to->tv_nsec;
        if (deadline.tv_nsec >= 1000000000L) { deadline.tv_sec++; deadline.tv_nsec -= 1000000000L; }
    }
    pthread_mutex_lock(&g_sem_lock);
    klg_semset *S = klg_sem_get(id);
    if (!S) { pthread_mutex_unlock(&g_sem_lock); errno = EINVAL; return -1; }
    unsigned gen = S->gen;
    for (size_t i = 0; i < n; i++)
        if (ops[i].num >= S->nsems) { pthread_mutex_unlock(&g_sem_lock); errno = EFBIG; return -1; }
    for (;;) {
        if (!S->used || S->gen != gen) { pthread_mutex_unlock(&g_sem_lock); errno = EIDRM; return -1; }
        // All or nothing, as Linux does. Applied to a scratch copy so an op
        // list naming the same semaphore twice is judged in order.
        unsigned short v[KLG_SEMMSL];
        memcpy(v, S->vals, sizeof v);
        size_t blk = n;                              // the op that would block
        int range = 0;
        for (size_t i = 0; i < n && blk == n; i++) {
            int cur = v[ops[i].num], op = ops[i].op;
            if (op < 0 && cur + op < 0) blk = i;
            else if (op == 0 && cur != 0) blk = i;
            else if (cur + op > KLG_SEMVMX) { range = 1; break; }
            else v[ops[i].num] = (unsigned short)(cur + op);
        }
        if (range) { pthread_mutex_unlock(&g_sem_lock); errno = ERANGE; return -1; }
        if (blk == n) {
            memcpy(S->vals, v, sizeof v);
            for (size_t i = 0; i < n; i++) S->pids[ops[i].num] = getpid();
            S->otime = (long)time(NULL);
            pthread_cond_broadcast(&g_sem_cond);
            pthread_mutex_unlock(&g_sem_lock);
            return 0;
        }
        if (ops[blk].flg & KLG_IPC_NOWAIT) { pthread_mutex_unlock(&g_sem_lock); errno = EAGAIN; return -1; }
        unsigned short *cnt = ops[blk].op ? &S->ncnt[ops[blk].num] : &S->zcnt[ops[blk].num];
        (*cnt)++;
        int w = to ? pthread_cond_timedwait(&g_sem_cond, &g_sem_lock, &deadline)
                   : pthread_cond_wait(&g_sem_cond, &g_sem_lock);
        if (S->gen == gen) (*cnt)--;                 // a removed set was zeroed on reuse
        if (w == ETIMEDOUT) {
            int gone = !S->used || S->gen != gen;
            pthread_mutex_unlock(&g_sem_lock);
            errno = gone ? EIDRM : EAGAIN;
            return -1;
        }
    }
}
static int klg_semop(int id, klg_sembuf *ops, size_t n) { return klg_semtimedop(id, ops, n, NULL); }

// ---------- the table ----------
enum { DIRECT = 0, ALIAS, STUB_M1, STUB_NULL, STUB_ERR, STUB_ZERO };
typedef struct { const char *name; const void *fn; int kind; } klg_entry;
#define D(n, f) { n, (const void *)(f), DIRECT }
#define A(n, a) { n, a, ALIAS }            // the bionic shim's answer for `a`
#define S(n, k) { n, NULL, k }

static const klg_entry g_glibc[] = {
    // internals
    D("__errno_location", klb_errno), D("__h_errno_location", klg___h_errno_location),
    D("__getauxval", klb_getauxval), D("getauxval", klb_getauxval),
    D("_dl_find_object", klg__dl_find_object),
    D("__libc_single_threaded", &klg_libc_single_threaded),
    D("__libc_start_main", klg___libc_start_main),
    D("__libc_stack_end", &klg_libc_stack_end),
    D("program_invocation_name", &klg_program_invocation_name),
    D("program_invocation_short_name", &klg_program_invocation_short_name),
    D("__progname", &klg_program_invocation_short_name),
    D("__progname_full", &klg_program_invocation_name),
    D("__assert_fail", klg___assert_fail),
    D("secure_getenv", klg_secure_getenv), D("__secure_getenv", klg_secure_getenv),
    D("__getdelim", klg___getdelim), D("__xpg_basename", klg___xpg_basename),
    D("__xpg_strerror_r", klg___xpg_strerror_r), D("strerror_l", klg_strerror_l),
    D("__sched_cpualloc", klg___sched_cpualloc), D("__sched_cpufree", klg___sched_cpufree),
    D("__fpending", klg___fpending), D("__sysconf", klg___sysconf),
    D("sysconf", klg_sysconf),
    D("readlink", klg_readlink),
    D("semget", klg_semget), D("semctl", klg_semctl),
    D("semop", klg_semop), D("semtimedop", klg_semtimedop),
    D("Plat_VirtualAlloc", klg_plat_virtualalloc),
    D("eventfd", klg_eventfd), D("eventfd_read", klg_eventfd_read),
    D("eventfd_write", klg_eventfd_write),
    D("read", klg_read), D("write", klg_write), D("close", klg_close),
    D("lstat", klg_lstat), D("lstat64", klg_lstat),
    D("dlmopen", klg_dlmopen),
    S("__uflow", STUB_M1), S("__overflow", STUB_M1),
    S("__res_ninit", STUB_M1), S("__res_nclose", STUB_ZERO), S("res_nquery", STUB_M1),
    S("dn_expand", STUB_M1),

    // fortify
    D("__printf_chk", klv___printf_chk), D("__fprintf_chk", klv___fprintf_chk),
    D("__asprintf_chk", klv___asprintf_chk), D("__dprintf_chk", klv___dprintf_chk),
    D("__syslog_chk", klv___syslog_chk),
    D("__vfprintf_chk", klg___vfprintf_chk), D("__vprintf_chk", klg___vprintf_chk),
    D("__vasprintf_chk", klg___vasprintf_chk),
    D("__explicit_bzero_chk", klg___explicit_bzero_chk), D("explicit_bzero", klg___explicit_bzero_chk),
    D("__fdelt_chk", klg___fdelt_chk), D("__realpath_chk", klg___realpath_chk),
    D("__mbstowcs_chk", klg___mbstowcs_chk),

    // setjmp: no frame of ours between the guest and the host (see kl_va_thunks.S)
    D("_setjmp", klg_setjmp), D("setjmp", klg_setjmp), D("__sigsetjmp", sigsetjmp),
    D("longjmp", siglongjmp), D("_longjmp", siglongjmp), D("siglongjmp", siglongjmp),
    D("__longjmp_chk", siglongjmp),

    // C23 / C99 scanf-strtol spellings
    D("__isoc23_strtol", strtol), D("__isoc23_strtoul", strtoul),
    D("__isoc23_strtoll", strtoll), D("__isoc23_strtoull", strtoull),
    D("__isoc23_strtoimax", strtoimax), D("__isoc23_strtoumax", strtoumax),
    D("__isoc23_strtoll_l", klg_strtoll_l), D("__isoc23_strtoull_l", klg_strtoull_l),
    D("__isoc23_wcstoll", wcstoll), D("__isoc23_wcstoull", wcstoull),
    D("__isoc23_wcstol", wcstol), D("__isoc23_wcstoul", wcstoul),
    A("__isoc23_sscanf", "sscanf"), A("__isoc99_sscanf", "sscanf"),
    A("__isoc23_fscanf", "fscanf"), A("__isoc99_fscanf", "fscanf"),
    A("__isoc23_vsscanf", "vsscanf"), A("__isoc99_vsscanf", "vsscanf"),
    D("__isoc23_vfscanf", klg_vfscanf), D("__isoc99_vfscanf", klg_vfscanf),
    S("__isoc23_swscanf", STUB_M1), S("__isoc23_vswscanf", STUB_M1),

    // LFS: off_t is 64-bit everywhere here, so *64 is the plain name
    A("open64", "open"), A("fcntl64", "fcntl"),
    D("mmap", klg_mmap), D("mmap64", klg_mmap),
    D("mprotect", klg_mprotect), D("munmap", klg_munmap), D("madvise", klg_madvise),
    A("readdir64", "readdir"), A("scandir64", "scandir"), A("alphasort64", "alphasort"),
    A("statfs64", "statfs"), A("statvfs64", "statvfs"), A("fstatvfs64", "fstatvfs"),
    A("getrlimit64", "getrlimit"), A("setrlimit64", "setrlimit"),
    A("openat64", "openat"), A("freopen64", "freopen"), A("mkstemp64", "mkstemp"),
    A("sendfile64", "sendfile"), A("tmpfile64", "tmpfile"), D("creat", klg_creat), D("creat64", klg_creat),
    A("truncate64", "truncate"), A("lseek64", "lseek"),
    D("__xstat", klg___xstat), D("__xstat64", klg___xstat),
    D("__lxstat", klg___lxstat), D("__lxstat64", klg___lxstat),
    D("__fxstat", klg___fxstat), D("__fxstat64", klg___fxstat),
    D("fstatat", klg_fstatat), D("fstatat64", klg_fstatat), D("newfstatat", klg_fstatat),
    D("fstatfs", klg_fstatfs), D("fstatfs64", klg_fstatfs),
    D("posix_fadvise", klg_posix_fadvise), D("posix_fadvise64", klg_posix_fadvise),
    D("posix_fallocate", klg_posix_fallocate), D("posix_fallocate64", klg_posix_fallocate),
    D("faccessat", klg_faccessat), D("eaccess", klg_eaccess), D("euidaccess", klg_eaccess),
    D("get_current_dir_name", klg_get_current_dir_name),
    D("__open64_2", klg___open64_2), D("__openat_2", klg___openat_2),
    D("__openat64_2", klg___openat_2),
    S("__xmknod", STUB_M1), S("fallocate64", STUB_M1), S("fallocate", STUB_M1),
    S("mkostemp64", STUB_M1), S("mkostemps64", STUB_M1), S("nftw64", STUB_M1),
    S("statx", STUB_M1), S("mremap", STUB_NULL), S("close_range", STUB_M1),
    S("copy_file_range", STUB_M1), S("name_to_handle_at", STUB_M1), S("open_tree", STUB_M1),
    S("scandirat", STUB_M1), S("signalfd", STUB_M1), S("splice", STUB_M1),

    // ctype + locales
    D("__ctype_b_loc", klg___ctype_b_loc), D("__ctype_tolower_loc", klg___ctype_tolower_loc),
    D("__ctype_toupper_loc", klg___ctype_toupper_loc),
    D("newlocale", klg_newlocale), D("__newlocale", klg_newlocale),
    D("duplocale", klg_duplocale), D("__duplocale", klg_duplocale),
    D("freelocale", klg_freelocale), D("__freelocale", klg_freelocale),
    D("uselocale", klg_uselocale), D("__uselocale", klg_uselocale),
    D("setlocale", klg_setlocale),
    D("nl_langinfo", klg_nl_langinfo), D("nl_langinfo_l", klg_nl_langinfo_l),
    D("__nl_langinfo_l", klg_nl_langinfo_l),
    D("__strcoll_l", klg_strcoll_l), D("strcoll_l", klg_strcoll_l),
    D("__strxfrm_l", klg_strxfrm_l), D("strxfrm_l", klg_strxfrm_l),
    D("__wcscoll_l", klg_wcscoll_l), D("__wcsxfrm_l", klg_wcsxfrm_l),
    D("__towlower_l", klg_towlower_l), D("__towupper_l", klg_towupper_l),
    D("__wctype_l", klg_wctype_l), D("__iswctype_l", klg_iswctype_l),
    D("__strftime_l", klg_strftime_l), D("strftime_l", klg_strftime_l),
    D("__wcsftime_l", klg_wcsftime_l),
    D("__strtod_l", klg_strtod_l), D("__strtof_l", klg_strtof_l),
    D("strtod_l", klg_strtod_l), D("strtof_l", klg_strtof_l),
    A("__strtold_l", "strtold"), A("strtold_l", "strtold"),
    D("strtol_l", klg_strtol_l), D("__strtol_l", klg_strtol_l),
    D("strtoul_l", klg_strtoul_l), D("__strtoul_l", klg_strtoul_l),
    D("strtoll_l", klg_strtoll_l), D("__strtoll_l", klg_strtoll_l),
    D("strtoull_l", klg_strtoull_l), D("__strtoull_l", klg_strtoull_l),
    D("isalnum_l", klg_isalnum_l), D("isalpha_l", klg_isalpha_l), D("isblank_l", klg_isblank_l),
    D("iscntrl_l", klg_iscntrl_l), D("isdigit_l", klg_isdigit_l), D("isgraph_l", klg_isgraph_l),
    D("islower_l", klg_islower_l), D("isprint_l", klg_isprint_l), D("ispunct_l", klg_ispunct_l),
    D("isspace_l", klg_isspace_l), D("isupper_l", klg_isupper_l), D("isxdigit_l", klg_isxdigit_l),
    D("tolower_l", klg_tolower_l), D("toupper_l", klg_toupper_l),
    D("__tolower_l", klg_tolower_l), D("__toupper_l", klg_toupper_l),
    D("towlower_l", klg_towlower_l), D("towupper_l", klg_towupper_l),
    D("wcscoll_l", klg_wcscoll_l), D("wcsxfrm_l", klg_wcsxfrm_l),
    D("iswctype_l", klg_iswctype_l), D("wctype_l", klg_wctype_l),
    D("wcsftime_l", klg_wcsftime_l),
    D("strcasecmp_l", klg_strcasecmp_l), D("strncasecmp_l", klg_strncasecmp_l),
    D("gettext", klg_gettext), D("dgettext", klg_dgettext), D("dcgettext", klg_dcgettext),
    D("dcngettext", klg_dcngettext), D("textdomain", klg_textdomain),
    D("bindtextdomain", klg_bindtextdomain),
    D("bind_textdomain_codeset", klg_bind_textdomain_codeset),
    S("iconv_open", STUB_M1), S("iconv", STUB_M1), S("iconv_close", STUB_M1),
    S("catopen", STUB_M1), S("catgets", STUB_NULL), S("catclose", STUB_M1),
    D("wcsstr", wcsstr), D("wcswidth", wcswidth), D("wcwidth", wcwidth), D("wctomb", wctomb),
    D("wcscasecmp", wcscasecmp), D("wcsncasecmp", wcsncasecmp), D("wcsdup", wcsdup),
    D("wcslcat", wcslcat), D("wcslcpy", wcslcpy),

    // signals
    D("sigemptyset", klg_sigemptyset), D("sigfillset", klg_sigfillset),
    D("sigaddset", klg_sigaddset), D("sigdelset", klg_sigdelset),
    D("sigismember", klg_sigismember), D("sigisemptyset", klg_sigisemptyset),
    D("sigaction", klg_sigaction), D("__sigaction", klg_sigaction),
    D("sigprocmask", klg_sigprocmask), D("pthread_sigmask", klg_pthread_sigmask),
    S("sigtimedwait", STUB_M1),

    // pthread / sched
    D("sched_getcpu", klg_sched_getcpu),
    D("pthread_getaffinity_np", klg_pthread_getaffinity_np),
    S("pthread_setaffinity_np", STUB_ZERO), S("pthread_attr_setinheritsched", STUB_ZERO),
    S("pthread_setcanceltype", STUB_ZERO), S("pthread_setcancelstate", STUB_ZERO),
    S("pthread_cancel", STUB_ERR),
    D("pthread_getname_np", klg_pthread_getname_np),
    S("sched_getparam", STUB_ZERO), S("sched_getscheduler", STUB_ZERO),
    S("sched_setscheduler", STUB_ZERO),

    // stdio / string / stdlib
    D("fgets_unlocked", klg_fgets_unlocked), D("fileno_unlocked", klg_fileno_unlocked),
    D("__fsetlocking", klg___fsetlocking), S("tmpnam", STUB_NULL), D("ctermid", ctermid),
    D("lroundf", lroundf), D("lround", lround), D("floor", floor),
    D("nextafterf", nextafterf), D("cabsf", cabsf), D("cexpf", cexpf),
    D("fegetround", fegetround), D("fesetround", fesetround),
    D("bcmp", klg_bcmp), D("qsort_r", klg_qsort_r), D("malloc_stats", klg_malloc_stats),
    D("memmem", memmem), D("putenv", putenv), D("strverscmp", klg_strverscmp),
    D("versionsort", klg_versionsort), D("__mbrlen", klg___mbrlen),
    D("mkostemp", mkostemp), S("random_r", STUB_M1), S("initstate_r", STUB_M1),
    D("dirfd", dirfd), D("ttyname", ttyname),

    // time
    D("asctime", asctime), D("asctime_r", asctime_r),
    D("daylight", &daylight), D("timezone", &timezone), D("__timezone", &timezone),
    D("in6addr_loopback", &in6addr_loopback),

    // process / system
    D("_Exit", klb__exit), D("getdtablesize", getdtablesize), D("getloadavg", getloadavg),
    D("backtrace", backtrace), D("backtrace_symbols", backtrace_symbols),
    D("getresuid", klg_getresuid), D("getresgid", klg_getresgid),
    D("get_nprocs", klg_get_nprocs), D("get_nprocs_conf", klg_get_nprocs),
    D("err", klv_g_err), D("errx", klv_g_errx), D("warn", klv_g_warn),
    D("futimes", futimes), D("lchmod", lchmod), D("setlogmask", setlogmask),
    S("execlp", STUB_M1), S("execvp", STUB_M1), S("execvpe", STUB_M1),
    S("getcontext", STUB_M1), S("setcontext", STUB_M1), S("makecontext", STUB_ZERO),
    S("swapcontext", STUB_M1),
    S("mount", STUB_M1), S("umount", STUB_M1), S("umount2", STUB_M1),
    S("mount_setattr", STUB_M1), S("move_mount", STUB_M1), S("fsconfig", STUB_M1),
    S("fsmount", STUB_M1), S("fsopen", STUB_M1), S("fspick", STUB_M1),
    S("capget", STUB_M1), S("capset", STUB_M1), S("setns", STUB_M1), S("unshare", STUB_M1),
    S("pidfd_send_signal", STUB_M1),
    S("posix_spawn", STUB_ERR), S("posix_spawnp", STUB_ERR),
    S("posix_spawn_file_actions_init", STUB_ZERO), S("posix_spawn_file_actions_destroy", STUB_ZERO),
    S("posix_spawn_file_actions_addclose", STUB_ZERO), S("posix_spawn_file_actions_adddup2", STUB_ZERO),
    S("posix_spawnattr_init", STUB_ZERO), S("posix_spawnattr_destroy", STUB_ZERO),
    S("posix_spawnattr_setflags", STUB_ZERO), S("posix_spawnattr_setsigdefault", STUB_ZERO),
    S("posix_madvise", STUB_ZERO),
    S("getxattr", STUB_M1), S("lgetxattr", STUB_M1), S("fgetxattr", STUB_M1),
    S("setxattr", STUB_M1), S("lsetxattr", STUB_M1), S("fsetxattr", STUB_M1),
    S("listxattr", STUB_M1), S("llistxattr", STUB_M1), S("flistxattr", STUB_M1),
    S("removexattr", STUB_M1), S("fremovexattr", STUB_M1),
    S("shmget", STUB_M1), S("shmat", STUB_M1), S("shmdt", STUB_M1), S("shmctl", STUB_M1),
    S("setmntent", STUB_NULL), S("getmntent_r", STUB_NULL), S("endmntent", STUB_ZERO),
    S("hasmntopt", STUB_NULL), S("getttynam", STUB_NULL), S("endservent", STUB_ZERO),
    S("getservbyname_r", STUB_ERR), S("recvmmsg", STUB_M1), S("sendmmsg", STUB_M1),
    S("fts64_open", STUB_NULL), S("fts64_read", STUB_NULL), S("fts64_close", STUB_M1),
    S("fts64_set", STUB_M1),
};

void *kl_glibc_lookup(const char *name) {
    // SDL's video half first (kl_glibc_sdl.c): Panorama imports some of it
    // directly, and those imports must land on the same seam the engine's
    // dlsym table does.
    void *sdl = kl_glibc_sdl_lookup(name);
    if (sdl) return sdl;
    // ...and libsteam_api's, for a Steam that is not running (kl_steam.c).
    void *steam = kl_steam_lookup(name);
    if (steam) return steam;
    // ...and libopenvr_api's, for a SteamVR that is not there (kl_openvr.c).
    void *ovr = kl_openvr_lookup(name);
    if (ovr) return ovr;
    for (size_t i = 0; i < sizeof g_glibc / sizeof *g_glibc; i++) {
        const klg_entry *e = &g_glibc[i];
        if (strcmp(e->name, name)) continue;
        switch (e->kind) {
        case DIRECT:    return (void *)e->fn;
        case ALIAS:     return kl_shim_lookup_base((const char *)e->fn);
        case STUB_M1:   return kl_named_stub(e->name, (void *)st_m1);
        case STUB_NULL: return kl_named_stub(e->name, (void *)st_null);
        case STUB_ERR:  return kl_named_stub(e->name, (void *)st_err);
        default:        return kl_named_stub(e->name, (void *)st_zero);
        }
    }
    return NULL;
}
