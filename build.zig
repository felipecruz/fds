const std = @import("std");

/// The release version: `fds --version` and `fds_version()` in C.
const version = "0.0.7";

// `zig build` produces:
//   zig-out/debug/fds     (Debug: safety checks, debug info)
//   zig-out/release/fds   (ReleaseFast: production)
//   zig-out/lib/libfds.a  (ReleaseFast C library) + zig-out/include/fds.h
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const variants = [_]struct { dir: []const u8, optimize: std.builtin.OptimizeMode, strip: bool }{
        .{ .dir = "debug", .optimize = .Debug, .strip = false },
        // Stripping halves the size (450 -> 256 KB) and changes no code.
        .{ .dir = "release", .optimize = .ReleaseFast, .strip = true },
    };

    for (variants) |v| {
        const exe = b.addExecutable(.{
            .name = "fds",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = v.optimize,
                .strip = v.strip,
            }),
        });
        exe.root_module.addOptions("build_options", options);
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
    lib.bundle_compiler_rt = true;
    lib.installHeader(b.path("include/fds.h"), "fds.h");
    b.installArtifact(lib);

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
        }),
    });
    tests.root_module.addOptions("build_options", options);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
}
