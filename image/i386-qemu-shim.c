/* SPDX-License-Identifier: MIT
 * SPDX-FileCopyrightText: 2026 Kevin T. Coughlin
 *
 * i386-qemu-shim.c — LD_PRELOAD shim for Valve's 32-bit Steam libraries
 * (steamclient.so, SteamCMD) running under qemu-i386 user-mode emulation on
 * non-x86 hosts (Apple silicon). Built and preloaded only by run-i386 and the
 * named launchers from i386-compat.sh; x86 images never contain it.
 *
 * It papers over two places where qemu-user differs from a real x86 kernel:
 *
 *  1. Robust futex lists. qemu-user does not implement set_robust_list /
 *     get_robust_list (ENOSYS), and steamclient.so aborts with
 *     "futex robust_list not initialized by pthreads" when its sanity check
 *     can't read one back. syscall(SYS_get_robust_list) is answered with a
 *     per-thread list head (an empty list, or the one the thread registered
 *     through syscall(SYS_set_robust_list)) shaped like glibc's own, with
 *     the same futex_offset. Nothing in the kernel walks it under emulation,
 *     so this only satisfies the check.
 *
 *  2. /proc/cpuinfo. Under qemu-user it still describes the host ARM CPU and
 *     SteamCMD exits(1) when it finds no x86 "flags" line. Opens of
 *     /proc/cpuinfo are redirected to $I386_FAKE_CPUINFO when that is set.
 *
 * Once loaded it removes itself from LD_PRELOAD, so the native (arm64)
 * programs the i386 process starts (/bin/sh, curl, ...) don't inherit a
 * 32-bit x86 preload and make ld.so print "wrong ELF class: ELFCLASS32" on
 * every exec. i386 children started through run-i386 or a launcher get it
 * again from there. Set I386_SHIM_INHERIT=1 to leave LD_PRELOAD alone (for
 * setups where a binfmt_misc handler runs i386 children directly).
 */
#define _GNU_SOURCE
#include <dlfcn.h>
#include <pthread.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>

/* i386 syscall numbers (fixed ABI) */
#ifndef SYS_set_robust_list
#define SYS_set_robust_list 311
#endif
#ifndef SYS_get_robust_list
#define SYS_get_robust_list 312
#endif

struct robust_list {
    struct robust_list *next;
};

struct robust_list_head {
    struct robust_list list;
    long futex_offset;
    struct robust_list *list_op_pending;
};

static __thread struct robust_list_head empty_head;
static __thread void *registered_head;
static __thread size_t registered_len;

#define REAL(name) static __typeof__(name) *real_##name; \
    if (real_##name == NULL) real_##name = (__typeof__(name) *)dlsym(RTLD_NEXT, #name)

__attribute__((constructor)) static void drop_from_preload(void)
{
    const char *cur = getenv("LD_PRELOAD");
    const char *inherit = getenv("I386_SHIM_INHERIT");
    const char *p;
    char *out, *o;
    size_t self_len;
    Dl_info self;

    if (cur == NULL)
        return;
    if (inherit != NULL && *inherit != '\0' && strcmp(inherit, "0") != 0)
        return;
    /* dli_fname is this library's name as ld.so loaded it, i.e. exactly its
     * LD_PRELOAD entry. Other entries (the caller's) are kept. */
    if (dladdr((void *)drop_from_preload, &self) == 0 || self.dli_fname == NULL)
        return;
    self_len = strlen(self.dli_fname);
    out = malloc(strlen(cur) + 1);
    if (out == NULL)
        return;
    o = out;
    for (p = cur; *p != '\0';) {
        size_t n = strcspn(p, ": "); /* ld.so splits on both */

        if (n > 0 && !(n == self_len && strncmp(p, self.dli_fname, n) == 0)) {
            if (o != out)
                *o++ = ':';
            memcpy(o, p, n);
            o += n;
        }
        p += n;
        if (*p != '\0')
            p++;
    }
    *o = '\0';
    if (o == out)
        unsetenv("LD_PRELOAD");
    else
        setenv("LD_PRELOAD", out, 1);
    free(out);
}

long syscall(long number, ...)
{
    va_list ap;
    long a[6];
    int i;
    REAL(syscall);

    va_start(ap, number);
    for (i = 0; i < 6; i++)
        a[i] = va_arg(ap, long);
    va_end(ap);

    if (number == SYS_set_robust_list) {
        registered_head = (void *)a[0];
        registered_len = (size_t)a[1];
        return 0;
    }
    if (number == SYS_get_robust_list) {
        void **head_ptr = (void **)a[1];
        size_t *len_ptr = (size_t *)a[2];

        if (head_ptr == NULL || len_ptr == NULL) {
            errno = EFAULT;
            return -1;
        }
        if (registered_head == NULL) {
            /* Same shape glibc gives each thread: an empty circular list and
             * the offset from a mutex's list node to its futex word. */
            empty_head.list.next = &empty_head.list;
            empty_head.futex_offset =
                (long)offsetof(pthread_mutex_t, __data.__lock) -
                (long)offsetof(pthread_mutex_t, __data.__list.__next);
            registered_head = &empty_head;
            registered_len = sizeof(empty_head);
        }
        *head_ptr = registered_head;
        *len_ptr = registered_len;
        return 0;
    }
    return real_syscall(number, a[0], a[1], a[2], a[3], a[4], a[5]);
}

static const char *redirect(const char *path)
{
    const char *fake;

    if (path == NULL || strcmp(path, "/proc/cpuinfo") != 0)
        return path;
    fake = getenv("I386_FAKE_CPUINFO");
    return (fake != NULL && *fake != '\0') ? fake : path;
}

/* open() takes a mode only with O_CREAT or O_TMPFILE. O_TMPFILE is two bits,
 * __O_TMPFILE | O_DIRECTORY (i386: 020000000 | 0200000), so it has to be
 * compared whole: `flags & O_TMPFILE` is also true for a plain O_DIRECTORY
 * open, which passes no mode to read. */
_Static_assert((O_TMPFILE & O_DIRECTORY) == O_DIRECTORY && O_TMPFILE != O_DIRECTORY,
               "O_TMPFILE is expected to include O_DIRECTORY");

static mode_t mode_arg(int flags, va_list ap)
{
    if ((flags & O_CREAT) != 0 || (flags & O_TMPFILE) == O_TMPFILE)
        return (mode_t)va_arg(ap, int);
    return 0;
}

int open(const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode;
    REAL(open);
    va_start(ap, flags);
    mode = mode_arg(flags, ap);
    va_end(ap);
    return real_open(redirect(path), flags, mode);
}

int open64(const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode;
    REAL(open64);
    va_start(ap, flags);
    mode = mode_arg(flags, ap);
    va_end(ap);
    return real_open64(redirect(path), flags, mode);
}

int openat(int dirfd, const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode;
    REAL(openat);
    va_start(ap, flags);
    mode = mode_arg(flags, ap);
    va_end(ap);
    return real_openat(dirfd, redirect(path), flags, mode);
}

int openat64(int dirfd, const char *path, int flags, ...)
{
    va_list ap;
    mode_t mode;
    REAL(openat64);
    va_start(ap, flags);
    mode = mode_arg(flags, ap);
    va_end(ap);
    return real_openat64(dirfd, redirect(path), flags, mode);
}

FILE *fopen(const char *path, const char *mode)
{
    REAL(fopen);
    return real_fopen(redirect(path), mode);
}

FILE *fopen64(const char *path, const char *mode)
{
    REAL(fopen64);
    return real_fopen64(redirect(path), mode);
}
