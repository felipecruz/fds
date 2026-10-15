# Scripting

The examples run in `testdata/tree` (see
[Running the examples](README.md#running-the-examples)).

## Exit status

As grep's: 0 if something matched, 1 if nothing did, 2 on an error (a
file that couldn't be read, or strings that couldn't be searched), even
if something matched elsewhere.

```console
$ fds -l parquet zqxjv; echo "exit $?"
exit 1
$ if fds -l parquet needle > /dev/null; then echo found; fi
found
```

## From Python

Rows are 0-based and count across the whole file, so they index a
dataframe of the file directly:

```python
import io, subprocess
import pandas as pd

out = subprocess.run(["fds", "--json", "parquet/snappy.parquet", "needle"],
                     capture_output=True, text=True).stdout
hits = pd.read_json(io.StringIO(out), lines=True)  # path, column, row, value
df = pd.read_parquet("parquet/snappy.parquet")
print(df.iloc[hits.row.unique()])                  # the matching rows, every column
```

The same with polars: `pl.read_parquet(path)[rows]`. For an Arrow file:
`pyarrow.ipc.open_file(path).read_all().to_pandas().iloc[rows]`.

## With other tools

`-l` hands files to other commands. To copy every file that mentions a
term:

```
fds -l data/ 'customer-4242' | xargs -I{} cp {} quarantine/
```

`--json` and `jq`, for the matches per column:

```console
$ fds --json parquet/snappy.parquet needle | jq -r .column | sort | uniq -c
      2 cat
      1 m[].key
      1 m[].value
      2 name
      1 note
      2 pair[]
      3 tags[]
      2 user.name
      2 view
```

Hugging Face datasets are cached as Arrow files, so a cache can be
searched as it is:

```
fds -i ~/.cache/huggingface/datasets 'some phrase'
```

## The C library

`libfds.a` and `fds.h` (in `zig-out/lib` and `zig-out/include` after
`zig build`) run the same search, with a callback per match:

```c
#include <stdio.h>
#include "fds.h"

static int on_match(void *ctx, const fds_match *m) {
    printf("%s:%s:%llu:%s\n", m->path, m->at, (unsigned long long)m->row, m->text);
    return 0;   /* nonzero stops the search */
}

int main(void) {
    return fds_search("testdata/tree", "needle", FDS_IGNORE_CASE, 0, on_match, NULL) < 0;
}
```

Flags: `FDS_IGNORE_CASE`, `FDS_REGEX`; threads: 0 for automatic. The
callback is never called concurrently, and one file's matches arrive
together, in order. [`examples/count.c`](https://github.com/felipecruz/fds/blob/main/examples/count.c) is a
complete program: `zig build c-example -- testdata/tree needle`.
