/* fds: search the string values of Arrow IPC and Parquet files (threads +
 * SIMD), as a C library.
 *
 * Build: `zig build` installs zig-out/lib/libfds.a and zig-out/include/fds.h.
 * Example: examples/count.c (`zig build c-example -- <folder> <term>`).
 */
#ifndef FDS_H
#define FDS_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Flags for fds_search. */
#define FDS_IGNORE_CASE 1u /* ASCII case-insensitive */
#define FDS_REGEX 2u       /* term is a regex (syntax: src/regex.zig) */

/* Return values of fds_search. */
#define FDS_OK 0        /* searched everything */
#define FDS_STOPPED 1   /* the callback asked to stop */
#define FDS_EARG (-1)   /* NULL argument or empty term */
#define FDS_EREGEX (-2) /* invalid regex */
#define FDS_EROOT (-3)  /* root folder can't be opened */
#define FDS_ENOMEM (-4) /* out of memory */

#include <stdint.h>

typedef struct fds_match {
    const char *path;   /* "<root>/<relative path>" (or root, if a file), NUL-terminated */
    const char *column; /* column path: "name", "user.name", "tags[]", NUL-terminated */
    uint64_t row;       /* 0-based row in the file */
    const char *text;   /* the matching value, NUL-terminated (it may contain NULs) */
    size_t text_len;
    const char *at;     /* its place in the row: "tags[1]", "m[key]", "m[key].key";
                           the column itself at the top level. NUL-terminated */
} fds_match;

/* Called once per matching value. Never called concurrently; one
 * file's matches arrive in order (by record batch, column, then row) and
 * files never interleave. `m` and its strings are valid only during the
 * call. Return 0 to continue, nonzero to stop. */
typedef int (*fds_callback)(void *ctx, const fds_match *m);

/* Searches every string value of every .arrow, .feather, .arrows and
 * .parquet file under `root`, or of `root` itself if it is a file, for
 * `term`. In Arrow files: utf8, large_utf8 and string_view, dictionary-
 * encoded or not, top-level or inside structs, lists and maps. In Parquet
 * files: string columns, top-level or inside structs, lists and maps.
 * Files that can't be read are skipped.
 * `threads` = 0 means automatic: the performance-core count on Apple
 * silicon, else the CPU count. Blocks until done. */
int fds_search(const char *root, const char *term, unsigned flags,
               unsigned threads, fds_callback cb, void *ctx);

/* The library version, e.g. "0.0.7". */
const char *fds_version(void);

#ifdef __cplusplus
}
#endif

#endif
