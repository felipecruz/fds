const std = @import("std");

/// The release version: `fds --version` and `fds_version()` in C.
const version = "0.0.7";

// `zig build` produces:
//   zig-out/debug/fds     (Debug: safety checks, debug info)
//   zig-out/release/fds   (ReleaseFast: production)
//   zig-out/lib/libfds.a  (ReleaseFast C library) + zig-out/include/fds.h
//   zig-out/share/man/man1/fds.1  (the man page, from docs/)
//
// Third-party code lives in third_party/, as git submodules (clone with
// --recursive, or run `git submodule update --init`):
//   third_party/zstd      zstd's decompressor (BSD), for zstd-compressed
//                         Arrow buffers and Parquet pages; see src/zstd.zig
//   third_party/pcre2     PCRE2 (BSD), only with `-Dpcre2`: the regex
//                         engine for -E instead of src/regex.zig; see
//                         src/re.zig
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    const use_pcre2 = b.option(bool, "pcre2", "Run -E regexes with PCRE2 (JIT) instead of fds's own engine") orelse false;
    options.addOption(bool, "pcre2", use_pcre2);

    // The C code in third_party (zstd; PCRE2 with -Dpcre2), always
    // optimized: a debug build of it would only be slow.
    const zstd = b.addLibrary(.{
        .name = "third_party",
        .linkage = .static,
        .root_module = b.createModule(.{ .target = target, .optimize = .ReleaseFast, .link_libc = true }),
    });
    addZstd(b, zstd.root_module, target);
    if (use_pcre2) addPcre2(b, zstd.root_module);

    const variants = [_]struct { dir: []const u8, optimize: std.builtin.OptimizeMode, strip: bool }{
        .{ .dir = "debug", .optimize = .Debug, .strip = false },
        // Stripping halves the size (450 -> 256 KB) and changes no code.
        .{ .dir = "release", .optimize = .ReleaseFast, .strip = true },
    };

    // docs/: the pages `fds help` prints, built into the binary.
    const docs = b.createModule(.{ .root_source_file = b.path("docs/help.zig") });

    for (variants) |v| {
        const exe = b.addExecutable(.{
            .name = "fds",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = v.optimize,
                .strip = v.strip,
                .link_libc = true, // zstd allocates with malloc
            }),
        });
        exe.root_module.addOptions("build_options", options);
        exe.root_module.addImport("docs", docs);
        exe.root_module.linkLibrary(zstd);
        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = v.dir } },
        });
        b.getInstallStep().dependOn(&install.step);
    }

    // The C library: src/c_api.zig behind include/fds.h.
    const lib = b.addLibrary(.{
        .name = "fds",
        .linkage = .static,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/c_api.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            // Callers are C programs: threads must be pthreads, since Zig's
            // own thread setup never ran.
            .link_libc = true,
        }),
    });
    lib.root_module.addOptions("build_options", options);
    // zstd goes inside libfds.a, so C programs link one library.
    addZstd(b, lib.root_module, target);
    if (use_pcre2) addPcre2(b, lib.root_module);
    lib.bundle_compiler_rt = true;
    lib.installHeader(b.path("include/fds.h"), "fds.h");
    b.installArtifact(lib);

    // The man page, written from docs/fds.1.md by docs/man.sh. With
    // `--prefix ~/.local`, `man fds` finds it.
    b.installFile("docs/fds.1", "share/man/man1/fds.1");

    // `zig build c-example -- <path> <term>`: examples/count.c against libfds.
    const example = b.addExecutable(.{
        .name = "count",
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    example.root_module.addCSourceFile(.{ .file = b.path("examples/count.c") });
    example.root_module.addIncludePath(b.path("include"));
    example.root_module.linkLibrary(lib);
    const example_run = b.addRunArtifact(example);
    example_run.addPassthruArgs();
    b.step("c-example", "Run examples/count.c, linked against libfds").dependOn(&example_run.step);

    // `zig build bench-match -- <corpus> [runs]`: time match.findValues alone.
    const bench = b.addExecutable(.{
        .name = "bench-match",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/bench_match.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const bench_run = b.addRunArtifact(bench);
    bench_run.addPassthruArgs();
    b.step("bench-match", "Benchmark match.findValues on an in-memory corpus").dependOn(&bench_run.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .link_libc = true,
        }),
    });
    tests.root_module.addOptions("build_options", options);
    tests.root_module.addImport("docs", docs);
    tests.root_module.linkLibrary(zstd);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

// zstd's decompressor: lib/common and lib/decompress only. No legacy
// formats, no threads (decompression doesn't use them), and zstd's own
// assembly Huffman decoder where it has one (x86-64, not Windows).
fn addZstd(b: *std.Build, m: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    const asm_ok = target.result.cpu.arch == .x86_64 and target.result.os.tag != .windows;
    const root = b.path("third_party/zstd/lib");
    m.addIncludePath(root);
    m.addCSourceFiles(.{
        .root = root,
        .files = &.{
            "common/debug.c",
            "common/entropy_common.c",
            "common/error_private.c",
            "common/fse_decompress.c",
            "common/xxhash.c",
            "common/zstd_common.c",
            "decompress/huf_decompress.c",
            "decompress/zstd_ddict.c",
            "decompress/zstd_decompress.c",
            "decompress/zstd_decompress_block.c",
        },
        .flags = if (asm_ok) &zstd_flags else &(zstd_flags ++ .{"-DZSTD_DISABLE_ASM"}),
    });
    if (asm_ok) m.addAssemblyFile(b.path("third_party/zstd/lib/decompress/huf_decompress_amd64.S"));
}

// PCRE2's 8-bit library with its JIT (sljit, a nested submodule), built
// from the release's generic files: config.h.generic as config.h,
// pcre2.h.generic as pcre2.h and the default (ASCII) character tables.
// No Unicode support: fds runs PCRE2 in byte mode.
fn addPcre2(b: *std.Build, m: *std.Build.Module) void {
    const src = b.path("third_party/pcre2/src");
    const gen = b.addWriteFiles();
    _ = gen.addCopyFile(src.path(b, "config.h.generic"), "config.h");
    _ = gen.addCopyFile(src.path(b, "pcre2.h.generic"), "pcre2.h");
    const tables = gen.addCopyFile(src.path(b, "pcre2_chartables.c.dist"), "pcre2_chartables.c");
    m.addIncludePath(gen.getDirectory());
    m.addIncludePath(src);
    m.addCSourceFiles(.{
        .root = src,
        .files = &.{
            "pcre2_auto_possess.c",
            "pcre2_chkdint.c",
            "pcre2_compile.c",
            "pcre2_compile_cgroup.c",
            "pcre2_compile_class.c",
            "pcre2_config.c",
            "pcre2_context.c",
            "pcre2_error.c",
            "pcre2_extuni.c",
            "pcre2_find_bracket.c",
            "pcre2_jit_compile.c",
            "pcre2_maketables.c",
            "pcre2_match.c",
            "pcre2_match_data.c",
            "pcre2_newline.c",
            "pcre2_ord2utf.c",
            "pcre2_pattern_info.c",
            "pcre2_script_run.c",
            "pcre2_string_utils.c",
            "pcre2_study.c",
            "pcre2_tables.c",
            "pcre2_ucd.c",
            "pcre2_valid_utf.c",
            "pcre2_xclass.c",
        },
        .flags = &pcre2_flags,
    });
    m.addCSourceFile(.{ .file = tables, .flags = &pcre2_flags });
}

const pcre2_flags = [_][]const u8{
    "-DHAVE_CONFIG_H",
    "-DPCRE2_CODE_UNIT_WIDTH=8",
    "-DPCRE2_STATIC",
    "-DSUPPORT_JIT",
};

const zstd_flags = [_][]const u8{
    "-DZSTD_LEGACY_SUPPORT=0",
    "-DZSTD_TRACE=0",
    "-DDEBUGLEVEL=0",
    // Keep xxhash's symbols out of the way of a program's own copy.
    "-DXXH_NAMESPACE=ZSTD_",
};
