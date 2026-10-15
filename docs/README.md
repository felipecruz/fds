# fds documentation

fds searches the string values of Arrow and Parquet files, grep-style:
point it at a directory and a term, and it prints every matching value with
its file, column and row.

![fds searching 20 million rows of Arrow and Parquet logs](demo.gif)

```
fds [options] <path> <term>
fds [options] -e <term> [-e <term>]... <path>
fds [options] -f <file> <path>
```

## Topics

| Topic | | In the terminal |
|:---|:---|:---|
| [Searching](search.md) | files and directories, rows, the output line, order | `fds help search` |
| [Matching](matching.md) | case, whole words, regexes, several terms | `fds help matching` |
| [Many terms](many-terms.md) | `-f`: thousands of terms in one pass | `fds help many-terms` |
| [Columns](columns.md) | `-c`, column paths in structs, lists and maps | `fds help columns` |
| [Output](output.md) | `--content`, `--count`, `-l`, `-m`, `--json`, colors | `fds help output` |
| [Scripting](scripting.md) | exit status, pandas and polars, other tools, the C library | `fds help scripting` |
| [Formats](formats.md) | what gets searched, and what fds reports it didn't | `fds help formats` |

The reference for every option is the man page, [`fds.1`](fds.1.md):
`man fds` once installed, or `man docs/fds.1` from the repository.

## Running the examples

Every example in these pages runs as shown on the test files in this
repository, and its output is the real one: CI runs them all and fails if
an output changes (`docs/examples.py --check`). To follow along, build fds
and go to the test files:

```
zig build
cd testdata/tree
export PATH="$PWD/../../zig-out/release:$PATH"
```

They hold one small table, written as Arrow (`plain.arrow`,
`sub/lz4.feather`, `sub/zstd.arrow`) and as Parquet four ways (in
`parquet/`), plus a few odd files: a stream with dictionary deltas
(`deltas.arrows`), a file written by polars, and a truncated file. The
table has six rows and every kind of string column: plain (`name`,
`note`), string views (`view`), a list (`tags`), a struct (`user`, with
`user.name`), a dictionary (`cat`), a map (`m`), a fixed-size list
(`pair`), and a union (`u`). [`testdata/make.py`](https://github.com/felipecruz/fds/blob/main/testdata/make.py)
writes them.

## Maintaining these pages

After changing the output or the test files, rewrite the examples' output
and review the diff:

```
zig build && zig build -Dpcre2 -p zig-out/pcre2
python3 docs/examples.py
```

`python3 docs/examples.py --check` only compares, as CI does. The man page
is generated from `fds.1.md` with pandoc (`docs/man.sh`), the pages are
built into the binary for `fds help` (`docs/help.zig`), and the README's
terminal demo is recorded with [vhs](https://github.com/charmbracelet/vhs)
from `demo.tape` (`docs/demo.sh`).

These pages are also the site at
[felipecruz.github.io/fds](https://felipecruz.github.io/fds/), built by
`.github/workflows/pages.yml` on every push to `main` that touches
`docs/`. Page titles and order are in `_config.yml`, not in the pages, so
they read the same on GitHub, on the site and in `fds help`; a new page
needs a line there. Links out of `docs/` are full GitHub URLs, as the site
has only this folder.
