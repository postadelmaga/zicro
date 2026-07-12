const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Cross-linking to macOS without an Apple SDK: a root that mirrors the macOS
    // filesystem layout (System/Library/Frameworks + usr/lib), e.g. Darling's
    // /usr/libexec/darling. The frameworks there are real Mach-O dylibs, so the
    // linker consumes them directly.
    const macos_sysroot = b.option([]const u8, "macos-sysroot", "macOS-shaped root (System/Library/Frameworks, usr/lib) for cross-linking, e.g. /usr/libexec/darling");

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
        zicro.linkSystemLibrary("asound", .{}); // ALSA: backend audio (audio_device.zig)

        // We only need the xdg-shell stable protocol for basic windowing
        const xml = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml";
        const scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        scan.addFileArg(.{ .cwd_relative = xml });
        const c_file = scan.addOutputFileArg("protocol.c");
        zicro.addCSourceFile(.{ .file = c_file });
        // xdg-decoration: server-side window frames (title bar, close/min/max
        // from the compositor) for windows that opt in via Options.decorations.
        const deco_xml = "/usr/share/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml";
        const deco_scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        deco_scan.addFileArg(.{ .cwd_relative = deco_xml });
        const deco_c = deco_scan.addOutputFileArg("xdg-decoration.c");
        zicro.addCSourceFile(.{ .file = deco_c });
        // cursor-shape-v1: server-driven cursor themes (wl.zig/window_wayland.zig).
        // Its get_tablet_tool_v2 request pulls in zwp_tablet_tool_v2_interface, so
        // tablet-v2's private-code must be linked too even though we only drive the
        // wl_pointer path — otherwise that interface symbol stays undefined.
        const cursor_xml = "/usr/share/wayland-protocols/staging/cursor-shape/cursor-shape-v1.xml";
        const cursor_scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        cursor_scan.addFileArg(.{ .cwd_relative = cursor_xml });
        const cursor_c = cursor_scan.addOutputFileArg("cursor-shape-v1.c");
        zicro.addCSourceFile(.{ .file = cursor_c });
        const tablet_xml = "/usr/share/wayland-protocols/stable/tablet/tablet-v2.xml";
        const tablet_scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        tablet_scan.addFileArg(.{ .cwd_relative = tablet_xml });
        const tablet_c = tablet_scan.addOutputFileArg("tablet-v2.c");
        zicro.addCSourceFile(.{ .file = tablet_c });

        const appmenu_xml = "/usr/share/qt6/wayland/protocols/appmenu/appmenu.xml";
        const appmenu_scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        appmenu_scan.addFileArg(.{ .cwd_relative = appmenu_xml });
        const appmenu_c = appmenu_scan.addOutputFileArg("appmenu.c");
        zicro.addCSourceFile(.{ .file = appmenu_c });
    }
    // winmm: backend audio waveOut (audio_device.zig) su Windows.
    if (target.result.os.tag == .windows) zicro.linkSystemLibrary("winmm", .{});

    // macOS Cocoa windowing backend (AppKit via the ObjC runtime + CoreGraphics present).
    // Only libobjc and the CG functions are needed at LINK time — AppKit classes resolve
    // by name at runtime (objc_getClass), Cocoa is linked for its load command alone.
    // Without a sysroot the vendored .tbd stubs make the link SDK-free (the zig way:
    // zig itself links libSystem from a bundled stub).
    if (target.result.os.tag == .macos) addMacosLinks(b, zicro, macos_sysroot);

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
        zicro_fast.linkSystemLibrary("asound", .{});
        const xml = "/usr/share/wayland-protocols/stable/xdg-shell/xdg-shell.xml";
        const scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        scan.addFileArg(.{ .cwd_relative = xml });
        const c_file = scan.addOutputFileArg("protocol.c");
        zicro_fast.addCSourceFile(.{ .file = c_file });
        const deco_xml = "/usr/share/wayland-protocols/unstable/xdg-decoration/xdg-decoration-unstable-v1.xml";
        const deco_scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        deco_scan.addFileArg(.{ .cwd_relative = deco_xml });
        const deco_c = deco_scan.addOutputFileArg("xdg-decoration.c");
        zicro_fast.addCSourceFile(.{ .file = deco_c });
        // cursor-shape-v1 (+ tablet-v2 for zwp_tablet_tool_v2_interface); see the
        // Debug block above for why both are needed.
        const cursor_xml = "/usr/share/wayland-protocols/staging/cursor-shape/cursor-shape-v1.xml";
        const cursor_scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        cursor_scan.addFileArg(.{ .cwd_relative = cursor_xml });
        const cursor_c = cursor_scan.addOutputFileArg("cursor-shape-v1.c");
        zicro_fast.addCSourceFile(.{ .file = cursor_c });
        const tablet_xml = "/usr/share/wayland-protocols/stable/tablet/tablet-v2.xml";
        const tablet_scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        tablet_scan.addFileArg(.{ .cwd_relative = tablet_xml });
        const tablet_c = tablet_scan.addOutputFileArg("tablet-v2.c");
        zicro_fast.addCSourceFile(.{ .file = tablet_c });

        const appmenu_xml = "/usr/share/qt6/wayland/protocols/appmenu/appmenu.xml";
        const appmenu_scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
        appmenu_scan.addFileArg(.{ .cwd_relative = appmenu_xml });
        const appmenu_c = appmenu_scan.addOutputFileArg("appmenu.c");
        zicro_fast.addCSourceFile(.{ .file = appmenu_c });
    }
    if (target.result.os.tag == .windows) zicro_fast.linkSystemLibrary("winmm", .{});
    if (target.result.os.tag == .macos) addMacosLinks(b, zicro_fast, macos_sysroot);

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
    inline for (.{ "counter", "world_counter", "shell", "demo", "gallery" }) |name| {
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

    // `zig build web` — the WebAssembly build: the CPU canvas in a browser tab.
    // wasm32-freestanding, no libc, no C: a dedicated minimal `zicro` module that
    // exposes only `paint` (the full root's threads/Io/Wayland don't exist on wasm).
    // Emits zig-out/web/{zicro.wasm,index.html}; `serve` that dir and open it.
    {
        const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
        const web_zicro = b.createModule(.{
            .root_source_file = b.path("src/web_root.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });
        // stb_truetype for wasm: the web C shim predefines the STBTT_* hooks (no libc
        // headers) and routes malloc/libm to the Zig shims in wasm_shim.zig.
        web_zicro.addIncludePath(b.path("vendor/stb"));
        web_zicro.addCSourceFile(.{
            .file = b.path("vendor/stb/stb_truetype_web.c"),
            .flags = &.{ "-O2", "-fno-sanitize=undefined" },
        });
        const web_mod = b.createModule(.{
            .root_source_file = b.path("examples/web_demo.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "zicro", .module = web_zicro }},
        });
        const web_exe = b.addExecutable(.{ .name = "zicro", .root_module = web_mod });
        web_exe.entry = .disabled; // no _start: JS drives the exported functions
        web_exe.rdynamic = true; //    keep the exports (zicroFrame, zicroPointer, …)
        const install_wasm = b.addInstallArtifact(web_exe, .{
            .dest_dir = .{ .override = .{ .custom = "web" } },
        });
        const copy_html = b.addInstallFileWithDir(b.path("web/index.html"), .{ .custom = "web" }, "index.html");
        const web_step = b.step("web", "Build the WebAssembly canvas demo into zig-out/web");
        web_step.dependOn(&install_wasm.step);
        web_step.dependOn(&copy_html.step);
    }

    // `zig build android` — compile-check the NDK NativeActivity backend for
    // aarch64-linux-android (issue #9). A build-obj: it verifies window_android.zig type-
    // checks and codegens for the target; the libandroid link + APK packaging is #10.
    {
        const android_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android });
        const and_mod = b.createModule(.{
            .root_source_file = b.path("src/android_check.zig"),
            .target = android_target,
            .optimize = .ReleaseSmall,
        });
        const and_obj = b.addObject(.{ .name = "zicro-android", .root_module = and_mod });
        const android_step = b.step("android", "Compile-check the Android (NDK) backend for aarch64-linux-android");
        android_step.dependOn(&and_obj.step);
    }
}

/// The macOS link set for a module: libobjc + Cocoa (load command) + CoreGraphics.
/// `sysroot` (a macOS-shaped tree, e.g. Darling's /usr/libexec/darling) overrides the
/// vendored .tbd stubs — those keep the default cross-link SDK-free.
fn addMacosLinks(b: *std.Build, mod: *std.Build.Module, sysroot: ?[]const u8) void {
    if (sysroot) |root| {
        mod.addFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ root, "System", "Library", "Frameworks" }) });
        mod.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ root, "usr", "lib" }) });
    } else {
        mod.addFrameworkPath(b.path("vendor/macos-stubs/System/Library/Frameworks"));
        mod.addLibraryPath(b.path("vendor/macos-stubs/usr/lib"));
    }
    mod.linkSystemLibrary("objc", .{});
    mod.linkFramework("Cocoa", .{});
    mod.linkFramework("CoreGraphics", .{});
}
