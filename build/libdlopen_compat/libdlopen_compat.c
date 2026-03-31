#define _GNU_SOURCE

#include <dlfcn.h>

/*
 * Shenji's bundled frida gadget still imports glibc's private
 * __libc_dlopen_mode symbol. Newer distros no longer expose it to
 * third-party libraries, so forward it to the public dlopen entrypoint.
 */
void *__libc_dlopen_mode(const char *filename, int flag) {
    return dlopen(filename, flag);
}
