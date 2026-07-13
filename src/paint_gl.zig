//! # paint_gl — motore 2D GPU (GLES3/WebGL2), impl di `paint.GlBackend`
//!
//! `paint.Canvas` è agnostico (Slice 1): con un `gl` ogni primitivo delega qui invece di
//! rasterizzare su CPU. Recorder: le op accodano vertici in memoria wasm; il lato
//! piattaforma (JS/WebGL2) li carica e disegna.
//!
//! ## Atlante → UNA draw call per frame
//! Il collo di bottiglia era ~1 draw call PER glifo/icona (texture propria). Ora glifi e
//! icone finiscono in UN atlante RGBA condiviso (packer a scaffali), e ogni quad porta UV
//! già relative all'atlante. Con l'atlante legato una volta, l'INTERO frame (forme + testo
//! + icone) è UNA `drawArrays`: le forme (mode 0/1/3) ignorano la texture, i quad texturati
//! (mode 2 full-color / 4 coverage) campionano l'atlante. Contenuto atlante:
//!   - icone oggetto (full color) → RGBA copiato → mode 2 (texture*colore).
//!   - glifi e maschere-icona UI → (bianco, coverage in ALPHA) → mode 4 (colore, a*tint).
//! L'atlante cresce monotòno (glifi/icone aggiunti una volta, mai rimossi); il JS lo carica
//! solo quando cambia (banda di righe "sporche").

const std = @import("std");
const paint = @import("paint.zig");
const Color = paint.Color;
const Corners = paint.Corners;
const Clip = paint.Canvas.Clip;
const TextOpts = paint.TextOpts;
const text = paint.text;

pub const atlas_dim: u32 = 2048;

/// Vertice ubershader 2D. `extern` per layout stabile letto da JS. UV sono relative
/// all'ATLANTE (0..1 sull'atlante intero), non al singolo bitmap.
pub const Vertex = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    u: f32 = 0,
    v: f32 = 0,
    r: f32 = 0,
    g: f32 = 0,
    b: f32 = 0,
    a: f32 = 0,
    cx: f32 = 0,
    cy: f32 = 0,
    hw: f32 = 0,
    hh: f32 = 0,
    rnw: f32 = 0,
    rne: f32 = 0,
    rse: f32 = 0,
    rsw: f32 = 0,
    mode: f32 = 0,
    stroke: f32 = 0,
    clip_x0: f32 = -1,
    clip_y0: f32 = -1,
    clip_x1: f32 = -1,
    clip_y1: f32 = -1,
    tex: f32 = 0,
};

const Slot = struct { x: u32, y: u32, w: u32, h: u32 };
const Ensured = struct { slot: Slot, is_new: bool };

