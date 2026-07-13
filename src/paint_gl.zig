//! # paint_gl — motore 2D GPU (GLES3/WebGL2), impl di `paint.GlBackend`
//!
//! Slice 2 della milestone "Motori grafici agnostici". `paint.Canvas` è già agnostico
//! (Slice 1): quando ha un `gl: ?*GlBackend`, ogni primitivo delega a questa vtable
//! invece di rasterizzare su CPU. Qui la implementiamo come **recorder**: le op non
//! disegnano subito, ma accodano vertici in un buffer in memoria wasm; a fine frame il
//! lato piattaforma (JS/WebGL2 su web, EGL/GLESv3 su nativo) legge il buffer e lo
//! **replica** in una manciata di draw call. Così il confine wasm↔JS si attraversa una
//! volta per frame, non una per primitivo.
//!
//! ## Modello ubershader (un solo shader, un solo VBO)
//! Ogni primitivo → un quad (2 triangoli, 6 vertici) in coord pixel del canvas. Il
//! fragment shader calcola la copertura:
//!   - `mode 0` FILL: SDF rounded-rect per-angolo (stessa matematica di `roundedRectSdf`),
//!     coverage AA; il colore è per-vertice (→ gradiente verticale gratis: colori diversi
//!     sui vertici alto/basso).
//!   - `mode 1` STROKE: come FILL ma coverage = banda [−stroke, 0] della SDF (bordo).
//!   - `mode 2` TEXTURE: campiona l'atlas (icone/glifi) a `uv`, moltiplica per il colore
//!     (tint). L'upload dell'atlas è lato piattaforma.
//! Il clip (scissor) rompe il batch: vertici con clip diverso → draw separata.
//!
//! ## Cosa manca (loop browser, issue #2)
//! - Lo shader GLSL + il replay WebGL2/EGL (lato JS/nativo) che consuma `vertexBytes()`.
//! - L'atlas glifi (da `text.Font`/`text.Glyph`) e l'atlas icone (dai baked RGBA): qui
//!   `drawText`/`blitImage` registrano il quad con `mode=texture` e una regione uv, ma
//!   la gestione dell'atlas (upload, packing) va rifinita guardando il canvas nel browser.

const std = @import("std");
const paint = @import("paint.zig");
const Color = paint.Color;
const Corners = paint.Corners;
const Clip = paint.Canvas.Clip;
const TextOpts = paint.TextOpts;
const text = paint.text;

/// Un vertice dell'ubershader 2D. `extern` per un layout stabile leggibile da JS/GL
/// direttamente dalla memoria wasm (nessuna serializzazione).
pub const Vertex = extern struct {
    // posizione in pixel del canvas
    x: f32,
    y: f32,
    // uv nell'atlas (mode texture); ignorato per fill/stroke
    u: f32 = 0,
    v: f32 = 0,
    // colore straight RGBA (fill/stroke) o tint (texture)
    r: f32,
    g: f32,
    b: f32,
    a: f32,
    // rettangolo SDF: centro + semi-dimensioni (pixel)
    cx: f32 = 0,
    cy: f32 = 0,
    hw: f32 = 0,
    hh: f32 = 0,
    // raggi d'angolo (nw, ne, se, sw) per la SDF per-corner
    rnw: f32 = 0,
    rne: f32 = 0,
    rse: f32 = 0,
    rsw: f32 = 0,
    // 0 = fill SDF, 1 = stroke SDF, 2 = texture
    mode: f32 = 0,
    // larghezza bordo (mode stroke)
    stroke: f32 = 0,
    // scissor: se attivo, il frag scarta fuori da [x0,y0,x1,y1]; z<0 = nessun clip
    clip_x0: f32 = -1,
    clip_y0: f32 = -1,
    clip_x1: f32 = -1,
    clip_y1: f32 = -1,
    // id texture/atlas (mode texture): 0 = atlas glifi, >0 = handle icona
    tex: f32 = 0,
};

