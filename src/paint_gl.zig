//! # paint_gl — motore 2D GPU (GLES3/WebGL2), impl di `paint.GlBackend`
//!
//! Slice 2 della milestone "Motori grafici agnostici". `paint.Canvas` è già agnostico
//! (Slice 1): quando ha un `gl: ?*GlBackend`, ogni primitivo delega a questa vtable
//! invece di rasterizzare su CPU. Qui la implementiamo come **recorder**: le op non
//! disegnano subito, ma accodano vertici (+ una lista di comandi) in memoria wasm; a fine
//! frame il lato piattaforma (JS/WebGL2) legge i buffer e li **replica** in draw call.
//!
//! ## Modello ubershader + command-list
//! Ogni primitivo → un quad (2 triangoli = 6 vertici) in coord pixel. La `cmds` è una
//! lista di RUN contigui `{start, count, fmt, tex, tw, th}` che preserva l'ORDINE di
//! disegno (z-order): le forme si fondono in un unico run `fmt=0`, ogni quad texturato è
//! un run a sé con il puntatore ai byte sorgente (icona RGBA o glifo R8). Il JS itera i
//! run: forme → drawArrays senza texture; texture → carica/binda la texture (cache per
//! puntatore) e disegna il range. Il fragment sceglie via `mode` (nel vertice):
//!   0 fill SDF rounded-rect per-corner · 1 stroke (banda SDF) · 2 texture RGBA (icona) ·
//!   3 quad pieno (segmenti) · 4 texture R8 coverage (glifo, tinta = colore).

const std = @import("std");
const paint = @import("paint.zig");
const Color = paint.Color;
const Corners = paint.Corners;
const Clip = paint.Canvas.Clip;
const TextOpts = paint.TextOpts;
const text = paint.text;

/// Un vertice dell'ubershader 2D. `extern` per un layout stabile leggibile da JS dalla
/// memoria wasm senza serializzazione. 23 f32 = 92 byte (6 attributi: 5×vec4 + 1×vec3).
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

/// Un run contiguo di vertici con lo stesso stato-texture. `fmt`: 0 = forme (nessuna
/// texture), 1 = RGBA (icona), 2 = R8 coverage (glifo). `tex` = puntatore ai byte sorgente
/// in memoria wasm (u32 su wasm32); `tw`/`th` = dimensioni sorgente.
pub const Cmd = extern struct {
    start: u32,
    count: u32,
    fmt: u32,
    tex: u32 = 0,
    tw: u32 = 0,
    th: u32 = 0,
};

