//! # zrame.xkb — hand-declared libxkbcommon FFI
//!
//! The thin xkbcommon floor for keyboard layout translation, in the same spirit as
//! zicro's `wl.zig`: explicit `extern` declarations against opaque handles, no
//! `@cImport`. Only the slice needed to turn Wayland's evdev key codes + xkb keymap
//! into UTF-8 text is declared: context, keymap-from-string, state, and the
//! modifier/utf8 queries. Linked via `xkbcommon` in build.zig.

/// `struct xkb_context` — global library context (include paths, logging).
pub const Context = opaque {};
/// `struct xkb_keymap` — the compiled keymap the compositor sent us.
pub const Keymap = opaque {};
/// `struct xkb_state` — keymap + current modifier/layout state.
pub const State = opaque {};

/// enum xkb_context_flags: no flags — default include paths (unused for a
/// compositor-provided keymap string, but the context wants a value).
pub const CONTEXT_NO_FLAGS: c_int = 0;
/// enum xkb_keymap_format: the text v1 format `wl_keyboard.keymap` fd carries.
pub const KEYMAP_FORMAT_TEXT_V1: c_int = 1;
/// enum xkb_keymap_compile_flags: no flags.
pub const KEYMAP_COMPILE_NO_FLAGS: c_int = 0;

pub extern fn xkb_context_new(flags: c_int) ?*Context;
pub extern fn xkb_context_unref(context: ?*Context) void;

/// Compile a keymap from a NUL-terminated text blob (the mmap'd `wl_keyboard.keymap` fd).
pub extern fn xkb_keymap_new_from_string(context: *Context, string: [*:0]const u8, format: c_int, flags: c_int) ?*Keymap;
pub extern fn xkb_keymap_unref(keymap: ?*Keymap) void;

pub extern fn xkb_state_new(keymap: *Keymap) ?*State;
pub extern fn xkb_state_unref(state: ?*State) void;

/// Feed the masks from `wl_keyboard.modifiers` straight through (the layout indices go
/// in the last slot: Wayland's `group` is the effective locked layout).
pub extern fn xkb_state_update_mask(state: *State, depressed_mods: u32, latched_mods: u32, locked_mods: u32, depressed_layout: u32, latched_layout: u32, locked_layout: u32) c_uint;

/// UTF-8 text a key produces under the current state. `key` is the xkb keycode
/// (evdev code + 8). Returns the byte length the full text needs (0 = none);
/// the buffer gets at most `size - 1` bytes plus a NUL.
pub extern fn xkb_state_key_get_utf8(state: *State, key: u32, buffer: [*]u8, size: usize) c_int;

/// Whether the keymap marks `key` (xkb keycode = evdev + 8) as auto-repeating.
/// Modifiers and lock keys report 0; letters, arrows, backspace… report 1.
pub extern fn xkb_keymap_key_repeats(keymap: *Keymap, key: u32) c_int;
