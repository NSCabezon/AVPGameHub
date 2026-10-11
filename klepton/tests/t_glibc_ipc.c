// The glibc personality's SysV semaphores and signal masks. `make glibcipc`,
// in `make check`.
//
// Both are reachable only from a glibc guest (Alyx's tier0 and libvideo for
// the semaphores; Source 2 / SDL / V8 worker threads for the masks), so this
// drives them through kl_glibc_lookup — the same entry points the guest binds —
// with Linux numbering, Linux layouts and Linux argument passing.
//
//   1. semget/semctl/semop/semtimedop are served IN-PROCESS (the visionOS
//      sandbox grants no SysV IPC), with glibc command numbers: SETVAL/GETVAL,
//      SETALL/GETALL, GETPID, IPC_STAT filling the 88-byte Linux semid_ds (it
//      used to answer EINVAL), IPC_CREAT|IPC_EXCL, IPC_NOWAIT, a timed wait
//      that times out, a blocked semop woken by another thread, IPC_RMID.
//   2. pthread_sigmask / sigprocmask with a FULL set keep the synchronous fault
//      signals deliverable, and a thread that blocked "everything" and then
//      faults reaches its SIGSEGV handler instead of the process dying
//      silently. The control is the same thread with Darwin's own
//      pthread_sigmask: its handler must never run.
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#include "../runtime/libc/kl_glibc_shim.h"

static int g_fail;
static void ck(int ok, const char *what) {
    if (!ok) g_fail++;
    printf("  %-4s %s\n", ok ? "ok" : "FAIL", what);
}

// Linux values the guest passes.
#define L_IPC_PRIVATE 0
#define L_IPC_CREAT   01000
#define L_IPC_EXCL    02000
#define L_IPC_NOWAIT  04000
#define L_IPC_RMID    0
#define L_IPC_STAT    2
#define L_GETPID      11
#define L_GETVAL      12
#define L_GETALL      13
#define L_GETNCNT     14
#define L_SETVAL      16
#define L_SETALL      17
#define L_SIG_SETMASK 2

typedef struct { unsigned short num; short op; short flg; } l_sembuf;
typedef struct {
    int32_t key; uint32_t uid, gid, cuid, cgid, mode;
    uint16_t seq, pad2; uint64_t res1, res2;
    int64_t otime, ctime; uint64_t nsems, res3, res4;
} l_semid_ds;

static int (*p_semget)(int, int, int);
static int (*p_semctl)(int, int, int, uintptr_t);   // union semun by value, in x3
static int (*p_semop)(int, l_sembuf *, size_t);
static int (*p_semtimedop)(int, l_sembuf *, size_t, const struct timespec *);
static int (*p_sigmask)(int, const uint64_t *, uint64_t *);
static int (*p_sigprocmask)(int, const uint64_t *, uint64_t *);

static int g_semid;
static void *poster(void *a) {
    usleep(50 * 1000);
    l_sembuf op = {1, 2, 0};
    p_semop(g_semid, &op, 1);
    return a;
}