pub const GlRecorder = struct {
    gpa: std.mem.Allocator,
    verts: std.ArrayList(Vertex) = .empty,
    cmds: std.ArrayList(Cmd) = .empty,

    pub fn init(gpa: std.mem.Allocator) GlRecorder {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *GlRecorder) void {
        self.verts.deinit(self.gpa);
        self.cmds.deinit(self.gpa);
    }
    pub fn reset(self: *GlRecorder) void {
        self.verts.clearRetainingCapacity();
        self.cmds.clearRetainingCapacity();
    }
    pub fn vertexBytes(self: *const GlRecorder) []const u8 {
        return std.mem.sliceAsBytes(self.verts.items);
    }
    pub fn vertexCount(self: *const GlRecorder) usize {
        return self.verts.items.len;
    }
    pub fn cmdBytes(self: *const GlRecorder) []const u8 {
        return std.mem.sliceAsBytes(self.cmds.items);
    }
    pub fn cmdCount(self: *const GlRecorder) usize {
        return self.cmds.items.len;
    }

    pub fn iface(self: *GlRecorder) paint.GlBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- gestione run/comandi -----------------------------------------------------------

    /// Registra un run di `n` vertici forma (fmt=0): estende l'ultimo run-forma contiguo
    /// se possibile, altrimenti ne apre uno nuovo. Preserva l'ordine di disegno.
    fn addShapeRun(self: *GlRecorder, start: usize, n: usize) void {
        if (self.cmds.items.len > 0) {
            const last = &self.cmds.items[self.cmds.items.len - 1];
            if (last.fmt == 0 and last.start + last.count == @as(u32, @intCast(start))) {
                last.count += @intCast(n);
                return;
            }
        }
        self.cmds.append(self.gpa, .{ .start = @intCast(start), .count = @intCast(n), .fmt = 0 }) catch {};
    }
    fn addTexRun(self: *GlRecorder, start: usize, n: usize, fmt: u32, tex: usize, tw: u32, th: u32) void {
        self.cmds.append(self.gpa, .{ .start = @intCast(start), .count = @intCast(n), .fmt = fmt, .tex = @intCast(tex), .tw = tw, .th = th }) catch {};
    }

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

    /// Quad forma (6 vertici, AA +1px), colori alto/basso (gradiente). Registra un run forma.
    fn quad(self: *GlRecorder, x: f32, y: f32, w: f32, h: f32, proto: Vertex, tl: Color, bl: Color) void {
        const pad: f32 = 1;
        const cs = [4][2]f32{ .{ x - pad, y - pad }, .{ x + w + pad, y - pad }, .{ x + w + pad, y + h + pad }, .{ x - pad, y + h + pad } };
        const cols = [4]Color{ tl, tl, bl, bl };
        const start = self.verts.items.len;
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
        self.addShapeRun(start, 6);
    }

    /// Quad texturato: 4 posizioni + 4 uv (angoli in ordine tl,tr,br,bl), tinta `col`,
    /// `mode` (2 RGBA / 4 R8). Registra un run texture verso `tex`.
    fn texQuad(self: *GlRecorder, pos: [4][2]f32, uv: [4][2]f32, col: Color, mode: f32, clip: ?Clip, fmt: u32, tex: usize, tw: u32, th: u32) void {
        const cl = clipTuple(clip);
        const start = self.verts.items.len;
        var v: Vertex = .{
            .r = col.r, .g = col.g, .b = col.b, .a = col.a,
            .mode = mode,
            .clip_x0 = cl[0], .clip_y0 = cl[1], .clip_x1 = cl[2], .clip_y1 = cl[3],
        };
        for ([6]usize{ 0, 1, 2, 0, 2, 3 }) |i| {
            v.x = pos[i][0];
            v.y = pos[i][1];
            v.u = uv[i][0];
            v.v = uv[i][1];
            self.verts.append(self.gpa, v) catch return;
        }
        self.addTexRun(start, 6, fmt, tex, tw, th);
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
        const start = self.verts.items.len;
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
        self.addShapeRun(start, 6);
    }
    fn strokeRoundedRect(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, radius: f32, stroke: f32, color: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        self.quad(x, y, w, h, shapeProto(x, y, w, h, Corners.all(radius), 1, stroke, clip), color, color);
    }
    fn blitImage(ptr: *anyopaque, dst_x: i32, dst_y: i32, dst_w: u32, dst_h: u32, src: []const u8, src_w: u32, src_h: u32, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        if (src.len == 0 or src_w == 0 or src_h == 0) return;
        const x0: f32 = @floatFromInt(dst_x);
        const y0: f32 = @floatFromInt(dst_y);
        const x1 = x0 + @as(f32, @floatFromInt(dst_w));
        const y1 = y0 + @as(f32, @floatFromInt(dst_h));
        const pos = [4][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
        const uv = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        self.texQuad(pos, uv, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 2, clip, 1, @intFromPtr(src.ptr), src_w, src_h);
    }
    fn blitMask(ptr: *anyopaque, dst_x: i32, dst_y: i32, dst_w: u32, dst_h: u32, src: []const u8, src_w: u32, src_h: u32, tint: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        if (src.len == 0 or src_w == 0 or src_h == 0) return;
        const x0: f32 = @floatFromInt(dst_x);
        const y0: f32 = @floatFromInt(dst_y);
        const x1 = x0 + @as(f32, @floatFromInt(dst_w));
        const y1 = y0 + @as(f32, @floatFromInt(dst_h));
        const pos = [4][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
        const uv = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        // mode 5 = maschera RGBA (sample .a) tinta da `tint`; fmt 1 (texture RGBA). Il
        // sorgente è STATICO (icona baked) → puntatore stabile e cacheable.
        self.texQuad(pos, uv, tint, 5, clip, 1, @intFromPtr(src.ptr), src_w, src_h);
    }
    fn blitImageRot(ptr: *anyopaque, dx: f32, dy: f32, dw: f32, dh: f32, src: []const u8, src_w: u32, src_h: u32, angle: f32, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        if (src.len == 0 or src_w == 0 or src_h == 0) return;
        // (dx,dy) è il CENTRO (come lo chiama app.zig), dw×dh la dimensione, ruotato di `angle`.
        const c = @cos(angle);
        const s = @sin(angle);
        const hw = dw / 2;
        const hh = dh / 2;
        const local = [4][2]f32{ .{ -hw, -hh }, .{ hw, -hh }, .{ hw, hh }, .{ -hw, hh } };
        var pos: [4][2]f32 = undefined;
        for (local, 0..) |l, i| pos[i] = .{ dx + l[0] * c - l[1] * s, dy + l[0] * s + l[1] * c };
        const uv = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        self.texQuad(pos, uv, .{ .r = 1, .g = 1, .b = 1, .a = 1 }, 2, clip, 1, @intFromPtr(src.ptr), src_w, src_h);
    }
    fn drawText(ptr: *anyopaque, font: *text.Font, x: i32, baseline_y: i32, s: []const u8, opts: TextOpts, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        // Stessa disposizione di paint.Canvas.drawText: pen glyph-by-glyph con kerning e
        // sub-pixel; ogni glifo → un quad texture R8 (coverage) tinto dal colore del testo.
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
                const x0 = ipen_x + @as(f32, @floatFromInt(g.xoff));
                const y0: f32 = @floatFromInt(baseline_y + g.yoff);
                const x1 = x0 + @as(f32, @floatFromInt(g.w));
                const y1 = y0 + @as(f32, @floatFromInt(g.h));
                const pos = [4][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
                const uv = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
                self.texQuad(pos, uv, opts.color, 4, clip, 2, @intFromPtr(g.bitmap.ptr), @intCast(g.w), @intCast(g.h));
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

test "recorder: un fill → 6 vertici, 1 run forma; reset azzera" {
    var rec = GlRecorder.init(std.testing.allocator);
    defer rec.deinit();
    const b = rec.iface();
    b.vtable.fillRoundedRect(b.ptr, 10, 20, 100, 40, 8, .{ .r = 1, .g = 0, .b = 0, .a = 1 }, null);
    try std.testing.expectEqual(@as(usize, 6), rec.vertexCount());
    try std.testing.expectEqual(@as(usize, 1), rec.cmdCount());
    rec.reset();
    try std.testing.expectEqual(@as(usize, 0), rec.vertexCount());
    try std.testing.expectEqual(@as(usize, 0), rec.cmdCount());
}
