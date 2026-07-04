//! # zicro.text — native text engine (stb_truetype)
//!
//! Rasterizes glyphs at an exact pixel size (no scaling → crisp) and caches
//! them as coverage maps (alpha 0..255). It is extensible: a default font is
//! embedded (Hack regular+bold), but any face can be replaced with arbitrary
//! TTF bytes (`setFace`) or loaded from disk (`loadFace`).
//!
//! The glyph *compositing* onto the premultiplied canvas lives in `paint.zig`
//! (`Canvas.drawText`); here there is only rasterization, with no dependency on paint.

const std = @import("std");
const c = @cImport({
    @cInclude("stb_truetype.h");
});

/// Available faces. The default embeds regular+bold; italic/bold_italic are
/// optional and, when absent, fall back to bold/regular.
pub const Style = enum(u2) { regular = 0, bold = 1, italic = 2, bold_italic = 3 };

/// Rasterized glyph: coverage (alpha 0..255) of size w*h, offset from the pen
/// point, baseline and horizontal advance (for proportional fonts).
/// `bitmap` is owned by the cache.
pub const Glyph = struct {
    w: i32,
    h: i32,
    xoff: i32,
    yoff: i32,
    advance: i32,
    bitmap: []const u8,
};

const default_regular = @embedFile("assets/Hack-Regular.ttf");
const default_bold = @embedFile("assets/Hack-Bold.ttf");

const Face = struct {
    info: c.stbtt_fontinfo,
    // Owned TTF bytes (font loaded from disk): they must outlive `info`, which
    // points into them. `null` for statically embedded fonts.
    owned: ?[]u8 = null,
};

const CacheKey = struct { px: u16, style: Style, cp: u32 };

