//! Compile-check root for the Android backend (issue #9): forces analysis of the
//! `zicro.window.Window` methods when targeting aarch64-linux-android. `zig build android`.
const window = @import("window.zig");
comptime {
    _ = window.Window.init;
    _ = window.Window.deinit;
    _ = window.Window.run;
    _ = window.Window.presentRgba;
    _ = window.Window.attach;
    _ = window.Window.textFont;
}
