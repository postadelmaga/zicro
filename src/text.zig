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
const builtin = @import("builtin");

// HarfBuzz is only linked for the Linux desktop build (`addNativeDeps` in build.zig);
// macOS/Windows/wasm/Android don't have the header on their include path, so pulling it
// in unconditionally breaks every cross-target build (`hb.h` not found).
const have_hb_lib = builtin.target.os.tag == .linux and builtin.target.abi != .android;

const c = @cImport({
    @cInclude("stb_truetype.h");
    if (have_hb_lib) @cInclude("hb.h");
});

pub const has_harfbuzz = have_hb_lib and @hasDecl(c, "hb_buffer_create");

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
    hb_blob: if (have_hb_lib) ?*c.hb_blob_t else void = if (have_hb_lib) null else {},
    hb_face: if (have_hb_lib) ?*c.hb_face_t else void = if (have_hb_lib) null else {},
    hb_font: if (have_hb_lib) ?*c.hb_font_t else void = if (have_hb_lib) null else {},

    fn initHb(self: *Face, ttf: []const u8) void {
        if (!has_harfbuzz) return;
        const blob = c.hb_blob_create(@ptrCast(ttf.ptr), @intCast(ttf.len), c.HB_MEMORY_MODE_READONLY, null, null);
        if (blob) |b| {
            const face = c.hb_face_create(b, 0);
            if (face) |f| {
                const font = c.hb_font_create(f);
                self.hb_blob = b;
                self.hb_face = f;
                self.hb_font = font;
            } else {
                c.hb_blob_destroy(b);
            }
        }
    }

    fn deinit(self: *Face, gpa: std.mem.Allocator) void {
        if (has_harfbuzz) {
            if (self.hb_font) |f| c.hb_font_destroy(f);
            if (self.hb_face) |f| c.hb_face_destroy(f);
            if (self.hb_blob) |b| c.hb_blob_destroy(b);
        }
        if (self.owned) |b| gpa.free(b);
    }
};

const CacheKey = struct { px: u16, style: Style, sub_x: u2, cp_or_idx: u32, is_index: bool = false };

