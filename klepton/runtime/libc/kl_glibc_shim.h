// The glibc ABI tier (kl_glibc_shim.c): answers for names whose glibc meaning
// differs from bionic's, or that only glibc has. Consulted ahead of
// kl_shim_lookup, and only once the glibc door installs it.
#ifndef KL_GLIBC_SHIM_H
#define KL_GLIBC_SHIM_H
void *kl_glibc_lookup(const char *name);
// What readlink("/proc/self/exe") answers: the entry executable, absolute.
void  kl_glibc_set_exe_path(const char *path);
#endif
