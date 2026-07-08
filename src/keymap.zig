//! # zicro.keymap — evdev keycodes → symbolic keys / characters
//!
//! The window backends' `on_key` delivers raw evdev keycodes on every platform (Win32
//! VK codes are already translated by the backend). This module gives them meaning for text-editing
//! UIs: a symbolic [`Key`] for navigation/editing keys, and a best-effort character
//! translation for a US layout (the same table the zicro shell example uses, extended
//! with punctuation).
//!
//! **Known limit:** real keyboard-layout awareness (Italian, dead keys, compose) needs
//! xkbcommon on Wayland; that is a deliberate later slice. The `Key` half is
//! layout-independent and final; only `toChar` is US-bound.

/// Layout-independent editing/navigation keys (evdev codes).
pub const Key = enum {
    escape,
    enter,
    tab,
    backspace,
    delete,
    left,
    right,
    up,
    down,
    home,
    end,
    page_up,
    page_down,
    shift,
    ctrl,
    alt,
    super,
    other,

    pub fn fromEvdev(code: u32) Key {
        return switch (code) {
            1 => .escape,
            28, 96 => .enter, // main + keypad
            15 => .tab,
            14 => .backspace,
            111 => .delete,
            105 => .left,
            106 => .right,
            103 => .up,
            108 => .down,
            102 => .home,
            107 => .end,
            104 => .page_up,
            109 => .page_down,
            42, 54 => .shift,
            29, 97 => .ctrl,
            56, 100 => .alt,
            125, 126 => .super,
            else => .other,
        };
    }
};

/// Best-effort US-layout character for an evdev keycode. Returns `null` for anything
/// that isn't a printable character (see [`Key`] for those).
pub fn toChar(code: u32, shift: bool) ?u8 {
    return switch (code) {
        // letter rows
        16 => sh(shift, 'Q', 'q'),
        17 => sh(shift, 'W', 'w'),
        18 => sh(shift, 'E', 'e'),
        19 => sh(shift, 'R', 'r'),
        20 => sh(shift, 'T', 't'),
        21 => sh(shift, 'Y', 'y'),
        22 => sh(shift, 'U', 'u'),
        23 => sh(shift, 'I', 'i'),
        24 => sh(shift, 'O', 'o'),
        25 => sh(shift, 'P', 'p'),
        30 => sh(shift, 'A', 'a'),
        31 => sh(shift, 'S', 's'),
        32 => sh(shift, 'D', 'd'),
        33 => sh(shift, 'F', 'f'),
        34 => sh(shift, 'G', 'g'),
        35 => sh(shift, 'H', 'h'),
        36 => sh(shift, 'J', 'j'),
        37 => sh(shift, 'K', 'k'),
        38 => sh(shift, 'L', 'l'),
        44 => sh(shift, 'Z', 'z'),
        45 => sh(shift, 'X', 'x'),
        46 => sh(shift, 'C', 'c'),
        47 => sh(shift, 'V', 'v'),
        48 => sh(shift, 'B', 'b'),
        49 => sh(shift, 'N', 'n'),
        50 => sh(shift, 'M', 'm'),
        // number row
        2 => sh(shift, '!', '1'),
        3 => sh(shift, '@', '2'),
        4 => sh(shift, '#', '3'),
        5 => sh(shift, '$', '4'),
        6 => sh(shift, '%', '5'),
        7 => sh(shift, '^', '6'),
        8 => sh(shift, '&', '7'),
        9 => sh(shift, '*', '8'),
        10 => sh(shift, '(', '9'),
        11 => sh(shift, ')', '0'),
        // punctuation
        12 => sh(shift, '_', '-'),
        13 => sh(shift, '+', '='),
        26 => sh(shift, '{', '['),
        27 => sh(shift, '}', ']'),
        39 => sh(shift, ':', ';'),
        40 => sh(shift, '"', '\''),
        41 => sh(shift, '~', '`'),
        43 => sh(shift, '|', '\\'),
        51 => sh(shift, '<', ','),
        52 => sh(shift, '>', '.'),
        53 => sh(shift, '?', '/'),
        57 => ' ',
        else => null,
    };
}

inline fn sh(shift: bool, upper: u8, lower: u8) u8 {
    return if (shift) upper else lower;
}

test "symbolic keys and US chars" {
    const t = @import("std").testing;
    try t.expectEqual(Key.enter, Key.fromEvdev(28));
    try t.expectEqual(Key.backspace, Key.fromEvdev(14));
    try t.expectEqual(Key.shift, Key.fromEvdev(54));
    try t.expectEqual(@as(?u8, 'a'), toChar(30, false));
    try t.expectEqual(@as(?u8, 'A'), toChar(30, true));
    try t.expectEqual(@as(?u8, '1'), toChar(2, false));
    try t.expectEqual(@as(?u8, null), toChar(105, false)); // left arrow is not a char
}
