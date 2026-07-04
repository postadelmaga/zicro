const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The zicro library module: the whole kernel + framework, one import.
    const zicro = b.addModule("zicro", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // stb_truetype FONT RASTERIZER (Hack regular+bold fonts embedded)
    zicro.addIncludePath(b.path("vendor/stb"));
    zicro.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_truetype_impl.c"),
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });

    // Linux-specific Wayland support
    if (target.result.os.tag == .linux) {
        zicro.linkSystemLibrary("wayland-client", .{});

        // We only need the xdg-shell stable protocol for basic windowing
        const xml = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml";
        const scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        scan.addFileArg(.{ .cwd_relative = xml });
        const c_file = scan.addOutputFileArg("protocol.c");
        zicro.addCSourceFile(.{ .file = c_file });
    }

    // macOS Cocoa windowing backend (AppKit via the ObjC runtime + CoreGraphics present).
    if (target.result.os.tag == .macos) {
        zicro.linkFramework("Cocoa", .{});
        zicro.linkFramework("QuartzCore", .{});
        zicro.linkFramework("CoreGraphics", .{});
    }

    // `zig build test` — every `test` block in the library.
    const mod_tests = b.addTest(.{ .root_module = zicro });
    const run_mod_tests = b.addRunArtifact(mod_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_mod_tests.step);

    // `zig build bench [-- --quick]` — the performance contract (always ReleaseFast).
    const zicro_fast = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .link_libc = true,
    });
    zicro_fast.addIncludePath(b.path("vendor/stb"));
    zicro_fast.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_truetype_impl.c"),
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });
    if (target.result.os.tag == .linux) {
        zicro_fast.linkSystemLibrary("wayland-client", .{});
        const xml = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml";
        const scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        scan.addFileArg(.{ .cwd_relative = xml });
        const c_file = scan.addOutputFileArg("protocol.c");
        zicro_fast.addCSourceFile(.{ .file = c_file });
    }
    if (target.result.os.tag == .macos) {
        zicro_fast.linkFramework("Cocoa", .{});
        zicro_fast.linkFramework("QuartzCore", .{});
        zicro_fast.linkFramework("CoreGraphics", .{});
    }

    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "zicro", .module = zicro_fast },
            },
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    const bench_step = b.step("bench", "Run the latency/throughput benchmarks (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    // Examples: `zig build run-counter`, `zig build run-world_counter`, `zig build run-shell`.
    inline for (.{ "counter", "world_counter", "shell" }) |name| {
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("examples/" ++ name ++ ".zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zicro", .module = zicro },
                },
            }),
        });
        b.installArtifact(exe);
        const run_cmd = b.addRunArtifact(exe);
        const run_step = b.step("run-" ++ name, "Run the " ++ name ++ " example");
        run_step.dependOn(&run_cmd.step);
    }
}
