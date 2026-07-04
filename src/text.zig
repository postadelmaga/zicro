//! # zrame.text — motore di testo nativo (stb_truetype)
//!
//! Rasterizza glifi a una dimensione in pixel esatta (niente scaling → nitido) e
//! li memorizza in cache come mappe di copertura (alpha 0..255). È estendibile:
//! un font di default è embeddato (Hack regular+bold), ma ogni faccia può essere
//! sostituita da byte TTF arbitrari (`setFace`) o caricata da disco (`loadFace`).
//!
//! Il *compositing* dei glifi sul canvas premoltiplicato vive in `paint.zig`
//! (`Canvas.drawText`); qui c'è solo la rasterizzazione, senza dipendenze da paint.

const std = @import("std");
const c = @cImport({
    @cInclude("stb_truetype.h");
});

/// Facce disponibili. Il default embedda regular+bold; italic/bold_italic sono
/// opzionali e, se assenti, ripiegano su bold/regular.
pub const Style = enum(u2) { regular = 0, bold = 1, italic = 2, bold_italic = 3 };

/// Glifo rasterizzato: copertura (alpha 0..255) di dimensione w*h, offset dal
/// punto di penna, baseline e avanzamento orizzontale (per font proporzionali).
/// `bitmap` è di proprietà della cache.
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
    // Byte TTF posseduti (font caricato da disco): devono sopravvivere a `info`,
    // che vi punta dentro. `null` per i font embeddati statici.
    owned: ?[]u8 = null,
};

const CacheKey = struct { px: u16, style: Style, cp: u32 };

/// Un font: fino a 4 facce + cache dei glifi condivisa (chiave px+stile+cp).
pub const Font = struct {
    gpa: std.mem.Allocator,
    faces: [4]?Face = .{ null, null, null, null },
    cache: std.AutoHashMapUnmanaged(CacheKey, Glyph) = .empty,

    /// Font di default: Hack regular + bold embeddati nel binario.
    pub fn initDefault(gpa: std.mem.Allocator) !Font {
        var self = Font{ .gpa = gpa };
        errdefer self.deinit();
        try self.setFace(.regular, default_regular, false);
        try self.setFace(.bold, default_bold, false);
        return self;
    }

    /// Imposta una faccia da byte TTF. Con `own = true` il `Font` prende possesso
    /// di `ttf` e lo libera in `deinit` (font da disco); con `false` assume che i
    /// byte restino validi per tutta la vita del font (embeddati statici).
    pub fn setFace(self: *Font, style: Style, ttf: []const u8, own: bool) !void {
        var face: Face = .{ .info = undefined, .owned = if (own) @constCast(ttf) else null };
        const p: [*c]const u8 = @ptrCast(ttf.ptr);
        const off = c.stbtt_GetFontOffsetForIndex(p, 0);
        if (c.stbtt_InitFont(&face.info, p, off) == 0) {
            if (own) self.gpa.free(@constCast(ttf));
            return error.FontInit;
        }
        const idx = @intFromEnum(style);
        // Sostituzione di una faccia: i glifi in cache di quello stile diventano
        // stale, ma la chiave include lo stile e non la faccia — si svuota la
        // cache per semplicità e correttezza (le facce si cambiano di rado).
        if (self.faces[idx]) |old| {
            if (old.owned) |b| self.gpa.free(b);
            self.clearCache();
        }
        self.faces[idx] = face;
    }

    /// Carica una faccia da un file .ttf/.otf su disco (byte posseduti dal font).
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

    /// Faccia effettiva per uno stile, con fallback: bold_italic→italic→bold→
    /// regular, così un font con sole regular+bold resta comunque utilizzabile.
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

    /// Glifo rasterizzato per (dimensione, stile, codepoint), da cache.
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

    /// Metriche verticali in pixel a una data dimensione/stile.
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

    /// Altezza di riga (avanzamento verticale) in pixel.
    pub fn lineHeight(self: *Font, px: u16, style: Style) i32 {
        const v = self.vmetrics(px, style);
        return v.ascent - v.descent + v.line_gap;
    }

    /// Larghezza in pixel di `s` (somma degli avanzamenti), per centrare/allineare.
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
    // 'A' ha copertura non nulla da qualche parte.
    var any: bool = false;
    for (g.bitmap) |cov| {
        if (cov > 0) any = true;
    }
    try std.testing.expect(any);

    // La misura di una stringa cresce con i caratteri.
    try std.testing.expect(font.measure(24, .regular, "Hi") > font.measure(24, .regular, "H"));
    // Il bold ripiega su una faccia valida (embeddata), lo spazio no-ink è ok.
    _ = try font.getGlyph(18, .bold, 'g');
}
