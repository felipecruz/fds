# Columns

fds searches every string column, at any depth, unless `-c` says which.
The examples run in `testdata/tree` (see
[Running the examples](README.md#running-the-examples)).

## Where in the row

A match in a nested value is reported as the top-level row that holds it,
and its place in that row: which list element, which map key, which
struct field. Every matching value is a line, so a row whose list holds
the term twice gives two (here row 3 is `["needle", "needle2"]`):

```console
$ fds --content -c tags parquet/snappy.parquet needle
parquet/snappy.parquet:tags[1]:0:needle
parquet/snappy.parquet:tags[0]:3:needle
parquet/snappy.parquet:tags[1]:3:needle2
```

| Place | What |
|:---|:---|
| `name` | a top-level column |
| `user.name` | a field of a struct |
| `tags[1]` | element 1 (0-based) of a list or fixed-size list |
| `m[key]` | the value of a map's entry `key` |
| `m[key].key` | that entry's key itself |
| `m[#2]` | entry 2 of a map whose keys aren't strings |
| `a[0].b[2]` | any nesting of those |

```console
$ fds --content -c m parquet/snappy.parquet needle
parquet/snappy.parquet:m[needle].key:1:needle
parquet/snappy.parquet:m[k]:0:needle
```

In a map key, a backslash, `]` and line breaks are escaped with a
backslash, so a place is always one line: `m[a\]b]` is key `a]b`. With
`--json`, the place is the `at` field.

## Column paths

Each column has a path, the same in Arrow and Parquet files: the place
with its positions left out. `tags[1]` is in column `tags[]`, `m[key]` in
`m[].value`, `m[key].key` in `m[].key`. Column paths are what `-c`
selects, what `--count` counts by, and the `column` field of `--json`.

## Choosing columns: `-c`

`-c NAME` searches only that column; repeat it for several. A top-level
name selects everything under it:

```console
$ fds -c user -c m parquet/snappy.parquet needle
parquet/snappy.parquet:user.name:0
parquet/snappy.parquet:m[needle].key:1
parquet/snappy.parquet:m[k]:0
parquet/snappy.parquet:user.name:4
```

Or give a nested path exactly as fds prints it:

```console
$ fds -c user.name -c 'm[].value' --content parquet/snappy.parquet needle
parquet/snappy.parquet:user.name:0:needle
parquet/snappy.parquet:m[k]:0:needle
parquet/snappy.parquet:user.name:4:needles
```

Columns not selected are not read at all: in Parquet, their pages are
never decompressed. A file with none of the columns is skipped quietly.
