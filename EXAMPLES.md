# fds examples

Every example on this page runs as shown on the test files in this
repository. Build fds (`zig build`), then:

```
cd testdata/tree
export PATH="$PWD/../../zig-out/release:$PATH"
```

The files hold one small table, written as Arrow (`plain.arrow`,
`sub/lz4.feather`, `sub/zstd.arrow`) and as Parquet four ways (under
`parquet/`), plus a few odd ones: a stream with dictionary deltas, a file
written by polars, and a truncated file. The table has six rows and every
kind of string column: plain (`name`, `note`), string views (`view`), a
list (`tags`), a struct (`user`, with `user.name`), a dictionary (`cat`),
a map (`m`), a fixed-size list (`pair`), and a union (`u`).
[`testdata/make.py`](testdata/make.py) writes them, and
[`testdata/examples.py`](testdata/examples.py) reruns the examples to
update their output.

Contents:
[Searching](#searching) ·
[Matching](#matching) ·
[Many terms](#many-terms) ·
[Choosing columns](#choosing-columns) ·
[Output](#output) ·
[Scripts and other tools](#scripts-and-other-tools) ·
[What fds didn't search](#what-fds-didnt-search) ·
[The C library](#the-c-library)

## Searching

A file: one line per matching value, `path:column:row`. Rows are 0-based
and count from the start of the file, across row groups (or record
batches).

```console
$ fds parquet/snappy.parquet needle
parquet/snappy.parquet:name:0
parquet/snappy.parquet:view:1
parquet/snappy.parquet:view:3
parquet/snappy.parquet:tags[]:0
parquet/snappy.parquet:tags[]:3
parquet/snappy.parquet:user.name:0
parquet/snappy.parquet:cat:1
parquet/snappy.parquet:m[].key:1
parquet/snappy.parquet:m[].value:0
parquet/snappy.parquet:pair[]:1
parquet/snappy.parquet:name:4
parquet/snappy.parquet:note:4
parquet/snappy.parquet:user.name:4
parquet/snappy.parquet:cat:4
parquet/snappy.parquet:pair[]:5
```

`--content` adds the value. Newlines in it are printed as `\n`, so one
match is always one line.

```console
$ fds --content parquet/snappy.parquet needle
parquet/snappy.parquet:name:0:needle
parquet/snappy.parquet:view:1:a long string with needle inside
parquet/snappy.parquet:view:3:needle
parquet/snappy.parquet:tags[]:0:needle
parquet/snappy.parquet:tags[]:3:needle
parquet/snappy.parquet:user.name:0:needle
parquet/snappy.parquet:cat:1:needle
parquet/snappy.parquet:m[].key:1:needle
parquet/snappy.parquet:m[].value:0:needle
parquet/snappy.parquet:pair[]:1:needle
parquet/snappy.parquet:name:4:a needle here
parquet/snappy.parquet:note:4:needle\nline
parquet/snappy.parquet:user.name:4:needles
parquet/snappy.parquet:cat:4:needle
parquet/snappy.parquet:pair[]:5:needle
```

A directory: every `.arrow`, `.feather`, `.arrows` and `.parquet` file
under it, searched in parallel. Files come out in no fixed order; within a
file, by row group (or record batch), column, then row. Here `-l` prints
just the files that match:

```console
$ fds -l . needle
fds: ./plain.arrow: column u not searched (strings in a union)
fds: ./sub/lz4.feather: column u not searched (strings in a union)
fds: ./sub/zstd.arrow: column u not searched (strings in a union)
fds: ./truncated.arrow: not a valid Arrow IPC file
./sub/lz4.feather
./plain.arrow
./sub/zstd.arrow
./deltas.arrows
./polars.arrow
./parquet/snappy.parquet
./parquet/v2_delta.parquet
./parquet/plain_gzip.parquet
./parquet/lz4.parquet
```

Problems go to stderr: a file that isn't valid, and columns fds couldn't
search (see [What fds didn't search](#what-fds-didnt-search)). The exit
status is then 2.

A file is searched whatever its name; the format comes from its first
bytes.

## Matching

`-i` ignores case (ASCII letters):

```console
$ fds -i --content -c note plain.arrow NEEDLE
plain.arrow:note:1:NEEDLE
plain.arrow:note:4:needle\nline
```

`-S` (smart case) ignores case only if the term is all lower case:

```console
$ fds -S --content -c note plain.arrow needle
plain.arrow:note:1:NEEDLE
plain.arrow:note:4:needle\nline
$ fds -S --content -c note plain.arrow Needle; echo "exit $?"
exit 1
```

`-w` matches whole words only: `needle` but not `needles`.

```console
$ fds -w --content -c name -c user plain.arrow needle
plain.arrow:name:0:needle
plain.arrow:user.name:0:needle
plain.arrow:name:4:a needle here
```

`-E` makes the term a regex. `^` and `$` are the start and end of the
value:

```console
$ fds -E --content -c name -c tags parquet/snappy.parquet '^needle$'
parquet/snappy.parquet:name:0:needle
parquet/snappy.parquet:tags[]:0:needle
parquet/snappy.parquet:tags[]:3:needle
$ fds -E --content -c name plain.arrow 'a \w+ here'
plain.arrow:name:4:a needle here
```

The syntax: `. [a-z] [^0-9] \d \w \s \b ^ $ * + ? {n,m} | ( )`, and `\n`,
`\r`, `\t`. Built with `zig build -Dpcre2`, fds runs regexes with PCRE2
instead, which adds lazy quantifiers, lookaround and backreferences:

```console pcre2
$ fds -E --content -c user plain.arrow 'needle(?!s)'
plain.arrow:user.name:0:needle
```

`-e` gives several terms; a value matches if it has any of them:

```console
$ fds -e hay -e here --content -c name parquet/snappy.parquet
parquet/snappy.parquet:name:2:hay
parquet/snappy.parquet:name:3:haystack
parquet/snappy.parquet:name:4:a needle here
```

## Many terms

`-f` reads the terms from a file, one per line. Empty lines are ignored,
and Windows line endings are fine.

```console
$ printf 'haystack\nred\nbob\na needle here\n' > /tmp/terms.txt
$ fds -f /tmp/terms.txt --content parquet/snappy.parquet
parquet/snappy.parquet:name:3:haystack
parquet/snappy.parquet:user.name:2:bob
parquet/snappy.parquet:cat:0:red
parquet/snappy.parquet:cat:2:red
parquet/snappy.parquet:name:4:a needle here
```

`-f -` reads them from stdin, so they can come from another command:

```console
$ printf 'blue\nbob\n' | fds -f - --content parquet
parquet/snappy.parquet:user.name:2:bob
parquet/snappy.parquet:cat:5:blue
parquet/v2_delta.parquet:user.name:2:bob
parquet/v2_delta.parquet:cat:5:blue
parquet/plain_gzip.parquet:user.name:2:bob
parquet/plain_gzip.parquet:cat:5:blue
parquet/lz4.parquet:user.name:2:bob
parquet/lz4.parquet:cat:5:blue
```

From 8 terms on, fds searches all of them in one pass (an Aho-Corasick
automaton), so thousands of terms cost about as much as eight: 10,000
take 400 ms over a 2.3 GB Arrow file. `-i` and `-w` apply to every term.
Some uses:

- **Contamination:** do any of a benchmark's questions appear in my
  training data? Export them one per line, then
  `fds -l -f questions.txt train/` lists the files that hold one, and
  `fds --count -f questions.txt train/` says how many rows per column.
- **Leaks:** which rows hold one of these customer IDs, emails or API
  keys? `fds -w -f ids.txt data/`.
- **Lookups:** where does each of these values occur, in any column of
  any file? `fds --json -f values.txt lake/ > hits.jsonl`.

A regex is better for a pattern than a list, for example email addresses:
`fds -E data/ '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}'`.

## Choosing columns

`-c` searches only some columns. A top-level name selects everything
under it:

```console
$ fds -c tags parquet/snappy.parquet needle
parquet/snappy.parquet:tags[]:0
parquet/snappy.parquet:tags[]:3
```

Or name a nested path exactly, as fds prints it: a struct field is
`user.name`, a list's values are `tags[]`, a map's are `m[].key` and
`m[].value`. `-c` can be repeated.

```console
$ fds -c user.name -c 'm[].value' --content parquet/snappy.parquet needle
parquet/snappy.parquet:user.name:0:needle
parquet/snappy.parquet:m[].value:0:needle
parquet/snappy.parquet:user.name:4:needles
```

A row whose list holds the term several times is reported once (row 3:
`["needle", "needle2"]`):

```console
$ fds --content -c tags parquet/snappy.parquet needle
parquet/snappy.parquet:tags[]:0:needle
parquet/snappy.parquet:tags[]:3:needle
```

## Output

`--count` prints how many rows match in each column:

```console
$ fds --count parquet/snappy.parquet needle
parquet/snappy.parquet:name:2
parquet/snappy.parquet:note:1
parquet/snappy.parquet:view:2
parquet/snappy.parquet:tags[]:2
parquet/snappy.parquet:user.name:2
parquet/snappy.parquet:cat:2
parquet/snappy.parquet:m[].key:1
parquet/snappy.parquet:m[].value:1
parquet/snappy.parquet:pair[]:2
```

`-m N` stops after N matches in each file (the first N in the file's
order). `-l` stops at the first.

```console
$ fds -m 2 parquet/snappy.parquet needle
parquet/snappy.parquet:name:0
parquet/snappy.parquet:view:1
```

`--json` prints JSON Lines. A value that isn't valid UTF-8 comes as
`value_base64` instead. With `-l` the objects are `{"path"}`, with
`--count` `{"path","column","count"}`.

```console
$ fds --json -c note plain.arrow needle
{"path":"plain.arrow","column":"note","row":4,"value":"needle\nline"}
$ fds --json --count -c tags -c cat parquet/snappy.parquet needle
{"path":"parquet/snappy.parquet","column":"tags[]","count":2}
{"path":"parquet/snappy.parquet","column":"cat","count":2}
```

With `jq`, for example the matches per column:

```console
$ fds --json parquet/snappy.parquet needle | jq -r .column | sort | uniq -c
      2 cat
      1 m[].key
      1 m[].value
      2 name
      1 note
      2 pair[]
      2 tags[]
      2 user.name
      2 view
```

On a terminal, paths, columns, rows and matches are colored, as in
ripgrep. `--color always` keeps the colors through a pipe
(`fds --color always ... | less -R`); `--color never` or `NO_COLOR` turns
them off.

## Scripts and other tools

The exit status is grep's: 0 if something matched, 1 if nothing did, 2 on
an error (a file that couldn't be read, or columns that couldn't be
searched), even if something matched.

```console
$ fds -l parquet zqxjv; echo "exit $?"
exit 1
$ if fds -l parquet needle > /dev/null; then echo found; fi
found
```

Rows are 0-based, counted across the whole file, so they index a
dataframe of the file directly:

```python
import io, subprocess
import pandas as pd

out = subprocess.run(["fds", "--json", "parquet/snappy.parquet", "needle"],
                     capture_output=True, text=True).stdout
hits = pd.read_json(io.StringIO(out), lines=True)     # path, column, row, value
df = pd.read_parquet("parquet/snappy.parquet")
print(df.iloc[hits.row.unique()])                     # the matching rows, every column
```

The same with polars: `pl.read_parquet(path)[rows]`. For an Arrow file,
`pyarrow.ipc.open_file(path).read_all().to_pandas().iloc[rows]`.

`-l` gives files to other commands, for example to copy every file that
mentions a term:

```
fds -l data/ 'customer-4242' | xargs -I{} cp {} quarantine/
```

Hugging Face datasets are cached as Arrow files, so a cache can be
searched directly:

```
fds -i ~/.cache/huggingface/datasets 'some phrase'
```

## What fds didn't search

fds never skips strings silently. Strings it can't search (inside Arrow
unions, run-end-encoded arrays and list views) are reported, and so are
files it can't read; matches found elsewhere are still printed, and the
exit status is 2:

```console
$ fds -c name -c u plain.arrow needle
fds: plain.arrow: column u not searched (strings in a union)
plain.arrow:name:0
plain.arrow:name:4
$ fds -l truncated.arrow needle
fds: truncated.arrow: not a valid Arrow IPC file
```

`-c` leaves out what it doesn't select, warnings included:

```console
$ fds -c name plain.arrow needle; echo "exit $?"
plain.arrow:name:0
plain.arrow:name:4
exit 0
```

Binary columns (Arrow `binary`, Parquet `BYTE_ARRAY` with no text
annotation) are not text, and are not searched.

## The C library

`libfds.a` and `fds.h` (in `zig-out/lib` and `zig-out/include`) run the
same search with a callback per match.
[`examples/count.c`](examples/count.c) counts matches and prints the first
few:

```
zig build c-example -- testdata/tree needle
```