/// A font: up to 4 faces + a shared glyph cache (key px+style+cp).
pub const Font = struct {
    gpa: std.mem.Allocator,
    faces: [4]?Face = .{ null, null, null, null },
    cache: std.AutoHashMapUnmanaged(CacheKey, Glyph) = .empty,

    /// Default font: Hack regular + bold embedded in the binary.
    pub fn initDefault(gpa: std.mem.Allocator) !Font {
        var self = Font{ .gpa = gpa };
        errdefer self.deinit();
        try self.setFace(.regular, default_regular, false);
        try self.setFace(.bold, default_bold, false);
        return self;
    }

    /// Sets a face from TTF bytes. With `own = true` the `Font` takes ownership
    /// of `ttf` and frees it in `deinit` (font from disk); with `false` it assumes
    /// the bytes stay valid for the whole lifetime of the font (statically embedded).
    pub fn setFace(self: *Font, style: Style, ttf: []const u8, own: bool) !void {
        var face: Face = .{ .info = undefined, .owned = if (own) @constCast(ttf) else null };
        const p: [*c]const u8 = @ptrCast(ttf.ptr);
        const off = c.stbtt_GetFontOffsetForIndex(p, 0);
        if (c.stbtt_InitFont(&face.info, p, off) == 0) {
            if (own) self.gpa.free(@constCast(ttf));
            return error.FontInit;
        }
        const idx = @intFromEnum(style);
        // Replacing a face: the cached glyphs of that style go stale, but the key
        // includes the style and not the face — the cache is cleared for
        // simplicity and correctness (faces are changed rarely).
        if (self.faces[idx]) |old| {
            if (old.owned) |b| self.gpa.free(b);
            self.clearCache();
        }
        self.faces[idx] = face;
    }

    /// Loads a face from a .ttf/.otf file on disk (bytes owned by the font).
    pub fn loadFace(self: *Font, style: Style, path: []const u8) !void {
        const bytes = try std.fs.cwd().readFileAlloc(self.gpa, path, 64 * 1024 * 1024);
        errdefer self.gpa.free(bytes);
        try self.setFace(style, bytes, true);
    }

    fn clearCache(self: *Font) void {
        var it = self.cache.valueIterator();
        while (it.next()) |g| if (g.bitmap.len > 0) self.gpa.free(g.bitmap);
        self.cache.clearRetainingCapacity();
    }

    /// Effective face for a style, with fallback: bold_italic→italic→bold→
    /// regular, so a font with only regular+bold stays usable.
    fn faceFor(self: *Font, style: Style) ?*c.stbtt_fontinfo {
        const order: []const Style = switch (style) {
            .regular => &.{.regular},
            .bold => &.{ .bold, .regular },
            .italic => &.{ .italic, .regular },
            .bold_italic => &.{ .bold_italic, .bold, .italic, .regular },
        };
        for (order) |s| {
            if (self.faces[@intFromEnum(s)]) |*f| return &f.info;
        }
        return null;
    }

    fn scaleFor(info: *c.stbtt_fontinfo, px: u16) f32 {
        return c.stbtt_ScaleForPixelHeight(info, @floatFromInt(px));
    }

    /// Rasterized glyph for (size, style, codepoint), from the cache.
    pub fn getGlyph(self: *Font, px: u16, style: Style, cp: u32) !*const Glyph {
        const key = CacheKey{ .px = px, .style = style, .cp = cp };
        if (self.cache.getPtr(key)) |g| return g;

        const info = self.faceFor(style) orelse return error.NoFace;
        const scale = scaleFor(info, px);

        var w: c_int = 0;
        var h: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        const bmp = c.stbtt_GetCodepointBitmap(info, 0, scale, @intCast(cp), &w, &h, &xoff, &yoff);
        const owned: []const u8 = if (bmp != null and w > 0 and h > 0) blk: {
            const n: usize = @intCast(w * h);
            break :blk try self.gpa.dupe(u8, bmp[0..n]);
        } else &[_]u8{};
        if (bmp != null) c.stbtt_FreeBitmap(bmp, null);

        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetCodepointHMetrics(info, @intCast(cp), &adv, &lsb);

        const g = Glyph{
            .w = w,
            .h = h,
            .xoff = xoff,
            .yoff = yoff,
            .advance = @intFromFloat(@round(@as(f32, @floatFromInt(adv)) * scale)),
            .bitmap = owned,
        };
        try self.cache.put(self.gpa, key, g);
        return self.cache.getPtr(key).?;
    }

    /// Vertical metrics in pixels at a given size/style.
    pub const VMetrics = struct { ascent: i32, descent: i32, line_gap: i32 };
    pub fn vmetrics(self: *Font, px: u16, style: Style) VMetrics {
        const info = self.faceFor(style) orelse return .{ .ascent = px, .descent = 0, .line_gap = 0 };
        const scale = scaleFor(info, px);
        var asc: c_int = 0;
        var desc: c_int = 0;
        var gap: c_int = 0;
        c.stbtt_GetFontVMetrics(info, &asc, &desc, &gap);
        return .{
            .ascent = @intFromFloat(@round(@as(f32, @floatFromInt(asc)) * scale)),
            .descent = @intFromFloat(@round(@as(f32, @floatFromInt(desc)) * scale)),
            .line_gap = @intFromFloat(@round(@as(f32, @floatFromInt(gap)) * scale)),
        };
    }

    /// Line height (vertical advance) in pixels.
    pub fn lineHeight(self: *Font, px: u16, style: Style) i32 {
        const v = self.vmetrics(px, style);
        return v.ascent - v.descent + v.line_gap;
    }

    /// Width in pixels of `s` (sum of advances), for centering/aligning.
    pub fn measure(self: *Font, px: u16, style: Style, s: []const u8) i32 {
        var width: i32 = 0;
        var i: usize = 0;
        while (i < s.len) {
            const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(i + seq, s.len);
            const cp: u32 = std.unicode.utf8Decode(s[i..end]) catch s[i];
            i = end;
            const g = self.getGlyph(px, style, cp) catch continue;
            width += g.advance;
        }
        return width;
    }

    pub fn deinit(self: *Font) void {
        self.clearCache();
        self.cache.deinit(self.gpa);
        for (self.faces) |maybe| {
            if (maybe) |f| if (f.owned) |b| self.gpa.free(b);
        }
    }
};

test "default font rasterizes a glyph" {
    const gpa = std.testing.allocator;
    var font = try Font.initDefault(gpa);
    defer font.deinit();

    const g = try font.getGlyph(24, .regular, 'A');
    try std.testing.expect(g.w > 0 and g.h > 0);
    try std.testing.expect(g.advance > 0);
    // 'A' has non-zero coverage somewhere.
    var any: bool = false;
    for (g.bitmap) |cov| {
        if (cov > 0) any = true;
    }
    try std.testing.expect(any);

    // A string's measure grows with its characters.
    try std.testing.expect(font.measure(24, .regular, "Hi") > font.measure(24, .regular, "H"));
    // Bold falls back to a valid (embedded) face; a no-ink space is fine.
    _ = try font.getGlyph(18, .bold, 'g');
}
