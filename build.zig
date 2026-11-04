const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Cross-linking to macOS without an Apple SDK: a root that mirrors the macOS
    // filesystem layout (System/Library/Frameworks + usr/lib), e.g. Darling's
    // /usr/libexec/darling. The frameworks there are real Mach-O dylibs, so the
    // linker consumes them directly.
    const macos_sysroot = b.option([]const u8, "macos-sysroot", "macOS-shaped root (System/Library/Frameworks, usr/lib) for cross-linking, e.g. /usr/libexec/darling");

    // One `text_c` module per (target, optimize, flavor): modules that agree on all three
    // share it (and its single stb object) instead of each re-translating hb.h. Modules
    // that differ in optimize mode keep their own — the translation is NOT identical
    // across modes (ReleaseFast's carries `NDEBUG`), so merging them would change it.
    var text_c: TextCCache = .{ .b = b };

    // The zicro library module: the whole kernel + framework, one import.
    const zicro = b.addModule("zicro", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    addNativeDeps(b, &text_c, zicro, target, macos_sysroot);

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
            // webgpu.h come modulo (0.17 ha rimosso `@cImport`): qui l'header lo
            // porta la dipendenza prebuilt, quindi lo step lo crea Zicro.
            const wgpu_c = b.addTranslateC(.{
                .root_source_file = b.path("src/c/webgpu.h"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            });
            wgpu_c.addIncludePath(wgpu_dep.path("include"));
            wgpu.addImport("webgpu_c", wgpu_c.createModule());
            wgpu.addIncludePath(wgpu_dep.path("include"));
            // gpu_wgpu.zig arriva a text.zig via paint_gl.zig: serve anche il suo
            // modulo C, che porta con sé stb e (dove c'è) HarfBuzz — una volta sola.
            text_c.attach(wgpu, target, optimize, .native);
            wgpu.addLibraryPath(wgpu_dep.path("lib"));
            wgpu.linkSystemLibrary("wgpu_native", .{});

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
    // Da Zig 0.17 (niente più `@cImport`) il consumatore deve anche TRADURRE
    // l'header, perché gli include path di un modulo non guidano la traduzione.
    // Lo step va creato sul builder della dipendenza, così `src/c/webgpu.h` si
    // risolve rispetto a questa radice:
    //
    //     const zb = zicro.builder;
    //     const wc = zb.addTranslateC(.{ .root_source_file = zb.path("src/c/webgpu.h"),
    //         .target = wasm_target, .optimize = optimize, .link_libc = true });
    //     wc.addSystemIncludePath(.{ .cwd_relative = <emsdk>/cache/sysroot/include });
    //     wc.addIncludePath(.{ .cwd_relative = <emsdk>/.../emdawnwebgpu_pkg/webgpu/include });
    //     zw.addImport("webgpu_c", wc.createModule());
    //
    // A different NAME from the desktop module, deliberately: enabling both forms in one
    // build must not put gpu_wgpu.zig in two modules, and a consumer who imports both
    // deserves the compiler saying so with these two names in the error.
    const want_wgpu_browser = b.option(bool, "wgpu-browser", "publish the WebGPU binding without wgpu-native (emscripten form; bring the port's include paths)") orelse false;
    if (want_wgpu_browser) {
        const wgpu_browser = b.addModule("zicro_wgpu_browser", .{
            .root_source_file = b.path("src/gpu_wgpu.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        // Come la forma desktop: text.zig è raggiungibile via paint_gl.zig.
        // webgpu.h invece lo traduce il consumatore (vedi il commento sopra).
        text_c.attach(wgpu_browser, target, optimize, .native);
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
    addNativeDeps(b, &text_c, zicro_fast, target, macos_sysroot);

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
    run_bench.addPassthruArgs();
    const bench_step = b.step("bench", "Run the latency/throughput benchmarks (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    // Examples: `zig build run-counter`, `zig build run-world_counter`, `zig build run-shell`.
    inline for (.{ "counter", "world_counter", "shell", "demo", "gallery", "monitor", "multiwindow" }) |name| {
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
        text_c.attach(web_zicro, wasm_target, .small, .web);
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
    // own ABI/api-level) and the libandroid/liblog link, so this module has no target here —
    // and therefore no `text_c` yet: the CONSUMER attaches it, with the same function this
    // build uses, from its own build.zig (a dependency's build.zig IS importable):
    //
    //     const zicro_build = @import("zicro");
    //     const ndk = b.option([]const u8, "ndk", "Android NDK path") orelse ""; // explicit
    //     _ = zicro_build.addTextCAndroid(dep.builder, dep.module("zicro_android"),
    //         android_target, optimize, ndk, 24);
    //
    // That brings the stb rasterizer (bionic is a real libc, so the native one compiles
    // as-is) and leaves HarfBuzz out, exactly as `Features` decides for Android.
    // See Zuer's build.zig for the live call, scripts/build-android-apk.sh for packaging.
    _ = b.addModule("zicro_android", .{
        .root_source_file = b.path("src/android_root.zig"),
        .link_libc = true,
    });

    addCheckZ(b, &text_c, target, optimize);
    addZrame(b, &text_c, zicro, target, optimize, test_step);
}

/// zrame — the window layer (glass chrome, panels, menus, tray, IME) — lives in this
/// repository under `zrame/` and is published from this package as the `zrame` module,
/// importing THIS build's `zicro`: one zicro instance per consumer, no second package to
/// keep in step. A consumer that wants the window layer does
///
///     const zicro_dep = b.dependency("zicro", .{ .target = target, .optimize = optimize });
///     exe.root_module.addImport("zrame", zicro_dep.module("zrame"));
///
/// and takes the web/Android roots from `zicro_dep.builder.path("zrame/src/...")`.
fn addZrame(
    b: *std.Build,
    text_c: *TextCCache,
    zicro: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    test_step: *std.Build.Step,
) void {
    const zrame = b.addModule("zrame", .{
        .root_source_file = b.path("zrame/src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zicro", .module = zicro }},
    });
    // On Linux the Wayland transport is zicro's window (linked with `zicro`); zrame adds
    // the desktop integrations. On Windows zrame still owns a native GDI window.
    if (target.result.os.tag == .linux and target.result.abi != .android) {
        // Tray (StatusNotifierItem) over sd-bus; FFI hand-declared, so only the library.
        zrame.linkSystemLibrary("systemd", .{ .use_pkg_config = .no });
    } else if (target.result.os.tag == .windows) {
        zrame.linkSystemLibrary("user32", .{});
        // GDI: the DIB section + memory DC behind the layered-window glass presentation.
        zrame.linkSystemLibrary("gdi32", .{});
    }

    // Its tests run with zicro's: `zig build test` covers both modules.
    const zrame_tests = b.addTest(.{ .root_module = zrame });
    test_step.dependOn(&b.addRunArtifact(zrame_tests).step);

    // Examples: `zig build run-hello`, `run-frames`, … `tray`, `menu` and `runtime` drive
    // Linux-desktop-only surfaces (StatusNotifierItem, KDE global menu, the Wayland poll
    // loop), so they build on Linux only.
    const Example = struct {
        fn add(bb: *std.Build, t: std.Build.ResolvedTarget, o: std.builtin.OptimizeMode, zr: *std.Build.Module, zi: *std.Build.Module, comptime name: []const u8) void {
            const exe = bb.addExecutable(.{
                .name = name,
                .root_module = bb.createModule(.{
                    .root_source_file = bb.path("zrame/examples/" ++ name ++ ".zig"),
                    .target = t,
                    .optimize = o,
                    .imports = &.{
                        .{ .name = "zrame", .module = zr },
                        .{ .name = "zicro", .module = zi },
                    },
                }),
            });
            bb.installArtifact(exe);
            const run_step = bb.step("run-" ++ name, "Run the zrame " ++ name ++ " example");
            run_step.dependOn(&bb.addRunArtifact(exe).step);
        }
    };
    const desktop_linux = target.result.os.tag == .linux and target.result.abi != .android;
    inline for (.{ "hello", "frames", "scroll", "widgets" }) |name| Example.add(b, target, optimize, zrame, zicro, name);
    if (desktop_linux) {
        inline for (.{ "tray", "menu", "runtime" }) |name| Example.add(b, target, optimize, zrame, zicro, name);

        // A loadable plugin built as a shared library, plus a host that dlopens it:
        // `zig build run-plugin` (the host hardcodes a `.so` path: Linux only).
        const clock = b.addLibrary(.{
            .name = "zrame_clock",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("zrame/examples/plugin_clock.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zrame", .module = zrame }},
            }),
        });
        b.installArtifact(clock);
        const host_exe = b.addExecutable(.{
            .name = "plugin_host",
            .root_module = b.createModule(.{
                .root_source_file = b.path("zrame/examples/plugin_host.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "zrame", .module = zrame }},
            }),
        });
        b.installArtifact(host_exe);
        const host_run = b.addRunArtifact(host_exe);
        host_run.step.dependOn(b.getInstallStep()); // it dlopens zig-out/lib/libzrame_clock.so
        host_run.addPassthruArgs();
        b.step("run-plugin", "Run the zrame dlopen plugin host example").dependOn(&host_run.step);
    }

    // `zig build web-zrame` — the glass window in a browser tab: zicro's web root (paint +
    // text + the web Window backend) under zrame's web root (chrome + panels).
    {
        const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
        const zicro_web = b.createModule(.{
            .root_source_file = b.path("src/web_root.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });
        text_c.attach(zicro_web, wasm_target, .small, .web);
        const zrame_web = b.createModule(.{
            .root_source_file = b.path("zrame/src/web_root.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "zicro", .module = zicro_web }},
        });
        const web_exe = b.addExecutable(.{ .name = "zrame", .root_module = b.createModule(.{
            .root_source_file = b.path("zrame/examples/web.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "zrame", .module = zrame_web }},
        }) });
        web_exe.entry = .disabled;
        web_exe.rdynamic = true;
        const web_step = b.step("web-zrame", "Build the zrame WebAssembly glass-window demo into zig-out/web-zrame");
        web_step.dependOn(&b.addInstallArtifact(web_exe, .{ .dest_dir = .{ .override = .{ .custom = "web-zrame" } } }).step);
        web_step.dependOn(&b.addInstallFileWithDir(b.path("zrame/web/index.html"), .{ .custom = "web-zrame" }, "index.html").step);
    }

    // `zig build android-zrame -Dndk=<path>` — compile-check zrame's Android backend for
    // aarch64-linux-android against zicro's Android root (stb from the NDK's bionic headers;
    // the NDK path is explicit — Zig 0.17's configure cache does not track the environment).
    {
        const android_target = b.resolveTargetQuery(.{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .android });
        const zicro_android = b.createModule(.{
            .root_source_file = b.path("src/android_root.zig"),
            .target = android_target,
            .optimize = .ReleaseSmall,
        });
        const ndk = b.option([]const u8, "ndk", "Android NDK path (required by `zig build android-zrame`)") orelse "";
        _ = addTextCAndroid(b, zicro_android, android_target, .small, ndk, 24);
        const and_obj = b.addObject(.{ .name = "zrame-android", .root_module = b.createModule(.{
            .root_source_file = b.path("zrame/src/android_check.zig"),
            .target = android_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "zicro", .module = zicro_android }},
        }) });
        b.step("android-zrame", "Compile-check zrame's Android backend for aarch64-linux-android (-Dndk=<path>)").dependOn(&and_obj.step);
    }
}

/// Everything a NATIVE zicro module links: the stb rasterizer plus the per-OS platform
/// set. One function on purpose — the Debug `zicro` module and the bench's ReleaseFast
/// twin call the same code, so they cannot drift apart (the bench once silently lost
/// the PipeWire backend this way).
fn addNativeDeps(b: *std.Build, text_c: *TextCCache, mod: *std.Build.Module, target: std.Build.ResolvedTarget, macos_sysroot: ?[]const u8) void {
    const features = Features.of(target.result);
    // stb_truetype FONT RASTERIZER (Hack regular+bold fonts embedded) + HarfBuzz where
    // the target has it: both travel inside the text_c module.
    text_c.attach(mod, target, mod.optimize orelse .debug, .native);

    if (features.alsa) mod.linkSystemLibrary("asound", .{}); // ALSA: backend audio (audio_device.zig)
    if (features.pipewire) {
        // PipeWire: low-latency audio backend, preferred over ALSA at runtime when a
        // PipeWire graph is reachable. The pull-model pw_stream is bridged to zicro's
        // blocking device contract by the audio_pw.c shim (SPA format PODs live in C).
        mod.linkSystemLibrary("libpipewire-0.3", .{}); // pkg-config: adds the include dirs too
        mod.addCSourceFile(.{
            .file = b.path("src/audio_pw.c"),
            .flags = &.{ "-O2", "-D_REENTRANT", "-fno-sanitize=undefined" },
        });
    }

    if (features.wayland) {
        mod.linkSystemLibrary("wayland-client", .{});
        // evdev code + compositor keymap → UTF-8 text and the key-repeat table of the
        // Wayland window (FFI hand-declared in src/xkb.zig).
        mod.linkSystemLibrary("xkbcommon", .{});
        // Wayland protocol glue, generated from the XMLs vendored in
        // vendor/wayland-protocols/ (MIT; system paths vary per distro — the appmenu
        // XML even required Qt6 dev files to be installed).
        //   xdg-shell        — basic windowing
        //   xdg-decoration   — server-side frames for windows that opt in (Options.decorations)
        //   cursor-shape-v1  — server-driven cursor themes; its get_tablet_tool_v2 request
        //                      pulls in zwp_tablet_tool_v2_interface, so tablet-v2 must be
        //                      generated too even though only the wl_pointer path is driven
        //   appmenu          — org_kde_kwin_appmenu (KDE global menu)
        // The last four are consumed by zrame's backend (compositor blur, dmabuf video,
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
        };
        for (protocols) |p| {
            const scan = b.addSystemCommand(&.{ "wayland-scanner", "private-code" });
            scan.addFileArg(b.path(b.pathJoin(&.{ "vendor", "wayland-protocols", p[0] })));
            mod.addCSourceFile(.{ .file = scan.addOutputFileArg(p[1]) });
        }
    }

    // winmm: backend audio waveOut (audio_device.zig) on Windows.
    if (features.winmm) mod.linkSystemLibrary("winmm", .{});

    // macOS Cocoa windowing backend (AppKit via the ObjC runtime + CoreGraphics present).
    // Only libobjc and the CG functions are needed at LINK time — AppKit classes resolve
    // by name at runtime (objc_getClass), Cocoa is linked for its load command alone.
    // Without a sysroot the vendored .tbd stubs make the link SDK-free (the zig way:
    // zig itself links libSystem from a bundled stub).
    if (features.cocoa) addMacosLinks(b, mod, macos_sysroot);
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

/// Which optional native libraries a target links — the ONE place these decisions live.
///
/// Every target-conditional dependency in this file asks here, and `src/text.zig` does not
/// decide anything itself (it only asks whether the translated header declares HarfBuzz),
/// so the build and the code cannot drift apart again. Android is `os.tag == .linux` but
/// none of the desktop-Linux stack exists there (no Wayland, ALSA, PipeWire or system
/// HarfBuzz in the NDK): testing `os.tag == .linux` alone used to link all four into an
/// Android build of `zicro` while text.zig had already turned HarfBuzz off.
pub const Features = struct {
    harfbuzz: bool,
    wayland: bool,
    alsa: bool,
    pipewire: bool,
    winmm: bool,
    cocoa: bool,

    pub fn of(t: std.Target) Features {
        const desktop_linux = t.os.tag == .linux and !t.abi.isAndroid();
        return .{
            .harfbuzz = desktop_linux,
            .wayland = desktop_linux,
            .alsa = desktop_linux,
            .pipewire = desktop_linux,
            .winmm = t.os.tag == .windows,
            .cocoa = t.os.tag == .macos,
        };
    }
};

/// Which stb_truetype implementation the text module compiles: the libc-backed one (every
/// native target, Android/bionic included) or the wasm shim (no libc headers; malloc and
/// libm routed to `wasm_shim.zig`).
pub const TextCFlavor = enum { native, web };

/// The C half of `src/text.zig`, as one self-contained module imported as "text_c":
/// the translated headers (stb_truetype + HarfBuzz where `Features` says so), the stb
/// implementation object, and the HarfBuzz link. Everything text.zig needs from C travels
/// together, so no caller can add the header without the object or the link (or add the
/// object twice).
///
/// Zig 0.17 removed `@cImport`, hence the build step. Public on purpose: a CONSUMER whose
/// module has no target until it picks one (`zicro_android`) calls it from its own
/// build.zig with `@import("zicro").addTextC(dep.builder, …)` — a dependency's build.zig
/// is importable — and adds target-specific include paths (an NDK's per-arch headers)
/// where they are needed: on `step` for the translation, on `module` for the stb object.
pub fn addTextC(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    flavor: TextCFlavor,
) TextC {
    const made = makeTextC(b, target, optimize, flavor);
    mod.addImport("text_c", made.module);
    return made;
}

/// [`addTextC`] for an ANDROID consumer, wired against an NDK — the one place that knows
/// where bionic's headers live, so every app that ships zicro on Android (Zuer, Zrame,
/// ZenFlow2) uses the same code instead of a copy of it:
/// * `<ndk>/toolchains/llvm/prebuilt/<host>/sysroot/usr/include` and its per-arch
///   subdirectory (asm/*.h) on both the translation and the stb compile;
/// * `__ANDROID_API__` / `__ANDROID_MIN_SDK_VERSION__` = `api_level`.
///
/// `ndk` is an explicit path — take it from a `-Dndk` option, never from the environment:
/// Zig 0.17's configure cache does NOT see environment reads (an `ANDROID_NDK_HOME`
/// changed or unset after a build reuses the old configuration — reproduced), while a
/// changed `-D` option re-configures. An empty path fails the build asking for `-Dndk`; a
/// path that is not an NDK fails it naming the missing bionic header, instead of a
/// missing `math.h` deep in stb.
pub fn addTextCAndroid(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ndk: []const u8,
    api_level: u32,
) TextC {
    const tc = addTextC(b, mod, target, optimize, .native);
    const host_tag = switch (b.graph.host.result.os.tag) {
        .macos => "darwin-x86_64", // the NDK ships x86_64 prebuilts for both Mac kinds
        .windows => "windows-x86_64",
        else => "linux-x86_64",
    };
    const inc = b.pathJoin(&.{ ndk, "toolchains", "llvm", "prebuilt", host_tag, "sysroot", "usr", "include" });
    const arch_dir: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "aarch64-linux-android",
        .x86_64 => "x86_64-linux-android",
        .arm, .thumb => "arm-linux-androideabi",
        .x86 => "i686-linux-android",
        else => @panic("addTextCAndroid: not an Android NDK architecture"),
    };
    if (ndk.len == 0) {
        tc.step.step.dependOn(&b.addFail("Android NDK path missing: pass -Dndk=<path to the NDK>").step);
        return tc;
    }
    // Checked when the build RUNS, not while configuring (a configure-time probe of the
    // filesystem would be cached like an environment read): copying bionic's stdlib.h
    // fails, naming the path, when `ndk` is not an NDK.
    const probe = b.addWriteFiles();
    _ = probe.addCopyFile(.{ .cwd_relative = b.pathJoin(&.{ inc, "stdlib.h" }) }, "ndk-check/stdlib.h");
    tc.step.step.dependOn(&probe.step);
    tc.addIncludePath(.{ .cwd_relative = inc });
    tc.addIncludePath(.{ .cwd_relative = b.pathJoin(&.{ inc, arch_dir }) });
    const api = b.fmt("{d}", .{api_level});
    tc.defineCMacro("__ANDROID_API__", api);
    tc.defineCMacro("__ANDROID_MIN_SDK_VERSION__", api);
    return tc;
}

/// What [`addTextC`] made: the translate-c step and the module (translated headers + the
/// stb object + the HarfBuzz link) it imported as "text_c".
pub const TextC = struct {
    step: *std.Build.Step.TranslateC,
    module: *std.Build.Module,

    /// Add an include directory to both the translation and the C compile (e.g. an NDK's
    /// per-architecture headers, which neither finds on its own).
    pub fn addIncludePath(tc: TextC, path: std.Build.LazyPath) void {
        tc.step.addIncludePath(path);
        tc.module.addIncludePath(path);
    }

    /// Define a C macro for both the translation and the C compile.
    pub fn defineCMacro(tc: TextC, name: []const u8, value: ?[]const u8) void {
        tc.step.defineCMacro(name, value);
        tc.module.addCMacro(name, value orelse "1");
    }
};

fn makeTextC(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, flavor: TextCFlavor) TextC {
    const features = Features.of(target.result);
    const step = b.addTranslateC(.{
        .root_source_file = b.path("src/c/text.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = flavor == .native,
    });
    step.addIncludePath(b.path("vendor/stb"));
    if (features.harfbuzz) {
        step.defineCMacro("ZICRO_HAVE_HARFBUZZ", "1");
        step.linkSystemLibrary("harfbuzz", .{}); // pkg-config brings hb.h's include dir
    }
    const module = step.createModule();
    module.addIncludePath(b.path("vendor/stb"));
    module.addCSourceFile(.{
        .file = b.path(switch (flavor) {
            .native => "vendor/stb/stb_truetype_impl.c",
            .web => "vendor/stb/stb_truetype_web.c",
        }),
        .flags = &.{ "-O2", "-fno-sanitize=undefined" },
    });
    if (features.harfbuzz) module.linkSystemLibrary("harfbuzz", .{}); // HarfBuzz: text shaping
    return .{ .step = step, .module = module };
}

/// This build's own `text_c` modules, one per (target, optimize, flavor) — see `build()`.
const TextCCache = struct {
    b: *std.Build,
    entries: [8]struct { triple: []const u8, optimize: std.builtin.OptimizeMode, flavor: TextCFlavor, module: *std.Build.Module } = undefined,
    len: usize = 0,

    fn attach(cache: *TextCCache, mod: *std.Build.Module, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, flavor: TextCFlavor) void {
        const triple = target.result.zigTriple(cache.b.allocator) catch @panic("OOM");
        for (cache.entries[0..cache.len]) |e| {
            if (e.optimize == optimize and e.flavor == flavor and std.mem.eql(u8, e.triple, triple)) {
                mod.addImport("text_c", e.module);
                return;
            }
        }
        const made = makeTextC(cache.b, target, optimize, flavor);
        cache.entries[cache.len] = .{ .triple = triple, .optimize = optimize, .flavor = flavor, .module = made.module };
        cache.len += 1;
        mod.addImport("text_c", made.module);
    }
};

/// `zig build check-z [-Dz-src=<path>]` — keep the Z-Scenic backend honest without booting
/// Z. `window_z.zig` is compiled by no other step (only Z's own build pulls it in, through
/// `-Dzicro-src`), so it used to rot unseen. Against the REAL Z sources (no stubs):
/// 1. the host tests of the protocol client and the generic window backend, built over
///    Z's own `user/scenic/protocol.zig` (scripted fake server: handshake, events during
///    a request, close, resize, refusals, leaks);
/// 2. `examples/shell_z.zig` compiled for Z's userspace target exactly the way Z's
///    build.zig wires it ("zicro" + "zrt" + "scenic_protocol" + "zfont").
/// The Z repo is found at `../Z` unless `-Dz-src` says otherwise.
fn addCheckZ(b: *std.Build, text_c: *TextCCache, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) void {
    const step = b.step("check-z", "Test the Z-Scenic backend and compile shell_z against a Z checkout (-Dz-src, default ../Z)");
    const z_src: ?[]const u8 = b.option([]const u8, "z-src", "Path to the Z repo for check-z (default: ../Z if it exists)") orelse blk: {
        const guess = b.root.joinString(b.allocator, "../Z") catch @panic("OOM");
        std.Io.Dir.cwd().access(b.graph.io, b.pathJoin(&.{ guess, "user", "scenic", "protocol.zig" }), .{}) catch break :blk null;
        break :blk guess;
    };
    const z = z_src orelse {
        step.dependOn(&b.addFail("check-z needs a Z checkout: pass -Dz-src=<path>").step);
        return;
    };
    const zp = struct {
        fn path(bb: *std.Build, root: []const u8, rel: []const u8) std.Build.LazyPath {
            return .{ .cwd_relative = bb.pathJoin(&.{ root, rel }) };
        }
    }.path;

    // 1. host tests over the real protocol module
    const host_proto = b.createModule(.{ .root_source_file = zp(b, z, "user/scenic/protocol.zig"), .target = target, .optimize = optimize });
    const host_mod = b.createModule(.{
        .root_source_file = b.path("src/scenic_window.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    host_mod.addImport("scenic_protocol", host_proto);
    text_c.attach(host_mod, target, optimize, .native);
    step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = host_mod })).step);

    // 2. the real Z userspace build of the shell, minus the link (Z's crt and linker
    //    script are its own business; type-checking and codegen are ours).
    const zt = b.resolveTargetQuery(blk: {
        const F = std.Target.x86.Feature;
        var sub = std.Target.Cpu.Feature.Set.empty;
        for ([_]F{ .mmx, .sse, .sse2, .sse3, .ssse3, .sse4_1, .sse4_2, .avx, .avx2 }) |f| sub.addFeature(@backingInt(f));
        var add = std.Target.Cpu.Feature.Set.empty;
        add.addFeature(@backingInt(F.soft_float));
        break :blk .{ .cpu_arch = .x86_64, .os_tag = .freestanding, .abi = .none, .cpu_features_sub = sub, .cpu_features_add = add };
    });
    const zrt = b.createModule(.{ .root_source_file = zp(b, z, "user/rt.zig") });
    const z_proto = b.createModule(.{ .root_source_file = zp(b, z, "user/scenic/protocol.zig") });
    const zicro_pkg = b.createModule(.{ .root_source_file = b.path("src/root.zig") });
    zicro_pkg.addImport("zrt", zrt);
    zicro_pkg.addImport("scenic_protocol", z_proto);
    const shell = b.createModule(.{
        .root_source_file = b.path("examples/shell_z.zig"),
        .target = zt,
        .optimize = .safe,
        .single_threaded = true,
        .pic = true,
    });
    shell.addImport("zrt", zrt);
    shell.addImport("zicro", zicro_pkg);
    shell.addImport("zfont", b.createModule(.{ .root_source_file = zp(b, z, "user/font.zig") }));
    const obj = b.addObject(.{ .name = "zicro_shell_z", .root_module = shell });
    step.dependOn(&obj.step);
}
