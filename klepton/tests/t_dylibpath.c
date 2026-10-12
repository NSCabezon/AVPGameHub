// Where a guest library's translation is looked up (kl_image.c dylib_candidate),
// against a fake Frameworks/ laid out the way an app bundle is: every game's
// translations flat, as <game>__<lib>.framework/<game>__<lib>, beside ANGLE's
// unprefixed libGLESv2.framework. Only existence is asked (kl_can_load), so the
// files are empty.
//
// What must hold:
//   - with KL_DYLIB_PREFIX the guest's own name ("libunity.so", any directory)
//     finds THIS game's framework and never another game's;
//   - with a prefix set, an unprefixed framework of the same name is NOT an
//     answer (ANGLE's libGLESv2, a stale pre-flat translation);
//   - the '+' -> 'x' file-name map still applies after the prefix
//     (libc++_shared -> <game>__libcxx_shared);
//   - with no prefix the host layout (<dir>/<lib>.dylib) is unchanged.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/stat.h>
#include "../runtime/klepton.h"

static int fails;
static void expect(const char *what, int got, int want) {
    printf("  %-4s %s\n", got == want ? "ok" : "FAIL", what);
    if (got != want) fails++;
}

static void touch_fw(const char *root, const char *name) {
    char p[1024];
    snprintf(p, sizeof p, "%s/%s.framework", root, name);
    mkdir(p, 0755);
    snprintf(p, sizeof p, "%s/%s.framework/%s", root, name, name);
    FILE *f = fopen(p, "w");
    if (f) fclose(f);
}

int main(void) {
    char root[] = "/tmp/kl_dylibpath.XXXXXX";
    if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }
    touch_fw(root, "beatsaber__libunity");
    touch_fw(root, "beatsaber__libmain");
    touch_fw(root, "superhot__libunity");
    touch_fw(root, "superhot__libphonon");
    touch_fw(root, "batman__libcxx_shared");
    touch_fw(root, "libGLESv2");               // ANGLE: shared, unprefixed
    char p[1024];
    snprintf(p, sizeof p, "%s/libhost.dylib", root);
    FILE *f = fopen(p, "w"); if (f) fclose(f);

    printf("=== translated-library lookup (flat Frameworks/, per-game prefix) ===\n");
    setenv("KL_DYLIB_DIR", root, 1);

    setenv("KL_DYLIB_PREFIX", "beatsaber__", 1);
    expect("beatsaber: libunity.so -> beatsaber__libunity",
           kl_can_load("/nowhere/lib/arm64-v8a/libunity.so"), 1);
    expect("beatsaber: libmain.so found", kl_can_load("libmain.so"), 1);
    expect("beatsaber: superhot's libphonon is not an answer",
           kl_can_load("/nowhere/libphonon.so"), 0);
    expect("beatsaber: unprefixed libGLESv2 (ANGLE) is not an answer",
           kl_can_load("/nowhere/libGLESv2.so"), 0);
    expect("beatsaber: kl_dylib_prefix() reports it",
           strcmp(kl_dylib_prefix(), "beatsaber__") == 0, 1);

    setenv("KL_DYLIB_PREFIX", "superhot__", 1);
    expect("superhot: libunity.so -> superhot__libunity", kl_can_load("libunity.so"), 1);
    expect("superhot: libmain.so is beatsaber's, not found", kl_can_load("libmain.so"), 0);

    setenv("KL_DYLIB_PREFIX", "batman__", 1);
    expect("batman: libc++_shared.so -> batman__libcxx_shared",
           kl_can_load("/x/libc++_shared.so"), 1);

    unsetenv("KL_DYLIB_PREFIX");
    expect("no prefix: host <dir>/libhost.dylib", kl_can_load("/x/libhost.so"), 1);
    expect("no prefix: prefixed frameworks are not bare names", kl_can_load("libunity.so"), 0);
    expect("no prefix: kl_dylib_prefix() is \"\"", kl_dylib_prefix()[0] == 0, 1);

    char cmd[1100];
    snprintf(cmd, sizeof cmd, "rm -rf '%s'", root);
    if (system(cmd) != 0) fprintf(stderr, "  (could not remove %s)\n", root);
    printf("%s: %d failed\n", fails ? "FAIL" : "PASS", fails);
    return fails ? 1 : 0;
}