pub const ShapedGlyph = struct {
    glyph_index: u32,
    x_advance: f32,
    y_advance: f32,
    x_offset: f32,
    y_offset: f32,
    face_info: *c.stbtt_fontinfo,
};

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
        face.initHb(ttf);
        const idx = @intFromEnum(style);
        // Replacing a face: the cached glyphs of that style go stale, but the key
        // includes the style and not the face — the cache is cleared for
        // simplicity and correctness (faces are changed rarely).
        if (self.faces[idx]) |*old| {
            old.deinit(self.gpa);
            self.clearCache();
        }
        self.faces[idx] = face;
    }

    /// Loads a face from a .ttf/.otf file on disk (bytes owned by the font).
    pub fn loadFace(self: *Font, io: std.Io, style: Style, path: []const u8) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(64 * 1024 * 1024));
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
        face.initHb(ttf);
        try self.fallbacks.append(self.gpa, face);
        self.clearCache();
    }

    /// Loads a fallback face from a .ttf/.otf file on disk (bytes owned by the font).
    pub fn loadFallback(self: *Font, io: std.Io, path: []const u8) !void {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, self.gpa, .limited(64 * 1024 * 1024));
        errdefer self.gpa.free(bytes);
        try self.addFallback(bytes, true);
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
        if (self.faceStructFor(style)) |f| return &f.info;
        return null;
    }

    fn faceStructFor(self: *Font, style: Style) ?*Face {
        const order: []const Style = switch (style) {
            .regular => &.{.regular},
            .bold => &.{ .bold, .regular },
            .italic => &.{ .italic, .regular },
            .bold_italic => &.{ .bold_italic, .bold, .italic, .regular },
        };
        for (order) |s| {
            if (self.faces[@intFromEnum(s)]) |*f| return f;
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
        const key = CacheKey{ .px = px, .style = style, .sub_x = sub_x, .cp_or_idx = cp, .is_index = false };
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
        const gop = try self.cache.getOrPut(self.gpa, key);
        gop.value_ptr.* = g;
        return gop.value_ptr;
    }

    /// Rasterized glyph for a specific glyph index in `info`, from the cache.
    pub fn getGlyphByIndex(self: *Font, info: *c.stbtt_fontinfo, px: u16, style: Style, sub_x: u2, glyph_index: u32) !*const Glyph {
        const key = CacheKey{ .px = px, .style = style, .sub_x = sub_x, .cp_or_idx = glyph_index, .is_index = true };
        if (self.cache.getPtr(key)) |g| return g;

        const scale = scaleFor(info, px);

        var w: c_int = 0;
        var h: c_int = 0;
        var xoff: c_int = 0;
        var yoff: c_int = 0;
        const shift_x = @as(f32, @floatFromInt(sub_x)) * 0.25;
        const bmp = c.stbtt_GetGlyphBitmapSubpixel(info, scale, scale, shift_x, 0.0, @intCast(glyph_index), &w, &h, &xoff, &yoff);
        const owned: []const u8 = if (bmp != null and w > 0 and h > 0) blk: {
            const n: usize = @intCast(w * h);
            break :blk try self.gpa.dupe(u8, bmp[0..n]);
        } else &[_]u8{};
        if (bmp != null) c.stbtt_FreeBitmap(bmp, null);
        errdefer if (owned.len > 0) self.gpa.free(owned);

        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetGlyphHMetrics(info, @intCast(glyph_index), &adv, &lsb);

        const g = Glyph{
            .w = w,
            .h = h,
            .xoff = xoff,
            .yoff = yoff,
            .advance = @as(f32, @floatFromInt(adv)) * scale,
            .bitmap = owned,
        };
        const gop = try self.cache.getOrPut(self.gpa, key);
        gop.value_ptr.* = g;
        return gop.value_ptr;
    }

    /// Shapes `text` into a sequence of positioned glyphs using HarfBuzz.
    /// Returns `true` if shaping was successfully performed, `false` if HarfBuzz is unavailable
    /// or font has no HarfBuzz handle.
    pub fn shapeText(self: *Font, px: u16, style: Style, text: []const u8, out: *std.ArrayListUnmanaged(ShapedGlyph), alloc: std.mem.Allocator) !bool {
        if (!has_harfbuzz) return false;
        const face = self.faceStructFor(style) orelse return false;
        const hb_font = face.hb_font orelse return false;

        const buf = c.hb_buffer_create() orelse return false;
        defer c.hb_buffer_destroy(buf);

        c.hb_buffer_add_utf8(buf, @ptrCast(text.ptr), @intCast(text.len), 0, @intCast(text.len));
        c.hb_buffer_guess_segment_properties(buf);

        const scale = scaleFor(&face.info, px);
        c.hb_shape(hb_font, buf, null, 0);

        var count: u32 = 0;
        const infos = c.hb_buffer_get_glyph_infos(buf, &count);
        const positions = c.hb_buffer_get_glyph_positions(buf, &count);
        if (count == 0) return true;

        var i: usize = 0;
        while (i < count) : (i += 1) {
            const g_idx = infos[i].codepoint;
            const x_adv = @as(f32, @floatFromInt(positions[i].x_advance)) * scale;
            const y_adv = @as(f32, @floatFromInt(positions[i].y_advance)) * scale;
            const x_off = @as(f32, @floatFromInt(positions[i].x_offset)) * scale;
            const y_off = @as(f32, @floatFromInt(positions[i].y_offset)) * scale;

            try out.append(alloc, .{
                .glyph_index = g_idx,
                .x_advance = x_adv,
                .y_advance = y_adv,
                .x_offset = x_off,
                .y_offset = y_off,
                .face_info = &face.info,
            });
        }
        return true;
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
        var w: GlyphWalker = .init(self, px, style, s);
        defer w.deinit();
        while (w.next()) |_| {}
        return @intFromFloat(@round(w.pen_x));
    }

    pub fn deinit(self: *Font) void {
        self.clearCache();
        self.cache.deinit(self.gpa);
        for (&self.faces) |*maybe| {
            if (maybe.*) |*f| f.deinit(self.gpa);
        }
        for (self.fallbacks.items) |*f| f.deinit(self.gpa);
        self.fallbacks.deinit(self.gpa);
    }
};