static void sems(void) {
    printf("=== SysV semaphores (glibc personality, in-process) ===\n");
    const int key = 0x4B4C5345;   // "KLSE"
    int id = p_semget(key, 3, L_IPC_CREAT | L_IPC_EXCL | 0600);
    ck(id >= 0, "semget(IPC_CREAT|IPC_EXCL) creates a set");
    errno = 0;
    ck(p_semget(key, 3, L_IPC_CREAT | L_IPC_EXCL | 0600) == -1 && errno == EEXIST,
       "...a second IPC_EXCL create is EEXIST");
    ck(p_semget(key, 2, 0) == id, "...and a plain semget finds the same id");
    errno = 0;
    ck(p_semget(0x4B4C0000, 1, 0) == -1 && errno == ENOENT, "an unknown key without IPC_CREAT is ENOENT");
    int priv = p_semget(L_IPC_PRIVATE, 1, 0600);
    ck(priv >= 0 && priv != id, "IPC_PRIVATE always makes a new set");

    l_semid_ds ds;
    memset(&ds, 0xAB, sizeof ds);
    int r = p_semctl(id, 0, L_IPC_STAT, (uintptr_t)&ds);
    ck(r == 0, "semctl(IPC_STAT) succeeds (it used to be EINVAL)");
    ck(ds.key == key && ds.nsems == 3 && (ds.mode & 0777) == 0600 && ds.res3 == 0,
       "...and fills the Linux 88-byte semid_ds: key, nsems, mode");

    ck(p_semctl(id, 1, L_SETVAL, 5) == 0 && p_semctl(id, 1, L_GETVAL, 0) == 5,
       "SETVAL 5 / GETVAL reads 5 (glibc command numbers)");
    unsigned short all[3] = {1, 2, 3}, back[3] = {0};
    ck(p_semctl(id, 0, L_SETALL, (uintptr_t)all) == 0 &&
       p_semctl(id, 0, L_GETALL, (uintptr_t)back) == 0 &&
       back[0] == 1 && back[1] == 2 && back[2] == 3, "SETALL / GETALL round-trip");

    l_sembuf dec = {0, -1, 0};
    ck(p_semop(id, &dec, 1) == 0 && p_semctl(id, 0, L_GETVAL, 0) == 0, "semop -1 takes the count to 0");
    ck(p_semctl(id, 0, L_GETPID, 0) == getpid(), "GETPID names the last operator");
    l_sembuf nw = {0, -1, L_IPC_NOWAIT};
    errno = 0;
    ck(p_semop(id, &nw, 1) == -1 && errno == EAGAIN, "IPC_NOWAIT on a zero semaphore is EAGAIN");
    struct timespec to = {0, 30 * 1000 * 1000};
    errno = 0;
    ck(p_semtimedop(id, &nw, 1, &to) == -1 && errno == EAGAIN, "semtimedop times out with EAGAIN");
    // All or nothing: the second op cannot proceed, so the first must not apply.
    l_sembuf pair[2] = {{2, -1, 0}, {0, -1, L_IPC_NOWAIT}};
    p_semop(id, pair, 2);
    ck(p_semctl(id, 2, L_GETVAL, 0) == 3, "a multi-op semop is all-or-nothing");

    // A blocked wait, released from another thread (sem 1 is 2 after SETALL).
    l_sembuf take3 = {1, -3, 0};
    g_semid = id;
    pthread_t t;
    pthread_create(&t, NULL, poster, NULL);
    struct timespec two = {2, 0};
    r = p_semtimedop(id, &take3, 1, &two);
    pthread_join(t, NULL);
    ck(r == 0 && p_semctl(id, 1, L_GETVAL, 0) == 1, "a blocked semop wakes when another thread posts");
    ck(p_semctl(id, 1, L_GETNCNT, 0) == 0, "GETNCNT is back to 0 after the waiter left");

    ck(p_semctl(id, 0, L_IPC_RMID, 0) == 0, "IPC_RMID");
    errno = 0;
    ck(p_semctl(id, 0, L_GETVAL, 0) == -1 && errno == EINVAL, "...the id is gone afterwards (EINVAL)");
    p_semctl(priv, 0, L_IPC_RMID, 0);
}

// ---- signal masks ----
static void on_segv(int s) { (void)s; _exit(42); }

// Child: block every signal the way an engine worker does, then fault.
// Returns the child's wait status.
static int fault_with_all_blocked(int use_shim) {
    pid_t pid = fork();
    if (pid == 0) {
        signal(SIGSEGV, on_segv);
        signal(SIGBUS, on_segv);
        uint64_t all[16];
        memset(all, 0xff, sizeof all);
        if (use_shim) p_sigmask(L_SIG_SETMASK, all, NULL);
        else { sigset_t s; sigfillset(&s); pthread_sigmask(SIG_SETMASK, &s, NULL); }
        *(volatile int *)(uintptr_t)8 = 1;   // the fault
        _exit(0);
    }
    // Darwin does not always kill a thread whose fault signal is blocked: the
    // control has been seen to re-fault forever at 100% CPU instead. Either
    // way the handler never runs, so give it 3 s and then end it.
    int st = 0;
    for (int i = 0; i < 300; i++) {
        if (waitpid(pid, &st, WNOHANG) == pid) return st;
        usleep(10 * 1000);
    }
    kill(pid, SIGKILL);
    waitpid(pid, &st, 0);
    return st;
}

