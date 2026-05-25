// FineTune/Audio/Loopback/ShmHelper.h
// C helper to call shm_open (variadic C function unavailable in Swift)

#ifndef ShmHelper_h
#define ShmHelper_h

#include <sys/mman.h>
#include <fcntl.h>

/// Wrapper for shm_open since Swift cannot call C variadic functions.
static inline int ft_shm_open(const char *name, int oflag, mode_t mode) {
    return shm_open(name, oflag, mode);
}

#endif /* ShmHelper_h */
