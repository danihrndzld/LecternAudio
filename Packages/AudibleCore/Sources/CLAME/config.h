/* Hand-written config for building LAME 3.100 with SwiftPM on macOS and Linux (replaces autoconf's config.h). */
#ifndef LAME_CONFIG_H
#define LAME_CONFIG_H

/* SwiftPM defines DEBUG in debug builds, which turns on LAME's stderr tracing and slow asserts. */
#undef DEBUG
#ifndef NDEBUG
#define NDEBUG 1
#endif

#define STDC_HEADERS 1
#define HAVE_ERRNO_H 1
#define HAVE_FCNTL_H 1
#define HAVE_LIMITS_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDINT_H 1
#define HAVE_STDLIB_H 1
#define HAVE_STRING_H 1
#define HAVE_UNISTD_H 1
#define HAVE_MEMCPY 1
#define HAVE_STRCHR 1
#define LAME_LIBRARY_BUILD 1
#define USE_FAST_LOG 1

#define PACKAGE "lame"
#define PACKAGE_NAME "lame"
#define PACKAGE_VERSION "3.100"

typedef float ieee754_float32_t;
typedef double ieee754_float64_t;

#endif