/// Walks a string glyph by glyph, advancing the pen with kerning and (optionally)
/// subpixel-quantized positioning — the exact math `Canvas.drawText` (CPU and GL) and
/// `Font.measure` all need, so it lives once here instead of three times.
pub const GlyphWalker = struct {
    font: *Font,
    px: u16,
    style: Style,
    s: []const u8,
    i: usize = 0,
    /// Left edge of the pen, updated as glyphs are consumed.
    pen_x: f32 = 0,
    prev_cp: ?u32 = null,
    /// Quantize `pen_x`'s fraction into `glyph.sub_x` (crisp small text at fixed pixel
    /// sizes); off for `measure`, which only wants the total advance.
    subpixel: bool = false,
    shaping: bool = true,

    shaped_items: std.ArrayListUnmanaged(ShapedGlyph) = .empty,
    shaped_idx: usize = 0,
    shaped_init: bool = false,

    pub fn init(font: *Font, px: u16, style: Style, s: []const u8) GlyphWalker {
        return .{ .font = font, .px = px, .style = style, .s = s };
    }

    pub fn initAt(font: *Font, px: u16, style: Style, s: []const u8, pen_x: f32) GlyphWalker {
        return .{ .font = font, .px = px, .style = style, .s = s, .pen_x = pen_x, .subpixel = true };
    }

    pub fn deinit(w: *GlyphWalker) void {
        w.shaped_items.deinit(w.font.gpa);
    }

    /// One glyph and the pen position (rounded, pixel) to draw it at. `null` at end of
    /// string; advances `pen_x` by the glyph's width so the next call continues the run.
    pub fn next(w: *GlyphWalker) ?struct { glyph: *const Glyph, pen_x: i32 } {
        if (w.shaping and !w.shaped_init) {
            w.shaped_init = true;
            _ = w.font.shapeText(w.px, w.style, w.s, &w.shaped_items, w.font.gpa) catch false;
        }

        if (w.shaped_items.items.len > 0) {
            // Freed once by `deinit` (every caller `defer`s it), not here: freeing on
            // exhaustion and resetting to `.empty` would make a stray extra `next()` call
            // (after it already returned `null` once) silently fall through to the
            // byte-walk path below and re-walk the string from `w.i == 0`, duplicating glyphs.
            if (w.shaped_idx >= w.shaped_items.items.len) return null;
            const sg = w.shaped_items.items[w.shaped_idx];
            w.shaped_idx += 1;

            const sub_x: u2 = if (w.subpixel)
                @intCast(@as(i32, @intFromFloat(@round(((w.pen_x + sg.x_offset) - @floor(w.pen_x + sg.x_offset)) * 4.0))) & 3)
            else
                0;
            const glyph = w.font.getGlyphByIndex(sg.face_info, w.px, w.style, sub_x, sg.glyph_index) catch return w.next();
            const ipen_x: i32 = @intFromFloat(@floor(w.pen_x + sg.x_offset + 0.5));
            w.pen_x += sg.x_advance;
            return .{ .glyph = glyph, .pen_x = ipen_x };
        }

        if (w.i >= w.s.len) return null;
        const seq = std.unicode.utf8ByteSequenceLength(w.s[w.i]) catch 1;
        const end = @min(w.i + seq, w.s.len);
        const cp: u32 = std.unicode.utf8Decode(w.s[w.i..end]) catch w.s[w.i];
        w.i = end;

        if (w.prev_cp) |prev| w.pen_x += w.font.getKernAdvance(w.style, w.px, prev, cp);
        w.prev_cp = cp;

        const sub_x: u2 = if (w.subpixel)
            @intCast(@as(i32, @intFromFloat(@round((w.pen_x - @floor(w.pen_x)) * 4.0))) & 3)
        else
            0;
        const glyph = w.font.getGlyph(w.px, w.style, sub_x, cp) catch {
            return w.next(); // skip a glyph the font can't rasterize; keep walking
        };
        const ipen_x: i32 = @intFromFloat(@floor(w.pen_x + 0.5));
        w.pen_x += glyph.advance;
        return .{ .glyph = glyph, .pen_x = ipen_x };
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

    // DejaVu Sans (glyf TrueType, ubiquitous) does. Read its bytes via loadFallback;
    // skip if this box lacks the font.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const deja = "/usr/share/fonts/TTF/DejaVuSans.ttf";
    font.loadFallback(io, deja) catch return;

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

test "HarfBuzz shaping shapes text runs and produces positioned glyphs" {
    if (!has_harfbuzz) return;
    const gpa = std.testing.allocator;
    var font = try Font.initDefault(gpa);
    defer font.deinit();

    var shaped: std.ArrayListUnmanaged(ShapedGlyph) = .empty;
    defer shaped.deinit(gpa);

    const text_str = "hello world";
    const ok = try font.shapeText(24, .regular, text_str, &shaped, gpa);
    try std.testing.expect(ok);
    try std.testing.expectEqual(@as(usize, text_str.len), shaped.items.len);

    // Test GlyphWalker with shaping
    var walker = GlyphWalker.init(&font, 24, .regular, text_str);
    defer walker.deinit();

    var count: usize = 0;
    while (walker.next()) |item| {
        try std.testing.expect(item.glyph.advance > 0);
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, text_str.len), count);
}


