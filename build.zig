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

    addNativeDeps(b, zicro, target, macos_sysroot);

    // The WebGPU device — its OWN module, not part of `zicro`.
    //
    // zicro owns the device and the window; whoever is drawing owns the frame. So the
    // wgpu binding lives here, next to the window backends —
    // that are the only things in the stack that know what a surface is made of. It is
    // a separate module because the prebuilt library is ~50 MB and nothing that does
    // not ask for a wgpu device should link a byte of it.
    //
    //   `zig build -Dwgpu` — build it and run its bring-up test.
    //
    // The browser implements the same `webgpu.h` itself, so this dependency is only the
    // DESKTOP half; `window_web.zig`'s canvas is the other.
    const want_wgpu = b.option(bool, "wgpu", "build the WebGPU device binding (links prebuilt wgpu-native)") orelse false;
    if (want_wgpu) {
        if (b.lazyDependency("wgpu_native", .{})) |wgpu_dep| {
            const wgpu = b.addModule("zicro_wgpu", .{
                .root_source_file = b.path("src/gpu_wgpu.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            wgpu.addIncludePath(wgpu_dep.path("include"));
            wgpu.addLibraryPath(wgpu_dep.path("lib"));
            wgpu.linkSystemLibrary("wgpu_native", .{});
            wgpu.addIncludePath(b.path("vendor/stb"));
            wgpu.addCSourceFile(.{
                .file = b.path("vendor/stb/stb_truetype_impl.c"),
                .flags = &.{ "-O2", "-fno-sanitize=undefined" },
            });
            if (target.result.os.tag == .linux) {
                wgpu.linkSystemLibrary("harfbuzz", .{});
            }

            const wgpu_tests = b.addTest(.{ .root_module = wgpu });
            const run_wgpu_tests = b.addRunArtifact(wgpu_tests);
            b.step("test-wgpu", "bring a WebGPU device up and ask what it can do").dependOn(&run_wgpu_tests.step);
        }
    }

    // The BROWSER form of the same binding (Zengine's issue #89): the identical module,
    // minus the prebuilt library — in a browser the implementation of webgpu.h is the
    // browser's own, supplied at link time by emcc's emdawnwebgpu port. What the module
    // cannot carry is the header's location, because it lives in the CONSUMER's emsdk
    // cache; they add it (modules stay mutable across the dependency boundary):
    //
    //     const zicro = b.dependency("zicro", .{ .target = wasm_target, .@"wgpu-browser" = true });
    //     const zw = zicro.module("zicro_wgpu_browser");
    //     zw.addSystemIncludePath(.{ .cwd_relative = <emsdk>/cache/sysroot/include });
    //     zw.addIncludePath(.{ .cwd_relative = <emsdk>/.../emdawnwebgpu_pkg/webgpu/include });
    //
    // A different NAME from the desktop module, deliberately: enabling both forms in one
    // build must not put gpu_wgpu.zig in two modules, and a consumer who imports both
    // deserves the compiler saying so with these two names in the error.
    const want_wgpu_browser = b.option(bool, "wgpu-browser", "publish the WebGPU binding without wgpu-native (emscripten form; bring the port's include paths)") orelse false;
    if (want_wgpu_browser) {
        _ = b.addModule("zicro_wgpu_browser", .{
            .root_source_file = b.path("src/gpu_wgpu.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
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
    addNativeDeps(b, zicro_fast, target, macos_sysroot);

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
    inline for (.{ "counter", "world_counter", "shell", "demo", "gallery", "monitor" }) |name| {
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

    // The Android module a dependent app (an APK's libmain.so) imports as "zicro":
    // `android_root.zig` — the CPU canvas + text + widgets + the NDK window backend, WITHOUT
    // the Wayland/ALSA/shm stack that doesn't exist on Android. The app owns the target (its
    // own ABI/api-level) and the libandroid/liblog link, so this module carries only what is
    // portable: the stb rasterizer. See Zuer's scripts/build-android-apk.sh for the packaging.
    const zicro_android = b.addModule("zicro_android", .{
        .root_source_file = b.path("src/android_root.zig"),
        .link_libc = true,
    });
    // Bionic is a real libc, so the native stb_truetype rasterizer compiles as-is (unlike
    // the wasm build). Same font path as every other platform.
    zicro_android.addIncludePath(b.path("vendor/stb"));
    zicro_android.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_truetype_impl.c"),
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });
}

/// Everything a NATIVE zicro module links: the stb rasterizer plus the per-OS platform
/// set. One function on purpose — the Debug `zicro` module and the bench's ReleaseFast
/// twin call the same code, so they cannot drift apart (the bench once silently lost
/// the PipeWire backend this way).
fn addNativeDeps(b: *std.Build, mod: *std.Build.Module, target: std.Build.ResolvedTarget, macos_sysroot: ?[]const u8) void {
    // stb_truetype FONT RASTERIZER (Hack regular+bold fonts embedded)
    mod.addIncludePath(b.path("vendor/stb"));
    mod.addCSourceFile(.{
        .file = b.path("vendor/stb/stb_truetype_impl.c"),
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });

    if (target.result.os.tag == .linux) {
        mod.linkSystemLibrary("wayland-client", .{});
        mod.linkSystemLibrary("asound", .{}); // ALSA: backend audio (audio_device.zig)
        mod.linkSystemLibrary("harfbuzz", .{}); // HarfBuzz: text shaping (src/text.zig)

        // PipeWire: low-latency audio backend, preferred over ALSA at runtime when a
        // PipeWire graph is reachable. The pull-model pw_stream is bridged to zicro's
        // blocking device contract by the audio_pw.c shim (SPA format PODs live in C).
        mod.linkSystemLibrary("libpipewire-0.3", .{}); // pkg-config: adds the include dirs too
        mod.addCSourceFile(.{
            .file = b.path("src/audio_pw.c"),
            .flags = &.{ "-O2", "-D_REENTRANT", "-fno-sanitize=undefined" },
        });

        // Wayland protocol glue, generated from the XMLs vendored in
        // vendor/wayland-protocols/ (MIT; system paths vary per distro — the appmenu
        // XML even required Qt6 dev files to be installed).
        //   xdg-shell        — basic windowing
        //   xdg-decoration   — server-side frames for windows that opt in (Options.decorations)
        //   cursor-shape-v1  — server-driven cursor themes; its get_tablet_tool_v2 request
        //                      pulls in zwp_tablet_tool_v2_interface, so tablet-v2 must be
        //                      generated too even though only the wl_pointer path is driven
        //   appmenu          — org_kde_kwin_appmenu (KDE global menu)
        //   color-representation-v1 — segnala coefficienti/range YCbCr (BT.601/709,
        //                      limited/full) su una subsurface dmabuf.
        //   color-management-v1 — segnala primari/funzione di trasferimento
        //                      (gamma/EOTF) della surface: su un compositor con
        //                      pipeline colore avanzata attiva (wp_color_manager_v1,
        //                      es. KWin recenti) un dmabuf YCbCr SENZA questo viene
        //                      trattato con un'ipotesi di colore sbagliata — visto in
        //                      pratica un crollo di luminosità severo sul percorso
        //                      zero-copy VAAPI di Zuer (ZUER_VAAPI_DMABUF), risolto
        //                      solo dichiarando ANCHE questo (non basta
        //                      color-representation da solo: confrontato via
        //                      WAYLAND_DEBUG col trace di mpv --vo=dmabuf-wayland,
        //                      che su questo stesso compositor mostra il video giusto
        //                      e usa entrambi i protocolli insieme).
        // The last six are consumed by zrame's backend (compositor blur, dmabuf video,
        // HiDPI viewport/fractional scale): ALL interface tables are generated here, in
        // one repo, because zrame links this module's C objects — a table generated in
        // both repos collides at link time.
        const protocols = [_][2][]const u8{
            .{ "xdg-shell.xml", "xdg-shell.c" },
            .{ "xdg-decoration-unstable-v1.xml", "xdg-decoration.c" },
            .{ "cursor-shape-v1.xml", "cursor-shape-v1.c" },
            .{ "tablet-v2.xml", "tablet-v2.c" },
            .{ "appmenu.xml", "appmenu.c" },
            .{ "ext-background-effect-v1.xml", "ext-background-effect-v1.c" },
            .{ "linux-dmabuf-v1.xml", "linux-dmabuf-v1.c" },
            .{ "viewporter.xml", "viewporter.c" },
            .{ "fractional-scale-v1.xml", "fractional-scale-v1.c" },
            .{ "text-input-v3.xml", "text-input-v3.c" },
            .{ "color-representation-v1.xml", "color-representation-v1.c" },
            .{ "color-management-v1.xml", "color-management-v1.c" },
        };
        for (protocols) |p| {
            const scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
            scan.addFileArg(b.path(b.pathJoin(&.{ "vendor", "wayland-protocols", p[0] })));
            mod.addCSourceFile(.{ .file = scan.addOutputFileArg(p[1]) });
        }
    }

    // winmm: backend audio waveOut (audio_device.zig) on Windows.
    if (target.result.os.tag == .windows) mod.linkSystemLibrary("winmm", .{});

    // macOS Cocoa windowing backend (AppKit via the ObjC runtime + CoreGraphics present).
    // Only libobjc and the CG functions are needed at LINK time — AppKit classes resolve
    // by name at runtime (objc_getClass), Cocoa is linked for its load command alone.
    // Without a sysroot the vendored .tbd stubs make the link SDK-free (the zig way:
    // zig itself links libSystem from a bundled stub).
    if (target.result.os.tag == .macos) addMacosLinks(b, mod, macos_sysroot);
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
    // AppKit DIRETTO e PRIMA dell'umbrella Cocoa: `NSApp` vive in AppKit e il
    // two-level namespace binda il simbolo alla PRIMA dylib vista al link che lo
    // esporta. Bindarlo ad AppKit è corretto su macOS reale e necessario sotto
    // Darling, il cui umbrella Cocoa non ri-esporta i simboli di AppKit (exports
    // trie vuoto) → col bind a Cocoa dyld fallirebbe con "Symbol not found: _NSApp".
    mod.linkFramework("AppKit", .{});
    mod.linkFramework("Cocoa", .{});
    mod.linkFramework("CoreGraphics", .{});
}
