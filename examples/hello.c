/* SPDX-License-Identifier: MIT
 * Smoke test: a dynamically linked i386 program that checks the two things
 * the shim fakes, so a passing run proves libc6:i386, qemu-i386 and the shim
 * are all wired up. `hello-i386 --sleep N` then stays up N seconds, to check
 * what /proc/PID/comm shows for a launcher. `hello-i386 --exec PROG [ARGS]`
 * then execs PROG (a native program, say), to check what a child inherits.
 */
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/utsname.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    struct utsname u;
    void *head = NULL;
    size_t len = 0;
    char line[512];
    int x86_flags = 0;
    FILE *f;

    uname(&u);
    printf("hello from a %zu-bit x86 binary (kernel reports %s)\n",
           sizeof(void *) * 8, u.machine);

    if (syscall(SYS_get_robust_list, 0, &head, &len) == 0)
        printf("get_robust_list: ok (len %zu)\n", len);
    else
        printf("get_robust_list: failed\n");

    f = fopen("/proc/cpuinfo", "r");
    while (f != NULL && fgets(line, sizeof(line), f) != NULL)
        if (strncmp(line, "flags", 5) == 0 && strstr(line, " sse2") != NULL)
            x86_flags = 1;
    if (f != NULL)
        fclose(f);
    printf("/proc/cpuinfo x86 flags: %s\n", x86_flags ? "ok" : "missing");

    if (argc == 3 && strcmp(argv[1], "--sleep") == 0) {
        fflush(stdout);
        sleep((unsigned int)atoi(argv[2]));
    }
    if (len == 0 || !x86_flags)
        return 1;
    if (argc >= 3 && strcmp(argv[1], "--exec") == 0) {
        fflush(stdout);
        execvp(argv[2], argv + 2);
        perror(argv[2]);
        return 127;
    }
    return 0;
}
