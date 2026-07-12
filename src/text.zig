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
    advance: f32,
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

const CacheKey = struct { px: u16, style: Style, sub_x: u2, cp: u32 };

/// A font: up to 4 styled faces + an ordered fallback chain + a shared glyph
/// cache (key px+style+cp). When the primary face lacks a codepoint, the glyph
/// is pulled from the first fallback that has it (CJK, emoji-outline, symbols…),
/// instead of rendering a missing-glyph box.
pub const Font = struct {
    gpa: std.mem.Allocator,
    faces: [4]?Face = .{ null, null, null, null },
    /// Consulted in order for codepoints the styled face doesn't cover. Style-less:
    /// a fallback face serves every style (a CJK fallback rarely ships a bold cut,
    /// and a tofu box in the right weight helps no one).
    fallbacks: std.ArrayListUnmanaged(Face) = .empty,
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
    /// On error the caller keeps ownership of `ttf` even with `own = true` (see
    /// `loadFace`, whose errdefer frees the bytes — freeing here too would double-free).
    pub fn setFace(self: *Font, style: Style, ttf: []const u8, own: bool) !void {
        var face: Face = .{ .info = undefined, .owned = if (own) @constCast(ttf) else null };
        const p: [*c]const u8 = @ptrCast(ttf.ptr);
        const off = c.stbtt_GetFontOffsetForIndex(p, 0);
        if (c.stbtt_InitFont(&face.info, p, off) == 0) return error.FontInit;
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

    /// Appends a fallback face from TTF bytes (ownership follows `own`, as in
    /// `setFace`). Fallbacks are tried in insertion order for codepoints the
    /// styled face lacks. Clears the cache (glyph resolution can now change).
    pub fn addFallback(self: *Font, ttf: []const u8, own: bool) !void {
        var face: Face = .{ .info = undefined, .owned = if (own) @constCast(ttf) else null };
        const p: [*c]const u8 = @ptrCast(ttf.ptr);
        const off = c.stbtt_GetFontOffsetForIndex(p, 0);
        if (c.stbtt_InitFont(&face.info, p, off) == 0) return error.FontInit;
        try self.fallbacks.append(self.gpa, face);
        self.clearCache();
    }

    /// Whether some face (styled or fallback) can render `cp` with a real glyph
    /// (not the .notdef box). Codepoint 0 is treated as "coverable" (it maps to
    /// .notdef by definition).
    pub fn hasGlyph(self: *Font, style: Style, cp: u32) bool {
        if (cp == 0) return true;
        if (self.faceFor(style)) |info| {
            if (c.stbtt_FindGlyphIndex(info, @intCast(cp)) != 0) return true;
        }
        for (self.fallbacks.items) |*f| {
            if (c.stbtt_FindGlyphIndex(&f.info, @intCast(cp)) != 0) return true;
        }
        return false;
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

    /// Face that should rasterize `cp` for `style`: the styled face when it covers
    /// the codepoint, else the first fallback that does, else the styled face
    /// (which renders .notdef — a visible box beats a silent drop). Resolution is
    /// deterministic for a fixed face set, so the cache key needs no face id.
    fn faceForCp(self: *Font, style: Style, cp: u32) ?*c.stbtt_fontinfo {
        const primary = self.faceFor(style) orelse return null;
        if (cp == 0 or c.stbtt_FindGlyphIndex(primary, @intCast(cp)) != 0) return primary;
        for (self.fallbacks.items) |*f| {
            if (c.stbtt_FindGlyphIndex(&f.info, @intCast(cp)) != 0) return &f.info;
        }
        return primary;
    }

    /// Rasterized glyph for (size, style, subpixel_x, codepoint), from the cache.
    pub fn getGlyph(self: *Font, px: u16, style: Style, sub_x: u2, cp: u32) !*const Glyph {
        const key = CacheKey{ .px = px, .style = style, .sub_x = sub_x, .cp = cp };
        if (self.cache.getPtr(key)) |g| return g;

        const info = self.faceForCp(style, cp) orelse return error.NoFace;
        const scale = scaleFor(info, px);

        var w: c_int = 0;
        var h: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        const shift_x = @as(f32, @floatFromInt(sub_x)) * 0.25;
        const bmp = c.stbtt_GetCodepointBitmapSubpixel(info, scale, scale, shift_x, 0.0, @intCast(cp), &w, &h, &xoff, &yoff);
        const owned: []const u8 = if (bmp != null and w > 0 and h > 0) blk: {
            const n: usize = @intCast(w * h);
            break :blk try self.gpa.dupe(u8, bmp[0..n]);
        } else &[_]u8{};
        if (bmp != null) c.stbtt_FreeBitmap(bmp, null);
        // If the cache insert below fails, the duped bitmap would leak.
        errdefer if (owned.len > 0) self.gpa.free(owned);

        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetCodepointHMetrics(info, @intCast(cp), &adv, &lsb);

        const g = Glyph{
            .w = w,
            .h = h,
            .xoff = xoff,
            .yoff = yoff,
            .advance = @as(f32, @floatFromInt(adv)) * scale,
            .bitmap = owned,
        };
        // getOrPut instead of put+getPtr: one hash lookup instead of two (the entry is
        // always new — the miss was checked above and the font is single-threaded).
        const gop = try self.cache.getOrPut(self.gpa, key);
        gop.value_ptr.* = g;
        return gop.value_ptr;
    }

    pub fn getKernAdvance(self: *Font, style: Style, px: u16, cp1: u32, cp2: u32) f32 {
        const info = self.faceFor(style) orelse return 0.0;
        const scale = scaleFor(info, px);
        const k = c.stbtt_GetCodepointKernAdvance(info, @intCast(cp1), @intCast(cp2));
        return @as(f32, @floatFromInt(k)) * scale;
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

    /// Width in pixels of `s` (sum of advances + kerning), for centering/aligning.
    pub fn measure(self: *Font, px: u16, style: Style, s: []const u8) i32 {
        var width: f32 = 0.0;
        var prev_cp: ?u32 = null;
        var i: usize = 0;
        while (i < s.len) {
            const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(i + seq, s.len);
            const cp: u32 = std.unicode.utf8Decode(s[i..end]) catch s[i];
            i = end;
            const g = self.getGlyph(px, style, 0, cp) catch continue;
            if (prev_cp) |prev| {
                width += self.getKernAdvance(style, px, prev, cp);
            }
            width += g.advance;
            prev_cp = cp;
        }
        return @intFromFloat(@round(width));
    }

    pub fn deinit(self: *Font) void {
        self.clearCache();
        self.cache.deinit(self.gpa);
        for (self.faces) |maybe| {
            if (maybe) |f| if (f.owned) |b| self.gpa.free(b);
        }
        for (self.fallbacks.items) |f| if (f.owned) |b| self.gpa.free(b);
        self.fallbacks.deinit(self.gpa);
    }
};

test "default font rasterizes a glyph" {
    const gpa = std.testing.allocator;
    var font = try Font.initDefault(gpa);
    defer font.deinit();

    const g = try font.getGlyph(24, .regular, 0, 'A');
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
    _ = try font.getGlyph(18, .bold, 0, 'g');
}

test "fallback chain resolves a codepoint the primary lacks" {
    const gpa = std.testing.allocator;
    var font = try Font.initDefault(gpa);
    defer font.deinit();

    // Hack (a code font) has no SNOWMAN — the primary can't cover it.
    const snowman: u32 = 0x2603;
    try std.testing.expect(!font.hasGlyph(.regular, snowman));
    try std.testing.expect(font.hasGlyph(.regular, 'A')); // but it has Latin

    // DejaVu Sans (glyf TrueType, ubiquitous) does. Read its bytes via the io API
    // and register as a fallback; skip if this box lacks the font.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const deja = "/usr/share/fonts/TTF/DejaVuSans.ttf";
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, deja, gpa, .limited(64 * 1024 * 1024)) catch return;
    try font.addFallback(bytes, true); // font owns & frees the bytes

    try std.testing.expect(font.hasGlyph(.regular, snowman)); // now coverable
    const g = try font.getGlyph(32, .regular, 0, snowman);
    // The fallback glyph rasterized with real ink (not an empty .notdef).
    var ink = false;
    for (g.bitmap) |cov| {
        if (cov > 0) ink = true;
    }
    try std.testing.expect(ink);
    try std.testing.expect(g.advance > 0);

    // A Latin glyph still comes from the primary (Hack), unaffected by the fallback.
    try std.testing.expect((try font.getGlyph(32, .regular, 0, 'A')).advance > 0);
}
