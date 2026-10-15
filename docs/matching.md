# Matching

By default a term is a literal: a value matches if it contains it,
anywhere. The examples run in `testdata/tree` (see
[Running the examples](README.md#running-the-examples)).

## Case

`-i` ignores case. Only ASCII letters are folded; other bytes, UTF-8
included, match exactly.

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

## Whole words

`-w` matches whole words only: `needle`, not `needles`. A word byte is a
letter, a digit or `_`; where a term starts or ends with a word byte, the
byte before or after it must not be one (or be the value's edge).

```console
$ fds -w --content -c name -c user plain.arrow needle
plain.arrow:name:0:needle
plain.arrow:user.name:0:needle
plain.arrow:name:4:a needle here
```

## Regexes

`-E` makes the term a regex. `^` and `$` are the start and end of the
value, not of a line:

```console
$ fds -E --content -c name -c tags parquet/snappy.parquet '^needle$'
parquet/snappy.parquet:name:0:needle
parquet/snappy.parquet:tags[]:0:needle
parquet/snappy.parquet:tags[]:3:needle
$ fds -E --content -c name plain.arrow 'a \w+ here'
plain.arrow:name:4:a needle here
```

The syntax: `.` `[a-z]` `[^0-9]` `\d` `\w` `\s` `\b` `^` `$` `*` `+` `?`
`{n,m}` `|` `( )`, and the escapes `\n` `\r` `\t`. `.` matches any byte,
newlines included; `\d`, `\w`, `\s` and `\b` are ASCII. The engine is a
Pike VM: its time is linear in the value, whatever the pattern.

The literal part a match must contain (`checkout` in
`^/api/v[0-9]+/checkout/\d+$`) is found first, with the same SIMD search
as plain terms, and only the values that hold it go to the regex engine.

### PCRE2

Built with `zig build -Dpcre2`, fds runs regexes with PCRE2 and its JIT
instead: 1.2 to 4 times faster on the benchmarks, and the full PCRE
syntax: lazy quantifiers, lookaround, backreferences, POSIX classes.
`fds -V` says which engine a binary has.

```console pcre2
$ fds -E --content -c user plain.arrow 'needle(?!s)'
plain.arrow:user.name:0:needle
```

PCRE2 backtracks, so a pattern like `(a+)+$` can take exponential time on
some values. Each match is bounded; a value that reaches the bound fails
the search of its file (exit status 2) instead of counting as no match.

## Several terms

`-e` gives a term; repeated, a value matches if it holds any of them.

```console
$ fds -e hay -e here --content -c name parquet/snappy.parquet
parquet/snappy.parquet:name:2:hay
parquet/snappy.parquet:name:3:haystack
parquet/snappy.parquet:name:4:a needle here
```

Literals each get a SIMD pass; from 8 terms on, one pass searches them
all (see [Many terms](many-terms.md)). With `-E`, the terms are regexes,
joined as alternatives; with `-w`, each must be a whole word.
