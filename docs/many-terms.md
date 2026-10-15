# Many terms

```
fds [options] -f <file> <path>
```

`-f` reads terms from a file, one per line; a value matches if it holds
any of them. Empty lines are ignored, and Windows line endings are fine.
`-f` can be repeated, and mixed with `-e`. The examples run in
`testdata/tree` (see [Running the examples](README.md#running-the-examples)).

```console
$ printf 'haystack\nred\nbob\na needle here\n' > /tmp/terms.txt
$ fds -f /tmp/terms.txt --content parquet/snappy.parquet
parquet/snappy.parquet:name:3:haystack
parquet/snappy.parquet:user.name:2:bob
parquet/snappy.parquet:cat:0:red
parquet/snappy.parquet:cat:2:red
parquet/snappy.parquet:name:4:a needle here
```

`-f -` reads the terms from stdin, so another command can produce them:

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

`-i` and `-w` apply to every term:

```console
$ printf 'red\nhay\nneedle\n' | fds -w -f - --content -c name -c cat parquet/snappy.parquet
parquet/snappy.parquet:name:0:needle
parquet/snappy.parquet:name:2:hay
parquet/snappy.parquet:cat:0:red
parquet/snappy.parquet:cat:1:needle
parquet/snappy.parquet:cat:2:red
parquet/snappy.parquet:name:4:a needle here
parquet/snappy.parquet:cat:4:needle
```

## Thousands of terms

From 8 terms on, fds searches all of them in one pass, with an
Aho-Corasick automaton, so ten thousand terms cost about as much as eight.
With `--count`, on a 2.3 GB Arrow file and a 740 MB Parquet file of 20
million rows:

| Terms | Arrow | Parquet |
|---:|---:|---:|
| 8 | 339 ms | 648 ms |
| 100 | 337 ms | 570 ms |
| 1,000 | 347 ms | 578 ms |
| 10,000 | 397 ms | 643 ms |
| 100,000 | 738 ms | 1,035 ms |

(`bench/terms.sh`. Below 8 terms, a SIMD pass per term is faster: about
40 ms each on the Arrow file.)

## Uses

- **Contamination:** do any of a benchmark's questions appear in my
  training data? Write them one per line, then `fds -l -f questions.txt
  train/` lists the files that hold one, and `fds --count -f
  questions.txt train/` counts the rows per column.
- **Leaks:** which rows hold one of these customer IDs, emails or keys?
  `fds -w -f ids.txt data/`.
- **Lookups:** where does each of these values occur, in any column of any
  file? `fds --json -f values.txt lake/ > hits.jsonl`.

A regex is better when the terms follow a pattern, for example email
addresses: `fds -E data/ '[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}'`.
