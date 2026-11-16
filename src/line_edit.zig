//! line_edit.zig — a single-line text editor model: bytes + caret + selection.
//!
//! The editing half of a text field, without any drawing or input plumbing, for
//! apps that paint their own fields (an address bar, a search box) instead of
//! going through `widget.Ui.textField`. Fixed capacity, no allocation; text is
//! UTF-8 and the caret never lands inside a sequence.
//!
//! Key mapping is the caller's (it knows its keycodes); the vocabulary is the
//! usual one: ←/→ (+Ctrl by word, +Shift extends the selection), Home/End,
//! Backspace/Delete (+Ctrl by word), Ctrl+A, and cut/copy/paste through
//! `selection()` + `insert()`. Words for Ctrl-moves are runs of alphanumerics
//! (and any non-ASCII byte), so URL punctuation (`/ . : ? & = -`) stops them.

const std = @import("std");

pub fn LineEdit(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        buf: [capacity]u8 = undefined,
        len: usize = 0,
        /// Caret, a byte offset on a codepoint boundary.
        cursor: usize = 0,
        /// Selection anchor: the selection spans anchor..cursor (either order).
        anchor: ?usize = null,

        pub fn text(self: *const Self) []const u8 {
            return self.buf[0..self.len];
        }

        /// Replace the whole content; caret at the end, everything selected when
        /// `select_all` (an address bar opening on the current URL).
        pub fn set(self: *Self, s: []const u8, select_all: bool) void {
            const n = clampUtf8(s, capacity);
            @memcpy(self.buf[0..n], s[0..n]);
            self.len = n;
            self.cursor = n;
            self.anchor = if (select_all and n > 0) 0 else null;
        }

        pub fn clear(self: *Self) void {
            self.len = 0;
            self.cursor = 0;
            self.anchor = null;
        }

        /// The selected byte range, or null when nothing (or an empty range) is selected.
        pub fn selection(self: *const Self) ?struct { start: usize, end: usize } {
            const a = self.anchor orelse return null;
            if (a == self.cursor) return null;
            return .{ .start = @min(a, self.cursor), .end = @max(a, self.cursor) };
        }

        pub fn selectedText(self: *const Self) []const u8 {
            const s = self.selection() orelse return &.{};
            return self.buf[s.start..s.end];
        }

        pub fn selectAll(self: *Self) void {
            self.anchor = 0;
            self.cursor = self.len;
        }

        /// Delete the selection, if any. Returns whether something was deleted.
        pub fn deleteSelection(self: *Self) bool {
            const s = self.selection() orelse {
                self.anchor = null;
                return false;
            };
            self.removeRange(s.start, s.end);
            self.cursor = s.start;
            self.anchor = null;
            return true;
        }

        /// Type or paste `s` at the caret, replacing the selection. Control bytes
        /// (newlines, tabs) are dropped — this is one line. Truncates at capacity
        /// on a codepoint boundary.
        pub fn insert(self: *Self, s: []const u8) void {
            _ = self.deleteSelection();
            var i: usize = 0;
            while (i < s.len) {
                const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                if (i + n > s.len) break;
                if (n == 1 and (s[i] < 0x20 or s[i] == 0x7f)) {
                    i += 1;
                    continue;
                }
                if (self.len + n > capacity) break;
                std.mem.copyBackwards(u8, self.buf[self.cursor + n .. self.len + n], self.buf[self.cursor..self.len]);
                @memcpy(self.buf[self.cursor .. self.cursor + n], s[i .. i + n]);
                self.len += n;
                self.cursor += n;
                i += n;
            }
        }

        pub fn backspace(self: *Self, word: bool) void {
            if (self.deleteSelection()) return;
            const to = if (word) self.wordLeft(self.cursor) else self.prev(self.cursor);
            self.removeRange(to, self.cursor);
            self.cursor = to;
        }

        pub fn delete(self: *Self, word: bool) void {
            if (self.deleteSelection()) return;
            const to = if (word) self.wordRight(self.cursor) else self.next(self.cursor);
            self.removeRange(self.cursor, to);
        }

        /// ←: by codepoint or word; `extend` grows the selection. Without
        /// `extend`, a selection collapses to its left edge first.
        pub fn left(self: *Self, word: bool, extend: bool) void {
            if (!extend) {
                if (self.selection()) |s| {
                    self.cursor = s.start;
                    self.anchor = null;
                    return;
                }
            }
            self.moveTo(if (word) self.wordLeft(self.cursor) else self.prev(self.cursor), extend);
        }

        pub fn right(self: *Self, word: bool, extend: bool) void {
            if (!extend) {
                if (self.selection()) |s| {
                    self.cursor = s.end;
                    self.anchor = null;
                    return;
                }
            }
            self.moveTo(if (word) self.wordRight(self.cursor) else self.next(self.cursor), extend);
        }

        pub fn home(self: *Self, extend: bool) void {
            self.moveTo(0, extend);
        }

        pub fn end(self: *Self, extend: bool) void {
            self.moveTo(self.len, extend);
        }

        // ---------------------------------------------------------------- internals

        fn moveTo(self: *Self, pos: usize, extend: bool) void {
            if (extend) {
                if (self.anchor == null) self.anchor = self.cursor;
            } else self.anchor = null;
            self.cursor = pos;
        }

        fn removeRange(self: *Self, a: usize, b: usize) void {
            if (b <= a) return;
            std.mem.copyForwards(u8, self.buf[a .. self.len - (b - a)], self.buf[b..self.len]);
            self.len -= b - a;
        }

        fn prev(self: *const Self, pos: usize) usize {
            if (pos == 0) return 0;
            var i = pos - 1;
            while (i > 0 and self.buf[i] & 0xc0 == 0x80) i -= 1;
            return i;
        }

        fn next(self: *const Self, pos: usize) usize {
            if (pos >= self.len) return self.len;
            var i = pos + 1;
            while (i < self.len and self.buf[i] & 0xc0 == 0x80) i += 1;
            return i;
        }

        fn isWord(c: u8) bool {
            return std.ascii.isAlphanumeric(c) or c >= 0x80;
        }

        /// Ctrl+←: skip separators, then the word before them.
        fn wordLeft(self: *const Self, pos: usize) usize {
            var i = pos;
            while (i > 0 and !isWord(self.buf[i - 1])) i -= 1;
            while (i > 0 and isWord(self.buf[i - 1])) i -= 1;
            return i;
        }

        /// Ctrl+→: skip the word under/after the caret, then the separators after it.
        fn wordRight(self: *const Self, pos: usize) usize {
            var i = pos;
            while (i < self.len and !isWord(self.buf[i])) i += 1;
            while (i < self.len and isWord(self.buf[i])) i += 1;
            return i;
        }
    };
}

