# Third-party code

Each directory here is a git submodule, pinned to a release. Clone fds with
`git clone --recursive`, or run `git submodule update --init` in a clone.

| Directory | Project | Version | License | Used for |
|---|---|---|---|---|
| `zstd/` | [Zstandard](https://github.com/facebook/zstd) | v1.5.7 | BSD-3-Clause (see `zstd/LICENSE`) | Decompressing zstd-compressed Arrow buffers and Parquet pages (`src/zstd.zig`) |

Only zstd's decompressor is built (`lib/common` and `lib/decompress`; see
`addZstd` in `build.zig`), and it is compiled into the `fds` binary and
into `libfds.a`. Anyone redistributing either in binary form must include
zstd's copyright notice and license, as `zstd/LICENSE` says. zstd is dual
licensed (BSD or GPLv2); fds uses it under the BSD license.

To update a submodule to a new release:

```
cd third_party/zstd && git fetch --tags && git checkout v1.5.8 && cd ../..
git add third_party/zstd    # then update the version above
```
