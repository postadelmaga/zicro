//! Compile-check root for the zrame Android backend (issue #11): forces analysis of the
//! `zrame.window.Window` methods when targeting aarch64-linux-android. `zig build android`.
const window = @import("window.zig");
comptime {
    _ = window.Window.init;
    _ = window.Window.deinit;
    _ = window.Window.run;
    _ = window.Window.attach;
    _ = window.Window.presentRgba;
    _ = window.Window.textFont;
}
