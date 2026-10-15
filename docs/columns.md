# Columns

fds searches every string column, at any depth, unless `-c` says which.
The examples run in `testdata/tree` (see
[Running the examples](README.md#running-the-examples)).

## Column paths

A column is printed as its path from the top-level column, the same in
Arrow and Parquet files:

| Path | What |
|:---|:---|
| `name` | a top-level column |
| `user.name` | a field of a struct |
| `tags[]` | the values of a list (or fixed-size list) |
| `m[].key`, `m[].value` | the keys and values of a map |
| `a.b[].c` | any nesting of those |

A match in a nested value is reported as the top-level row that holds it.
A row whose list holds the term several times is reported once: here row
3 is `["needle", "needle2"]`.

```console
$ fds --content -c tags parquet/snappy.parquet needle
parquet/snappy.parquet:tags[]:0:needle
parquet/snappy.parquet:tags[]:3:needle
```

## Choosing columns: `-c`

`-c NAME` searches only that column; repeat it for several. A top-level
name selects everything under it:

```console
$ fds -c user -c m parquet/snappy.parquet needle
parquet/snappy.parquet:user.name:0
parquet/snappy.parquet:m[].key:1
parquet/snappy.parquet:m[].value:0
parquet/snappy.parquet:user.name:4
```

Or give a nested path exactly as fds prints it:

```console
$ fds -c user.name -c 'm[].value' --content parquet/snappy.parquet needle
parquet/snappy.parquet:user.name:0:needle
parquet/snappy.parquet:m[].value:0:needle
parquet/snappy.parquet:user.name:4:needles
```

Columns not selected are not read at all: in Parquet, their pages are
never decompressed. A file with none of the columns is skipped quietly.
