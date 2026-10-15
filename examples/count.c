/* Counts matching values with libfds and prints the first few.
 * Usage: count [-i] [-E] <path> <term>
 * Build and run: zig build c-example -- testdata/tree needle */
#include <stdio.h>
#include <string.h>

#include "fds.h"

struct counter {
    size_t matches;
};

static int on_match(void *ctx, const fds_match *m) {
    struct counter *c = ctx;
    if (c->matches < 3) printf("%s:%s:%llu:%s\n", m->path, m->at, (unsigned long long)m->row, m->text);
    c->matches++;
    return 0; /* keep going */
}

int main(int argc, char **argv) {
    unsigned flags = 0;
    int i = 1;
    for (; i < argc && argv[i][0] == '-'; i++) {
        if (strcmp(argv[i], "-i") == 0) flags |= FDS_IGNORE_CASE;
        else if (strcmp(argv[i], "-E") == 0) flags |= FDS_REGEX;
        else break;
    }
    if (argc - i != 2) {
        fprintf(stderr, "usage: count [-i] [-E] <path> <term>\n");
        return 2;
    }

    struct counter c = {0};
    int rc = fds_search(argv[i], argv[i + 1], flags, 0, on_match, &c);
    if (rc < 0) {
        fprintf(stderr, "fds_search failed: %d\n", rc);
        return 2;
    }
    printf("%zu matching values (libfds %s)\n", c.matches, fds_version());
    return 0;
}