/// Longest prefix of `s` that fits in `max` bytes without splitting a codepoint.
fn clampUtf8(s: []const u8, max: usize) usize {
    if (s.len <= max) return s.len;
    var n = max;
    while (n > 0 and s[n] & 0xc0 == 0x80) n -= 1;
    return n;
}

test "type, move, delete" {
    var e: LineEdit(64) = .{};
    e.insert("hello world");
    e.left(true, false); // before "world"
    try std.testing.expectEqual(@as(usize, 6), e.cursor);
    e.insert("big ");
    try std.testing.expectEqualStrings("hello big world", e.text());
    e.backspace(true); // "big " → removes "big "
    try std.testing.expectEqualStrings("hello world", e.text());
    e.home(false);
    e.delete(false);
    try std.testing.expectEqualStrings("ello world", e.text());
    e.end(false);
    e.backspace(false);
    try std.testing.expectEqualStrings("ello worl", e.text());
}

test "selection replace, select all, collapse" {
    var e: LineEdit(64) = .{};
    e.set("https://example.com/path", true);
    try std.testing.expectEqualStrings("https://example.com/path", e.selectedText());
    e.insert("gemini.google.com");
    try std.testing.expectEqualStrings("gemini.google.com", e.text());
    e.left(false, true);
    e.left(false, true);
    try std.testing.expectEqualStrings("om", e.selectedText());
    e.left(false, false); // collapse to the left edge
    try std.testing.expectEqual(@as(?usize, null), e.anchor);
    try std.testing.expectEqual(@as(usize, 15), e.cursor);
    e.selectAll();
    e.backspace(false);
    try std.testing.expectEqualStrings("", e.text());
}

test "utf8 boundaries, control bytes, capacity" {
    var e: LineEdit(8) = .{};
    e.insert("è\nà");
    try std.testing.expectEqualStrings("èà", e.text());
    e.left(false, false);
    try std.testing.expectEqual(@as(usize, 2), e.cursor);
    e.backspace(false);
    try std.testing.expectEqualStrings("à", e.text());
    e.end(false);
    e.insert("abcdefgh"); // 2 + 6 fits, the rest is dropped
    try std.testing.expectEqual(@as(usize, 8), e.len);
    e.set("ààààà", false); // 10 bytes into 8: 4 whole codepoints
    try std.testing.expectEqualStrings("àààà", e.text());
}

test "word moves stop at URL punctuation" {
    var e: LineEdit(64) = .{};
    e.set("https://en.wikipedia.org/wiki", false);
    e.left(true, false);
    try std.testing.expectEqualStrings("wiki", e.text()[e.cursor..]);
    e.left(true, false);
    try std.testing.expectEqualStrings("org/wiki", e.text()[e.cursor..]);
    e.home(false);
    e.right(true, false);
    try std.testing.expectEqualStrings("://en.wikipedia.org/wiki", e.text()[e.cursor..]);
}