static void masks(void) {
    printf("=== signal masks (glibc personality) ===\n");
    uint64_t all[16], old[16];
    memset(all, 0xff, sizeof all);
    sigset_t saved;
    pthread_sigmask(SIG_SETMASK, NULL, &saved);

    ck(p_sigmask(L_SIG_SETMASK, all, NULL) == 0, "pthread_sigmask(SIG_SETMASK, full set)");
    sigset_t cur;
    pthread_sigmask(SIG_SETMASK, NULL, &cur);
    ck(!sigismember(&cur, SIGSEGV) && !sigismember(&cur, SIGBUS) && !sigismember(&cur, SIGILL) &&
       !sigismember(&cur, SIGFPE) && !sigismember(&cur, SIGTRAP) && !sigismember(&cur, SIGABRT),
       "...leaves SIGSEGV/SIGBUS/SIGILL/SIGFPE/SIGTRAP/SIGABRT unblocked");
    ck(sigismember(&cur, SIGINT) && sigismember(&cur, SIGTERM), "...while the rest of the set is blocked");
    memset(old, 0, sizeof old);
    ck(p_sigmask(L_SIG_SETMASK, all, old) == 0 && !((old[0] >> (SIGSEGV - 1)) & 1) &&
       ((old[0] >> (SIGINT - 1)) & 1), "the old mask handed back is the one in force");
    pthread_sigmask(SIG_SETMASK, &saved, NULL);

    ck(p_sigprocmask(L_SIG_SETMASK, all, NULL) == 0, "sigprocmask(SIG_SETMASK, full set)");
    pthread_sigmask(SIG_SETMASK, NULL, &cur);
    ck(!sigismember(&cur, SIGSEGV) && sigismember(&cur, SIGINT), "...gets the same treatment");
    pthread_sigmask(SIG_SETMASK, &saved, NULL);

    int ctl = fault_with_all_blocked(0);
    ck(!(WIFEXITED(ctl) && WEXITSTATUS(ctl) == 42),
       "control: Darwin's own full mask, then a fault -> the handler never runs (dies or spins)");
    int st = fault_with_all_blocked(1);
    ck(WIFEXITED(st) && WEXITSTATUS(st) == 42,
       "through the shim: the same fault reaches the SIGSEGV handler");
}

int main(void) {
    setvbuf(stdout, NULL, _IONBF, 0);
    p_semget      = (int (*)(int, int, int))kl_glibc_lookup("semget");
    p_semctl      = (int (*)(int, int, int, uintptr_t))kl_glibc_lookup("semctl");
    p_semop       = (int (*)(int, l_sembuf *, size_t))kl_glibc_lookup("semop");
    p_semtimedop  = (int (*)(int, l_sembuf *, size_t, const struct timespec *))kl_glibc_lookup("semtimedop");
    p_sigmask     = (int (*)(int, const uint64_t *, uint64_t *))kl_glibc_lookup("pthread_sigmask");
    p_sigprocmask = (int (*)(int, const uint64_t *, uint64_t *))kl_glibc_lookup("sigprocmask");
    if (!p_semget || !p_semctl || !p_semop || !p_semtimedop || !p_sigmask || !p_sigprocmask) {
        printf("FAIL: the glibc table does not serve semget/semctl/semop/semtimedop/"
               "pthread_sigmask/sigprocmask\n");
        return 1;
    }
    sems();
    masks();
    printf(g_fail ? "FAIL: %d check(s)\n" : "PASS: glibc SysV semaphores and fault-signal masks\n", g_fail);
    return g_fail ? 1 : 0;
}