pub const GlRecorder = struct {
    gpa: std.mem.Allocator,
    verts: std.ArrayList(Vertex) = .empty,

    // atlante RGBA 2048² (lazy) + packer a scaffali + mappa puntatore→slot (persistente).
    atlas: []u8 = &.{},
    slots: std.AutoHashMapUnmanaged(usize, Slot) = .empty,
    shelf_x: u32 = 0,
    shelf_y: u32 = 0,
    shelf_h: u32 = 0,
    // banda di righe modificate da caricare in GPU (dirty). lo>hi = pulito.
    dirty_lo: u32 = atlas_dim,
    dirty_hi: u32 = 0,

    pub fn init(gpa: std.mem.Allocator) GlRecorder {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *GlRecorder) void {
        self.verts.deinit(self.gpa);
        self.slots.deinit(self.gpa);
        if (self.atlas.len > 0) self.gpa.free(self.atlas);
    }
    /// Azzera i vertici del frame (l'atlante e gli slot PERSISTONO tra i frame).
    pub fn reset(self: *GlRecorder) void {
        self.verts.clearRetainingCapacity();
    }
    pub fn vertexBytes(self: *const GlRecorder) []const u8 {
        return std.mem.sliceAsBytes(self.verts.items);
    }
    pub fn vertexCount(self: *const GlRecorder) usize {
        return self.verts.items.len;
    }
    pub fn atlasPtr(self: *const GlRecorder) [*]const u8 {
        return self.atlas.ptr;
    }
    pub fn atlasReady(self: *const GlRecorder) bool {
        return self.atlas.len > 0;
    }
    pub fn dirtyLo(self: *const GlRecorder) u32 {
        return self.dirty_lo;
    }
    pub fn dirtyHi(self: *const GlRecorder) u32 {
        return self.dirty_hi;
    }
    /// Il JS chiama questo dopo aver caricato la banda sporca.
    pub fn clearDirty(self: *GlRecorder) void {
        self.dirty_lo = atlas_dim;
        self.dirty_hi = 0;
    }

    pub fn iface(self: *GlRecorder) paint.GlBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- atlante ------------------------------------------------------------------------

    fn ensureAtlas(self: *GlRecorder) bool {
        if (self.atlas.len > 0) return true;
        self.atlas = self.gpa.alloc(u8, @as(usize, atlas_dim) * atlas_dim * 4) catch return false;
        @memset(self.atlas, 0);
        return true;
    }
    fn markDirty(self: *GlRecorder, y0: u32, y1: u32) void {
        if (y0 < self.dirty_lo) self.dirty_lo = y0;
        if (y1 > self.dirty_hi) self.dirty_hi = y1;
    }
    /// Slot per un bitmap (chiave = puntatore sorgente, statico per glifi/icone baked).
    /// Alloca a scaffali; null se l'atlante è pieno. `is_new` → il chiamante copia i pixel.
    fn ensureSlot(self: *GlRecorder, key: usize, w: u32, h: u32) ?Ensured {
        if (self.slots.get(key)) |s| return .{ .slot = s, .is_new = false };
        if (!self.ensureAtlas()) return null;
        if (w == 0 or h == 0 or w > atlas_dim or h > atlas_dim) return null;
        if (self.shelf_x + w + 1 > atlas_dim) {
            self.shelf_y += self.shelf_h;
            self.shelf_x = 0;
            self.shelf_h = 0;
        }
        if (self.shelf_y + h + 1 > atlas_dim) return null; // atlante pieno
        const s = Slot{ .x = self.shelf_x, .y = self.shelf_y, .w = w, .h = h };
        self.shelf_x += w + 1;
        if (h + 1 > self.shelf_h) self.shelf_h = h + 1;
        self.slots.put(self.gpa, key, s) catch return null;
        return .{ .slot = s, .is_new = true };
    }
    fn copyRgba(self: *GlRecorder, s: Slot, src: []const u8) void {
        var yy: u32 = 0;
        while (yy < s.h) : (yy += 1) {
            const dst_off = (@as(usize, s.y + yy) * atlas_dim + s.x) * 4;
            const src_off = @as(usize, yy) * s.w * 4;
            const n = @as(usize, s.w) * 4;
            @memcpy(self.atlas[dst_off .. dst_off + n], src[src_off .. src_off + n]);
        }
        self.markDirty(s.y, s.y + s.h);
    }
    /// Copia una COVERAGE nell'atlante come (bianco, alpha=coverage). `stride`=byte/px del
    /// sorgente, `aoff`=offset del canale coverage (1 per R8, 4/idx3 per RGBA-maschera).
    fn copyCoverage(self: *GlRecorder, s: Slot, src: []const u8, stride: u32, aoff: u32) void {
        var yy: u32 = 0;
        while (yy < s.h) : (yy += 1) {
            var xx: u32 = 0;
            while (xx < s.w) : (xx += 1) {
                const dst = (@as(usize, s.y + yy) * atlas_dim + (s.x + xx)) * 4;
                const cov = src[(@as(usize, yy) * s.w + xx) * stride + aoff];
                self.atlas[dst + 0] = 255;
                self.atlas[dst + 1] = 255;
                self.atlas[dst + 2] = 255;
                self.atlas[dst + 3] = cov;
            }
        }
        self.markDirty(s.y, s.y + s.h);
    }

    // --- emissione vertici --------------------------------------------------------------

    fn clipTuple(clip: ?Clip) [4]f32 {
        if (clip) |c| return .{ @floatFromInt(c.x0), @floatFromInt(c.y0), @floatFromInt(c.x1), @floatFromInt(c.y1) };
        return .{ -1, -1, -1, -1 };
    }

    fn shapeProto(x: f32, y: f32, w: f32, h: f32, corners: Corners, mode: f32, stroke: f32, clip: ?Clip) Vertex {
        const cl = clipTuple(clip);
        return .{
            .cx = x + w / 2,
            .cy = y + h / 2,
            .hw = w / 2,
            .hh = h / 2,
            .rnw = corners.nw,
            .rne = corners.ne,
            .rse = corners.se,
            .rsw = corners.sw,
            .mode = mode,
            .stroke = stroke,
            .clip_x0 = cl[0],
            .clip_y0 = cl[1],
            .clip_x1 = cl[2],
            .clip_y1 = cl[3],
        };
    }

    fn quad(self: *GlRecorder, x: f32, y: f32, w: f32, h: f32, proto: Vertex, tl: Color, bl: Color) void {
        const pad: f32 = 1;
        const cs = [4][2]f32{ .{ x - pad, y - pad }, .{ x + w + pad, y - pad }, .{ x + w + pad, y + h + pad }, .{ x - pad, y + h + pad } };
        const cols = [4]Color{ tl, tl, bl, bl };
        var v = proto;
        for ([6]usize{ 0, 1, 2, 0, 2, 3 }) |i| {
            v.x = cs[i][0];
            v.y = cs[i][1];
            v.r = cols[i].r;
            v.g = cols[i].g;
            v.b = cols[i].b;
            v.a = cols[i].a;
            self.verts.append(self.gpa, v) catch return;
        }
    }

    /// Quad texturato con UV relative all'ATLANTE (dallo slot), 4 posizioni in ordine
    /// tl,tr,br,bl, tinta `col`, `mode` (2 full-color / 4 coverage).
    fn atlasQuad(self: *GlRecorder, pos: [4][2]f32, s: Slot, col: Color, mode: f32, clip: ?Clip) void {
        const cl = clipTuple(clip);
        const inv: f32 = 1.0 / @as(f32, @floatFromInt(atlas_dim));
        const ua = @as(f32, @floatFromInt(s.x)) * inv;
        const va = @as(f32, @floatFromInt(s.y)) * inv;
        const ub = @as(f32, @floatFromInt(s.x + s.w)) * inv;
        const vb = @as(f32, @floatFromInt(s.y + s.h)) * inv;
        const uv = [4][2]f32{ .{ ua, va }, .{ ub, va }, .{ ub, vb }, .{ ua, vb } };
        var vv: Vertex = .{
            .r = col.r, .g = col.g, .b = col.b, .a = col.a,
            .mode = mode,
            .clip_x0 = cl[0], .clip_y0 = cl[1], .clip_x1 = cl[2], .clip_y1 = cl[3],
        };
        for ([6]usize{ 0, 1, 2, 0, 2, 3 }) |i| {
            vv.x = pos[i][0];
            vv.y = pos[i][1];
            vv.u = uv[i][0];
            vv.v = uv[i][1];
            self.verts.append(self.gpa, vv) catch return;
        }
    }

    // --- impl vtable --------------------------------------------------------------------

    fn fillRoundedRect(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        self.quad(x, y, w, h, shapeProto(x, y, w, h, Corners.all(radius), 0, 0, clip), color, color);
    }
    fn fillRoundedRectPerCorner(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, corners: Corners, color: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        self.quad(x, y, w, h, shapeProto(x, y, w, h, corners, 0, 0, clip), color, color);
    }
    fn fillRoundedRectVGradient(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, radius: f32, top: Color, bottom: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        self.quad(x, y, w, h, shapeProto(x, y, w, h, Corners.all(radius), 0, 0, clip), top, bottom);
    }
    fn fillConcaveCorner(ptr: *anyopaque, x: f32, y: f32, size: f32, cx: f32, cy: f32, color: Color, clip: ?Clip) void {
        _ = cx;
        _ = cy;
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        self.quad(x, y, size, size, shapeProto(x, y, size, size, Corners.all(0), 0, 0, clip), color, color);
    }
    fn strokeSegment(ptr: *anyopaque, ax: f32, ay: f32, bx: f32, by: f32, width: f32, color: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        const dx = bx - ax;
        const dy = by - ay;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 1e-4) return;
        const nx = -dy / len * (width / 2);
        const ny = dx / len * (width / 2);
        const cl = clipTuple(clip);
        var v: Vertex = .{
            .r = color.r, .g = color.g, .b = color.b, .a = color.a,
            .mode = 3,
            .clip_x0 = cl[0], .clip_y0 = cl[1], .clip_x1 = cl[2], .clip_y1 = cl[3],
        };
        const p = [4][2]f32{ .{ ax + nx, ay + ny }, .{ bx + nx, by + ny }, .{ bx - nx, by - ny }, .{ ax - nx, ay - ny } };
        for ([6]usize{ 0, 1, 2, 0, 2, 3 }) |i| {
            v.x = p[i][0];
            v.y = p[i][1];
            self.verts.append(self.gpa, v) catch return;
        }
    }
    fn strokeRoundedRect(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, radius: f32, stroke: f32, color: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        self.quad(x, y, w, h, shapeProto(x, y, w, h, Corners.all(radius), 1, stroke, clip), color, color);
    }
    fn blitImage(ptr: *anyopaque, dst_x: i32, dst_y: i32, dst_w: u32, dst_h: u32, src: []const u8, src_w: u32, src_h: u32, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        if (src.len == 0 or src_w == 0 or src_h == 0) return;
        const e = self.ensureSlot(@intFromPtr(src.ptr), src_w, src_h) orelse return;
        if (e.is_new) self.copyRgba(e.slot, src);
        const x0: f32 = @floatFromInt(dst_x);
        const y0: f32 = @floatFromInt(dst_y);
        const x1 = x0 + @as(f32, @floatFromInt(dst_w));
        const y1 = y0 + @as(f32, @floatFromInt(dst_h));
        self.atlasQuad(.{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } }, e.slot, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 2, clip);
    }
    fn blitMask(ptr: *anyopaque, dst_x: i32, dst_y: i32, dst_w: u32, dst_h: u32, src: []const u8, src_w: u32, src_h: u32, tint: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        if (src.len == 0 or src_w == 0 or src_h == 0) return;
        const e = self.ensureSlot(@intFromPtr(src.ptr), src_w, src_h) orelse return;
        if (e.is_new) self.copyCoverage(e.slot, src, 4, 3); // RGBA: coverage = canale alpha
        const x0: f32 = @floatFromInt(dst_x);
        const y0: f32 = @floatFromInt(dst_y);
        const x1 = x0 + @as(f32, @floatFromInt(dst_w));
        const y1 = y0 + @as(f32, @floatFromInt(dst_h));
        self.atlasQuad(.{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } }, e.slot, tint, 4, clip);
    }
    fn blitImageRot(ptr: *anyopaque, dx: f32, dy: f32, dw: f32, dh: f32, src: []const u8, src_w: u32, src_h: u32, angle: f32, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        if (src.len == 0 or src_w == 0 or src_h == 0) return;
        const e = self.ensureSlot(@intFromPtr(src.ptr), src_w, src_h) orelse return;
        if (e.is_new) self.copyRgba(e.slot, src);
        const c = @cos(angle);
        const s = @sin(angle);
        const hw = dw / 2;
        const hh = dh / 2;
        const local = [4][2]f32{ .{ -hw, -hh }, .{ hw, -hh }, .{ hw, hh }, .{ -hw, hh } };
        var pos: [4][2]f32 = undefined;
        for (local, 0..) |l, i| pos[i] = .{ dx + l[0] * c - l[1] * s, dy + l[0] * s + l[1] * c };
        self.atlasQuad(pos, e.slot, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 2, clip);
    }
    fn drawText(ptr: *anyopaque, font: *text.Font, x: i32, baseline_y: i32, s: []const u8, opts: TextOpts, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        var pen_x: f32 = @floatFromInt(x);
        var prev_cp: ?u32 = null;
        var i: usize = 0;
        while (i < s.len) {
            const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(i + seq, s.len);
            const cp: u32 = std.unicode.utf8Decode(s[i..end]) catch s[i];
            i = end;
            if (prev_cp) |prev| pen_x += font.getKernAdvance(opts.style, opts.size, prev, cp);
            const frac = pen_x - @floor(pen_x);
            const sub_x: u2 = @intCast(@as(i32, @intFromFloat(@round(frac * 4.0))) & 3);
            const g = font.getGlyph(opts.size, opts.style, sub_x, cp) catch continue;
            const ipen_x: f32 = @floor(pen_x + 0.5);
            if (g.bitmap.len != 0 and g.w > 0 and g.h > 0) {
                // chiave glifo: puntatore bitmap (stabile nella cache font). R8 coverage.
                if (self.ensureSlot(@intFromPtr(g.bitmap.ptr), @intCast(g.w), @intCast(g.h))) |e| {
                    if (e.is_new) self.copyCoverage(e.slot, g.bitmap, 1, 0);
                    const x0 = ipen_x + @as(f32, @floatFromInt(g.xoff));
                    const y0: f32 = @floatFromInt(baseline_y + g.yoff);
                    const x1 = x0 + @as(f32, @floatFromInt(g.w));
                    const y1 = y0 + @as(f32, @floatFromInt(g.h));
                    self.atlasQuad(.{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } }, e.slot, opts.color, 4, clip);
                }
            }
            pen_x += g.advance;
            prev_cp = cp;
        }
    }

    const vtable = paint.GlBackend.VTable{
        .fillRoundedRect = fillRoundedRect,
        .fillRoundedRectPerCorner = fillRoundedRectPerCorner,
        .fillRoundedRectVGradient = fillRoundedRectVGradient,
        .fillConcaveCorner = fillConcaveCorner,
        .strokeSegment = strokeSegment,
        .strokeRoundedRect = strokeRoundedRect,
        .blitImage = blitImage,
        .blitMask = blitMask,
        .blitImageRot = blitImageRot,
        .drawText = drawText,
    };
};

test "recorder: fill → 6 vertici; reset non tocca l'atlante" {
    var rec = GlRecorder.init(std.testing.allocator);
    defer rec.deinit();
    const b = rec.iface();
    b.vtable.fillRoundedRect(b.ptr, 10, 20, 100, 40, 8, .{ .r = 1, .g = 0, .b = 0, .a = 1 }, null);
    try std.testing.expectEqual(@as(usize, 6), rec.vertexCount());
    rec.reset();
    try std.testing.expectEqual(@as(usize, 0), rec.vertexCount());
}
