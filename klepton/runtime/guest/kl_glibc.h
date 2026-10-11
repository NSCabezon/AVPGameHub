#ifndef KL_GLIBC_H
#define KL_GLIBC_H
#include <stdio.h>
#include <stddef.h>

// A Linux (glibc) AArch64 guest — the first one is Half-Life: Alyx's
// linuxsteamrtarm64 build. Not an APK: no Java, no NativeActivity, no bionic.
// The entry is an ELF EXECUTABLE (a PIE, so an ET_DYN like any library), and
// its libraries come from two places — the game's own tree and a Steam Runtime
// sysroot — under versioned glibc sonames (libc.so.6, libstdc++.so.6,
// libavutil.so.56 for a file called libavutil.so.56.51.100).
//
// What this door does today (phase A): build a soname index over the search
// path, map and relocate the entry's DT_NEEDED closure plus every module the
// engine would dlopen from the game tree, and report what is left unresolved,
// grouped. Nothing is RUN — no DT_INIT_ARRAY, no _start — so the census is
// complete rather than stopping at the first unimplemented call.
//
// Where the files are:
//   KL_GLIBC_MODDIRS   colon-separated game directories; every library in them
//                      is a root (the engine dlopens them by name). Default for
//                      `alyx`: the target libdir and ../../hlvr/bin/<same arch>.
//   KL_GLIBC_SYSROOT   colon-separated runtime directories, searched for
//                      DT_NEEDED only. Default for `alyx`: the SteamRT4 arm64
//                      lib dir beside the game, ../../../../steamrt4-arm64/
//                      files/lib/aarch64-linux-gnu from the libdir.
//   KL_GLIBC_SKIP      extra soname prefixes never to load (comma-separated).
//   KL_GLIBC_ROOTS     "entry" maps only the executable's own closure.
//   KL_GAP_OUT         where the full gap list goes (default
//                      build/<target>_gap.txt).
int         kl_glibc_configure(const char *target, const char *libdir,
                               const char *entry, FILE *out);
const char *kl_glibc_error(void);
// run 0: map + relocate the whole tree, run nothing (the gap census).
// run 1: the entry's closure only, constructors run in dependency order.
int         kl_glibc_load(FILE *out, int run);
unsigned    kl_glibc_gap(FILE *out);     // grouped unresolved imports + file
int         kl_glibc_begin(FILE *out);   // _start on a new thread (main via __libc_start_main)
double      kl_glibc_pump(double seconds, const volatile int *quit);
void        kl_glibc_report(FILE *out);
// The interposer that puts --jitless (KL_V8_FLAGS) in front of V8's flags.
void        klg_v8_set_flags(const char *flags, size_t len);
#endif
