/*
 * schnitzel-test.c: a tiny Windows console program for the engine release checks.
 *
 * This file is part of Schnitzel, licensed under the GNU General Public License v3.0 or later.
 *
 * Built twice with MinGW-w64 GCC, as a 32-bit (i686) and a 64-bit (x86_64) program. The prefix
 * check runs both through Wine and compares their output and exit code, which proves that
 * the engine's WoW64 build runs 32-bit and 64-bit Windows programs.
 */

#include <stdio.h>
#include <windows.h>

#if defined(__x86_64__)
#define SCHNITZEL_ARCH "x86_64"
#elif defined(__i386__)
#define SCHNITZEL_ARCH "i686"
#else
#error "unsupported architecture"
#endif

/* The exit code the check expects: not 0 or 1, so a crash or an early exit can't pass. */
#define SCHNITZEL_EXIT_CODE 42

int main(void)
{
    SYSTEM_INFO info;
    BOOL wow64 = FALSE;

    GetNativeSystemInfo(&info);
    IsWow64Process(GetCurrentProcess(), &wow64);

    printf("schnitzel-test arch=%s bits=%u wow64=%s\n",
           SCHNITZEL_ARCH, (unsigned)(sizeof(void *) * 8), wow64 ? "yes" : "no");
    fflush(stdout);
    return SCHNITZEL_EXIT_CODE;
}