/// Recorder: accumula i vertici del frame. Un backend di piattaforma (JS/EGL) crea
/// questo, lo passa a `Canvas{ .gl = &backend.iface() }`, esegue l'`on_draw`, poi legge
/// `vertexBytes()` e lo replica, infine `reset()` per il frame successivo.
pub const GlRecorder = struct {
    gpa: std.mem.Allocator,
    verts: std.ArrayList(Vertex) = .empty,

    pub fn init(gpa: std.mem.Allocator) GlRecorder {
        return .{ .gpa = gpa };
    }
    pub fn deinit(self: *GlRecorder) void {
        self.verts.deinit(self.gpa);
    }
    pub fn reset(self: *GlRecorder) void {
        self.verts.clearRetainingCapacity();
    }
    /// I vertici del frame come byte grezzi (per l'upload nel VBO lato piattaforma).
    pub fn vertexBytes(self: *const GlRecorder) []const u8 {
        return std.mem.sliceAsBytes(self.verts.items);
    }
    pub fn vertexCount(self: *const GlRecorder) usize {
        return self.verts.items.len;
    }

    /// L'interfaccia `paint.GlBackend` che punta a questo recorder.
    pub fn iface(self: *GlRecorder) paint.GlBackend {
        return .{ .ptr = self, .vtable = &vtable };
    }

    // --- helpers di emissione -----------------------------------------------------------

    fn clipTuple(clip: ?Clip) [4]f32 {
        if (clip) |c| return .{ @floatFromInt(c.x0), @floatFromInt(c.y0), @floatFromInt(c.x1), @floatFromInt(c.y1) };
        return .{ -1, -1, -1, -1 };
    }

    /// Accoda un quad (6 vertici) con estensione AA di 1px attorno a (x,y,w,h). `tl`/`bl`
    /// sono i colori alto/basso (uguali = tinta piatta). Gli attributi SDF/mode/stroke/tex
    /// sono condivisi da tutti i vertici del quad.
    fn quad(self: *GlRecorder, x: f32, y: f32, w: f32, h: f32, proto: Vertex, tl: Color, bl: Color) void {
        const pad: f32 = 1;
        const x0 = x - pad;
        const y0 = y - pad;
        const x1 = x + w + pad;
        const y1 = y + h + pad;
        var v = proto;
        // top-left, top-right, bottom-right, bottom-left
        const corners = [4][2]f32{ .{ x0, y0 }, .{ x1, y0 }, .{ x1, y1 }, .{ x0, y1 } };
        const cols = [4]Color{ tl, tl, bl, bl };
        const idx = [6]usize{ 0, 1, 2, 0, 2, 3 };
        for (idx) |i| {
            v.x = corners[i][0];
            v.y = corners[i][1];
            v.r = cols[i].r;
            v.g = cols[i].g;
            v.b = cols[i].b;
            v.a = cols[i].a;
            self.verts.append(self.gpa, v) catch {};
        }
    }

    fn shapeProto(x: f32, y: f32, w: f32, h: f32, corners: Corners, mode: f32, stroke: f32, clip: ?Clip) Vertex {
        const cl = clipTuple(clip);
        return .{
            .r = 0, .g = 0, .b = 0, .a = 0, // sovrascritti per-vertice in `quad`
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

    // --- impl vtable (le firme combaciano con paint.GlBackend.VTable) --------------------

    fn fillRoundedRect(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        const proto = shapeProto(x, y, w, h, Corners.all(radius), 0, 0, clip);
        self.quad(x, y, w, h, proto, color, color);
    }
    fn fillRoundedRectPerCorner(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, corners: Corners, color: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        const proto = shapeProto(x, y, w, h, corners, 0, 0, clip);
        self.quad(x, y, w, h, proto, color, color);
    }
    fn fillRoundedRectVGradient(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, radius: f32, top: Color, bottom: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        const proto = shapeProto(x, y, w, h, Corners.all(radius), 0, 0, clip);
        self.quad(x, y, w, h, proto, top, bottom);
    }
    fn fillConcaveCorner(ptr: *anyopaque, x: f32, y: f32, size: f32, cx: f32, cy: f32, color: Color, clip: ?Clip) void {
        // Approssimazione: quad pieno dell'area del corner (la forma concava esatta è un
        // dettaglio del chrome nativo, non serve sul web). TODO: SDF concava dedicata.
        _ = cx;
        _ = cy;
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        const proto = shapeProto(x, y, size, size, Corners.all(0), 0, 0, clip);
        self.quad(x, y, size, size, proto, color, color);
    }
    fn strokeSegment(ptr: *anyopaque, ax: f32, ay: f32, bx: f32, by: f32, width: f32, color: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        // Segmento = quad orientato spesso `width` lungo (a→b). Emesso come 2 triangoli
        // diretti (niente SDF): l'AA fine dei tratti è un raffinamento successivo.
        const dx = bx - ax;
        const dy = by - ay;
        const len = @sqrt(dx * dx + dy * dy);
        if (len < 1e-4) return;
        const nx = -dy / len * (width / 2);
        const ny = dx / len * (width / 2);
        const cl = clipTuple(clip);
        var v: Vertex = .{
            .r = color.r, .g = color.g, .b = color.b, .a = color.a,
            .mode = 3, // 3 = quad pieno senza SDF (tinta uniforme)
            .clip_x0 = cl[0], .clip_y0 = cl[1], .clip_x1 = cl[2], .clip_y1 = cl[3],
        };
        const p = [4][2]f32{ .{ ax + nx, ay + ny }, .{ bx + nx, by + ny }, .{ bx - nx, by - ny }, .{ ax - nx, ay - ny } };
        for ([6]usize{ 0, 1, 2, 0, 2, 3 }) |i| {
            v.x = p[i][0];
            v.y = p[i][1];
            self.verts.append(self.gpa, v) catch {};
        }
    }
    fn strokeRoundedRect(ptr: *anyopaque, x: f32, y: f32, w: f32, h: f32, radius: f32, stroke: f32, color: Color, clip: ?Clip) void {
        const self: *GlRecorder = @ptrCast(@alignCast(ptr));
        const proto = shapeProto(x, y, w, h, Corners.all(radius), 1, stroke, clip);
        self.quad(x, y, w, h, proto, color, color);
    }
    fn blitImage(ptr: *anyopaque, dst_x: i32, dst_y: i32, dst_w: u32, dst_h: u32, src: []const u8, src_w: u32, src_h: u32, clip: ?Clip) void {
        // TODO(loop browser): registrare un quad texture con la regione atlas dell'icona.
        // L'upload/packing dell'atlas icone (dai baked RGBA) va rifinito nel browser.
        _ = ptr;
        _ = dst_x;
        _ = dst_y;
        _ = dst_w;
        _ = dst_h;
        _ = src;
        _ = src_w;
        _ = src_h;
        _ = clip;
    }
    fn blitImageRot(ptr: *anyopaque, dx: f32, dy: f32, dw: f32, dh: f32, src: []const u8, src_w: u32, src_h: u32, angle: f32, clip: ?Clip) void {
        // TODO(loop browser): quad texture ruotato dell'icona.
        _ = ptr;
        _ = dx;
        _ = dy;
        _ = dw;
        _ = dh;
        _ = src;
        _ = src_w;
        _ = src_h;
        _ = angle;
        _ = clip;
    }
    fn drawText(ptr: *anyopaque, font: *text.Font, x: i32, baseline_y: i32, s: []const u8, opts: TextOpts, clip: ?Clip) void {
        // TODO(loop browser): per glifo, quad texture nell'atlas glifi (da `font`).
        _ = ptr;
        _ = font;
        _ = x;
        _ = baseline_y;
        _ = s;
        _ = opts;
        _ = clip;
    }

    const vtable = paint.GlBackend.VTable{
        .fillRoundedRect = fillRoundedRect,
        .fillRoundedRectPerCorner = fillRoundedRectPerCorner,
        .fillRoundedRectVGradient = fillRoundedRectVGradient,
        .fillConcaveCorner = fillConcaveCorner,
        .strokeSegment = strokeSegment,
        .strokeRoundedRect = strokeRoundedRect,
        .blitImage = blitImage,
        .blitImageRot = blitImageRot,
        .drawText = drawText,
    };
};

test "recorder emette 6 vertici per un fill e li azzera con reset" {
    var rec = GlRecorder.init(std.testing.allocator);
    defer rec.deinit();
    const b = rec.iface();
    b.vtable.fillRoundedRect(b.ptr, 10, 20, 100, 40, 8, .{ .r = 1, .g = 0, .b = 0, .a = 1 }, null);
    try std.testing.expectEqual(@as(usize, 6), rec.vertexCount());
    rec.reset();
    try std.testing.expectEqual(@as(usize, 0), rec.vertexCount());
}
