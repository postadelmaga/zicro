//! # zicro.paint — the software canvas
//!
//! Everything zicro puts on screen is drawn here, on the CPU, into a premultiplied
//! ARGB8888 buffer (the wl_shm wire format). The window chrome is analytic: a rounded
//! rectangle is a signed-distance function, the drop shadow is a smooth falloff of the
//! same SDF, anti-aliasing falls out of the distance for free. No textures, no GPU —
//! a decorated frame is just math over pixels.

const std = @import("std");
pub const text = @import("text.zig");

/// Text drawing options: pixel size, style (face) and color.
pub const TextOpts = struct {
    size: u16 = 14,
    style: text.Style = .regular,
    color: Color = .{ .r = 1, .g = 1, .b = 1, .a = 1 },
};

/// A straight (non-premultiplied) color; premultiplication happens at draw time.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,

    pub fn rgba(r: u8, g: u8, b: u8, a: f32) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = a,
        };
    }
};

/// Per-corner radii for a rounded rectangle, in screen space (y grows downward), so
/// `nw` is the top-left corner and `sw` the bottom-left. This is the shape the GPU
/// instanced-quad path wants too: one struct, four radii, drives rect (all 0), circle
/// (all = half the shorter side), pill, tab (top two only), or the window panel.
pub const Corners = struct {
    nw: f32 = 0,
    ne: f32 = 0,
    se: f32 = 0,
    sw: f32 = 0,

    /// The same radius on every corner (the plain rounded rect).
    pub fn all(r: f32) Corners {
        return .{ .nw = r, .ne = r, .se = r, .sw = r };
    }
    /// Round only the top two corners (tabs, sheet headers).
    pub fn top(r: f32) Corners {
        return .{ .nw = r, .ne = r, .se = 0, .sw = 0 };
    }
    /// Round only the bottom two corners.
    pub fn bottom(r: f32) Corners {
        return .{ .nw = 0, .ne = 0, .se = r, .sw = r };
    }
};

/// Signed distance from `(px,py)` to a rounded rectangle with independent corner radii:
/// negative inside. The active radius is picked by the quadrant the point falls in
/// (relative to the rect centre), then clamped to the box's half-extent so an oversized
/// radius degrades to a capsule/circle instead of inverting the field.
pub fn roundedRectSdfPerCorner(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32, c: Corners) f32 {
    const hw = w / 2.0;
    const hh = h / 2.0;
    const cx = x + hw;
    const cy = y + hh;
    const dx = px - cx;
    const dy = py - cy;
    // Quadrant select: right half → ne/se, left half → nw/sw; then bottom vs top by dy.
    const r_unclamped = if (dx > 0.0)
        (if (dy > 0.0) c.se else c.ne)
    else
        (if (dy > 0.0) c.sw else c.nw);
    const r = @min(r_unclamped, @min(hw, hh));
    const qx = @abs(dx) - (hw - r);
    const qy = @abs(dy) - (hh - r);
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - r;
}

/// Signed distance from point `(px, py)` to a rounded rectangle: negative inside.
/// Thin wrapper over [`roundedRectSdfPerCorner`] with one radius on every corner.
pub fn roundedRectSdf(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32, radius: f32) f32 {
    return roundedRectSdfPerCorner(px, py, x, y, w, h, Corners.all(radius));
}

/// Signed distance from `(px,py)` to the line segment `a`→`b`: the capsule/stadium
/// distance (zero on the segment's spine, growing outward). Feeds thin strokes — the
/// close ✕ and the minimize – are just two/one of these.
pub fn segmentSdf(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32) f32 {
    const pax = px - ax;
    const pay = py - ay;
    const bax = bx - ax;
    const bay = by - ay;
    const len2 = bax * bax + bay * bay;
    const h = if (len2 > 0.0) std.math.clamp((pax * bax + pay * bay) / len2, 0.0, 1.0) else 0.0;
    const dx = pax - bax * h;
    const dy = pay - bay * h;
    return @sqrt(dx * dx + dy * dy);
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    // Degenerate edges would divide by zero (NaN); step instead — same guard as anim.smoothstep.
    if (edge1 == edge0) return if (x < edge0) 0.0 else 1.0;
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Pixel coverage of an SDF: full at d <= -0.5, zero at d >= 0.5.
fn coverage(d: f32) f32 {
    return std.math.clamp(0.5 - d, 0.0, 1.0);
}

/// sRGB (0..1) → linear light (0..1). Needed to blend glyph antialiasing in
/// linear space (typographic rendering): blending coverage directly in sRGB
/// thins and dirties text edges, especially on a dark background.
/// Pub: le app con raster di testo propri (es. il layout documento di zuer)
/// riusano ESATTAMENTE queste curve, così la resa tipografica è identica per
/// costruzione ovunque.
pub fn srgbToLinear(u: f32) f32 {
    return if (u <= 0.04045) u / 12.92 else std.math.pow(f32, (u + 0.055) / 1.055, 2.4);
}

/// Linear light (0..1) → sRGB (0..1).
pub fn linearToSrgb(u: f32) f32 {
    const x = std.math.clamp(u, 0.0, 1.0);
    return if (x <= 0.0031308) x * 12.92 else 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
}

/// macOS-style "font smoothing": lifts mid coverage to slightly fatten the
/// strokes (macOS renders text fuller and softer than raw grayscale). Exponent
/// < 1 → fuller.
pub fn smoothCoverage(a: f32) f32 {
    return std.math.pow(f32, std.math.clamp(a, 0.0, 1.0), 0.72);
}

/// [`smoothCoverage`] tabulated over every u8 coverage value: glyph blitting reads
/// coverage as a byte, so the table is exact (no interpolation) and replaces a `pow`
/// per pixel with a load.
pub const smooth_coverage_lut: [256]f32 = blk: {
    @setEvalBranchQuota(2_000_000);
    var t: [256]f32 = undefined;
    for (&t, 0..) |*v, i| v.* = smoothCoverage(@as(f32, @floatFromInt(i)) / 255.0);
    break :blk t;
};

/// LUT sRGB byte (0..255) → luce lineare (0..1), per i loop di blending
/// byte-oriented delle app (un load al posto di un `pow` per canale).
pub const srgb_byte_to_linear: [256]f32 = blk: {
    @setEvalBranchQuota(20_000);
    var t: [256]f32 = undefined;
    for (&t, 0..) |*v, i| {
        const u = @as(f64, @floatFromInt(i)) / 255.0;
        v.* = @floatCast(if (u <= 0.04045) u / 12.92 else std.math.pow(f64, (u + 0.055) / 1.055, 2.4));
    }
    break :blk t;
};

/// LUT lineare (0..1) → sRGB byte, indicizzata con `round(x*4095)`. Con 4096
/// campioni l'errore di quantizzazione resta entro ~mezzo LSB anche nel tratto
/// più ripido della curva (quello lineare vicino allo zero).
pub const linear_to_srgb_byte: [4096]u8 = blk: {
    @setEvalBranchQuota(2_000_000);
    var t: [4096]u8 = undefined;
    for (&t, 0..) |*v, i| {
        const u = @as(f64, @floatFromInt(i)) / 4095.0;
        const s = if (u <= 0.0031308) u * 12.92 else 1.055 * std.math.pow(f64, u, 1.0 / 2.4) - 0.055;
        v.* = @intFromFloat(@round(std.math.clamp(s, 0.0, 1.0) * 255.0));
    }
    break :blk t;
};

/// Luce lineare (0..1) → sRGB byte via [`linear_to_srgb_byte`].
pub fn linearToSrgbByte(x: f32) u8 {
    const q: u32 = @intFromFloat(@round(std.math.clamp(x, 0.0, 1.0) * 4095.0));
    return linear_to_srgb_byte[q];
}

/// Pack already-premultiplied channels (each in [0,1]) into an ARGB8888 pixel.
fn packPremul(r: f32, g: f32, b: f32, a: f32) u32 {
    const ai: u32 = @intFromFloat(std.math.clamp(a, 0.0, 1.0) * 255.0 + 0.5);
    const ri: u32 = @intFromFloat(std.math.clamp(r, 0.0, 1.0) * 255.0 + 0.5);
    const gi: u32 = @intFromFloat(std.math.clamp(g, 0.0, 1.0) * 255.0 + 0.5);
    const bi: u32 = @intFromFloat(std.math.clamp(b, 0.0, 1.0) * 255.0 + 0.5);
    return (ai << 24) | (ri << 16) | (gi << 8) | bi;
}

/// Unpack an ARGB8888 pixel into premultiplied `{ r, g, b, a }` floats.
fn unpackPremul(px: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt((px >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((px >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(px & 0xff)) / 255.0,
        @as(f32, @floatFromInt(px >> 24)) / 255.0,
    };
}

/// Pack straight-alpha channels (each in [0,1]) into an RGBA8888 pixel — bytes
/// `R,G,B,A` in memory (little-endian), the layout an app hands to a compositor.
fn packStraight(r: f32, g: f32, b: f32, a: f32) u32 {
    const ri: u32 = @intFromFloat(std.math.clamp(r, 0.0, 1.0) * 255.0 + 0.5);
    const gi: u32 = @intFromFloat(std.math.clamp(g, 0.0, 1.0) * 255.0 + 0.5);
    const bi: u32 = @intFromFloat(std.math.clamp(b, 0.0, 1.0) * 255.0 + 0.5);
    const ai: u32 = @intFromFloat(std.math.clamp(a, 0.0, 1.0) * 255.0 + 0.5);
    return (ai << 24) | (bi << 16) | (gi << 8) | ri;
}

/// Unpack an RGBA8888 pixel (bytes `R,G,B,A`) into straight `{ r, g, b, a }` floats.
fn unpackStraight(px: u32) [4]f32 {
    return .{
        @as(f32, @floatFromInt(px & 0xff)) / 255.0,
        @as(f32, @floatFromInt((px >> 8) & 0xff)) / 255.0,
        @as(f32, @floatFromInt((px >> 16) & 0xff)) / 255.0,
        @as(f32, @floatFromInt(px >> 24)) / 255.0,
    };
}

/// How the window chrome looks. All lengths are in buffer pixels.
pub const Style = struct {
    /// Corner radius of the glass panel.
    corner_radius: f32 = 18,
    /// Transparent gutter around the panel that hosts the drop shadow.
    margin: u32 = 44,
    /// Penumbra half-width of the shadow falloff.
    shadow_blur: f32 = 26,
    /// Vertical offset of the shadow, a light-from-above cue.
    shadow_offset_y: f32 = 10,
    /// Peak shadow opacity.
    shadow_alpha: f32 = 0.55,
    /// The translucent panel fill; the compositor blur behind it makes it frosted.
    glass: Color = Color.rgba(22, 22, 32, 0.58),
    /// Opacity of the 1px highlight ring that catches the panel edge.
    border_alpha: f32 = 0.22,
    /// Progressive fade-out width of the glass color near the edges (0 to disable).
    glass_fade_width: f32 = 0,
    /// Sheen metallico: gradiente verticale del vetro (schiarisce in alto, scurisce in basso).
    /// 0 = piatto. ~0.3 = metallizzato/bagnato.
    sheen: f32 = 0,
    /// Highlight speculare vicino al bordo superiore (riflesso vetroso/bagnato). 0 = off.
    specular: f32 = 0,
    /// Corner radius of the content frames.
    content_radius: f32 = 14,
    /// Progressive fade-out width of the content near its edges (0 to disable).
    content_fade_width: f32 = 0,
    /// Inset of the compositor blur region relative to the panel (0 for full panel blur).
    blur_inset: f32 = 0,
    /// Width of the animated border band: blitted frames only show within this
    /// distance of the panel edge, fading toward the center (0 = frames fill the
    /// panel). Orthogonal to the presets — compose it onto any of them with
    /// [`withBorderAnim`].
    border_anim_width: f32 = 0,

    /// Copy of the style with the animated border band enabled; composes with every
    /// preset: `Style.fluent().withBorderAnim(80)`.
    pub fn withBorderAnim(self: Style, width: f32) Style {
        var s = self;
        s.border_anim_width = width;
        return s;
    }

    /// Preset: Apple macOS Vision Pro Glassmorphism
    pub fn macos() Style {
        return .{
            .corner_radius = 28,
            .glass = Color.rgba(255, 255, 255, 0.08),
            .border_alpha = 0.35,
            .shadow_alpha = 0.30,
            .shadow_blur = 30,
            .shadow_offset_y = 12,
        };
    }

    /// Preset: Windows 11 Fluent Design / Acrylic
    pub fn fluent() Style {
        return .{
            .corner_radius = 12,
            .glass = Color.rgba(32, 32, 32, 0.65),
            .border_alpha = 0.15,
            .shadow_alpha = 0.40,
            .shadow_blur = 20,
            .shadow_offset_y = 8,
        };
    }

    /// Preset: Carbon Glass — vetro scuro metallizzato/bagnato, angoli arrotondati e fine
    /// cornice vetrosa. Pensato per titlebar/chrome sopra il blur del compositor.
    pub fn carbon() Style {
        return .{
            .corner_radius = 20,
            .glass = Color.rgba(24, 26, 32, 0.62),
            .border_alpha = 0.30,
            .sheen = 0.38,
            .specular = 0.14,
            .shadow_alpha = 0.45,
            .shadow_blur = 28,
            .shadow_offset_y = 12,
            .blur_inset = 12,
        };
    }
    /// Preset: Aurora Glass (inset blur with wide color fade)
    pub fn aurora() Style {
        return .{
            .corner_radius = 24,
            .glass = Color.rgba(137, 180, 250, 0.40),
            .glass_fade_width = 30.0,
            .blur_inset = 16.0,
            .border_alpha = 0.20,
        };
    }

    /// Preset: Material Design 3 (highly rounded, high opacity surface, flat borders)
    pub fn material() Style {
        return .{
            .corner_radius = 28,
            .glass = Color.rgba(28, 27, 31, 0.85),
            .border_alpha = 0.0,
            .shadow_alpha = 0.45,
            .shadow_blur = 30,
            .shadow_offset_y = 8,
        };
    }

    /// Preset: Psychedelic Neon (vibrant magenta tint, reflective border, heavy content fade)
    pub fn psy() Style {
        return .{
            .corner_radius = 32,
            .glass = Color.rgba(240, 0, 255, 0.30),
            .glass_fade_width = 80.0,
            .border_alpha = 0.60,
            .content_radius = 24,
            .content_fade_width = 60.0,
            .shadow_alpha = 0.40,
            .shadow_blur = 25,
            .shadow_offset_y = 10,
            .border_anim_width = 80.0,
        };
    }
};

/// Pixel layout a [`Canvas`] reads and writes.
pub const Format = enum {
    /// Premultiplied ARGB8888 (the wl_shm wire format) — the default.
    argb_premul,
    /// Straight-alpha RGBA8888 (bytes `R,G,B,A` in memory), e.g. an app's own
    /// compositor buffer that it hands to a Wayland surface as content. Currently
    /// honored by [`Canvas.fillRoundedRect`] (all `zicro.scroll` needs); the
    /// chrome/glyph/blit primitives assume `argb_premul`.
    rgba_straight,
};

/// A premultiplied ARGB8888 pixel canvas, the exact bytes a wl_shm buffer wants.
pub const Canvas = struct {
    pixels: []u32,
    width: u32,
    height: u32,
    /// Pixel layout of `pixels` (see [`Format`]).
    format: Format = .argb_premul,
    /// Optional scissor rect (pixel bounds, `x1`/`y1` exclusive). When set, every draw
    /// primitive is confined to it — how apps keep scrolled content from bleeding over
    /// the chrome. `null` = draw to the whole canvas.
    clip: ?Clip = null,

    pub const Clip = struct { x0: u32, y0: u32, x1: u32, y1: u32 };

    pub fn init(pixels: []u32, width: u32, height: u32) Canvas {
        std.debug.assert(pixels.len == @as(usize, width) * @as(usize, height));
        return .{ .pixels = pixels, .width = width, .height = height };
    }

    /// Wrap a straight-alpha RGBA8888 buffer (bytes `R,G,B,A` per pixel — the layout
    /// an app hands to a compositor as surface content) as a canvas. `pixels` is the
    /// `u32` view of that buffer (its backing bytes must be 4-byte aligned). Lets apps
    /// that composite their own frame reuse `zicro.scroll`'s bar drawing in place.
    pub fn initRgba8(pixels: []u32, width: u32, height: u32) Canvas {
        std.debug.assert(pixels.len == @as(usize, width) * @as(usize, height));
        return .{ .pixels = pixels, .width = width, .height = height, .format = .rgba_straight };
    }

    /// Source-over a straight color (`sr,sg,sb` straight in [0,1], coverage-scaled
    /// alpha `sa`) onto packed pixel `dst`, honoring the canvas [`Format`]. The
    /// premultiplied branch is the hot default and is byte-identical to the inline
    /// blend it replaced.
    inline fn overColor(self: *const Canvas, dst: u32, sr: f32, sg: f32, sb: f32, sa: f32) u32 {
        switch (self.format) {
            .argb_premul => {
                const dr, const dg, const db, const da = unpackPremul(dst);
                const inv = 1.0 - sa;
                return packPremul(sr * sa + dr * inv, sg * sa + dg * inv, sb * sa + db * inv, sa + da * inv);
            },
            .rgba_straight => {
                const dr, const dg, const db, const da = unpackStraight(dst);
                const inv = 1.0 - sa;
                const oa = sa + da * inv;
                if (oa <= 0.0) return packStraight(0, 0, 0, 0);
                // De-premultiply the blended result back to straight alpha.
                return packStraight(
                    (sr * sa + dr * da * inv) / oa,
                    (sg * sa + dg * da * inv) / oa,
                    (sb * sa + db * da * inv) / oa,
                    oa,
                );
            },
        }
    }

    /// Restrict subsequent drawing to `(x,y,w,h)` (canvas coords), intersected with the
    /// canvas. Returns the previous clip so callers can restore it
    /// (`const saved = canvas.setClip(...); defer canvas.clip = saved;`).
    pub fn setClip(self: *Canvas, x: u32, y: u32, w: u32, h: u32) ?Clip {
        const saved = self.clip;
        self.clip = .{
            .x0 = @min(x, self.width),
            .y0 = @min(y, self.height),
            .x1 = @min(x +| w, self.width),
            .y1 = @min(y +| h, self.height),
        };
        return saved;
    }

    /// Iteration bounds `[x0,x1)×[y0,y1)` intersected with the active clip (if any).
    fn clipBounds(self: *const Canvas, x0: u32, y0: u32, x1: u32, y1: u32) [4]u32 {
        if (self.clip) |c| {
            return .{ @max(x0, c.x0), @max(y0, c.y0), @min(x1, c.x1), @min(y1, c.y1) };
        }
        return .{ x0, y0, x1, y1 };
    }

    /// Is pixel `(x,y)` inside the active clip? (For per-pixel primitives like glyphs.)
    fn inClip(self: *const Canvas, x: u32, y: u32) bool {
        if (self.clip) |c| return x >= c.x0 and x < c.x1 and y >= c.y0 and y < c.y1;
        return true;
    }

    /// Paint the full window chrome: transparent gutter, drop shadow, glass panel,
    /// highlight ring. The panel occupies the canvas minus `style.margin` on each side.
    pub fn drawChrome(self: *Canvas, style: Style) void {
        const m: f32 = @floatFromInt(style.margin);
        const pw = @as(f32, @floatFromInt(self.width)) - 2.0 * m;
        const ph = @as(f32, @floatFromInt(self.height)) - 2.0 * m;
        if (pw <= 0 or ph <= 0) return;

        const g = style.glass;

        // Deep inside the panel the shadow is gone, the highlight ring has faded out and
        // the glass fade is saturated, so every pixel is the same premultiplied glass
        // colour. Fill that flat core with a memset and pay for the per-pixel SDF only in
        // the edge/corner/shadow band — on a big window that skips the vast majority of
        // pixels (each of which otherwise costs two `roundedRectSdf` evaluations).
        const ga_full = g.a;
        const core_px = packPremul(g.r * ga_full, g.g * ga_full, g.b * ga_full, ga_full);

        // Band where anything varies: the ring reaches ~2.5px, the glass fade its own
        // width; also stay clear of the rounded corners (guard >= corner radius).
        const band = @max(@as(f32, 3.0), style.glass_fade_width + 1.0);
        const guard = @max(style.corner_radius, band);
        const cx0f = m + guard;
        const cx1f = m + pw - guard;
        const cy0f = m + guard;
        const cy1f = m + ph - guard;
        const has_core = (cx1f - cx0f) >= 1.0 and (cy1f - cy0f) >= 1.0;
        const cx0: u32 = if (has_core) @intFromFloat(@ceil(cx0f)) else 0;
        const cx1: u32 = if (has_core) @intFromFloat(@floor(cx1f)) else 0;
        const cy0: u32 = if (has_core) @intFromFloat(@ceil(cy0f)) else 0;
        const cy1: u32 = if (has_core) @intFromFloat(@floor(cy1f)) else 0;

        const dynamic_core = style.sheen != 0.0 or style.specular != 0.0;
        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const row = self.pixels[@as(usize, y) * self.width ..][0..self.width];
            const core_row = has_core and y >= cy0 and y < cy1;
            // Core piatto (memset veloce): colore per-riga se il vetro ha un gradiente verticale.
            const row_core_px = if (dynamic_core) blk: {
                const gc = glassColorAt(style, g, m, ph, fy);
                break :blk packPremul(gc[0] * ga_full, gc[1] * ga_full, gc[2] * ga_full, ga_full);
            } else core_px;
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                if (core_row and x == cx0 and cx1 > cx0) {
                    @memset(row[cx0..cx1], row_core_px);
                    x = cx1 - 1; // the loop's ++ resumes the band at cx1
                    continue;
                }
                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                row[x] = chromePixel(fx, fy, style, g, m, pw, ph);
            }
        }
    }

    /// One chrome pixel at sub-pixel `(fx,fy)`: drop shadow, rounded glass and the 1px
    /// highlight ring, composited back-to-front in premultiplied space. The hot inner body
    /// of `drawChrome`, kept separate so the flat-core fast path can skip it.
    /// Colore del vetro (straight RGB) alla riga `fy`: applica sheen (gradiente verticale) e
    /// speculare superiore. Base per lo shader del pannello e per il fill del core.
    fn glassColorAt(style: Style, g: Color, m: f32, ph: f32, fy: f32) [3]f32 {
        const ty = std.math.clamp((fy - m) / @max(1.0, ph), 0.0, 1.0);
        const sheen_mul = 1.0 + style.sheen * (0.5 - ty);
        var cr = std.math.clamp(g.r * sheen_mul, 0.0, 1.0);
        var cg = std.math.clamp(g.g * sheen_mul, 0.0, 1.0);
        var cb = std.math.clamp(g.b * sheen_mul, 0.0, 1.0);
        if (style.specular > 0.0) {
            const spec = style.specular * (1.0 - smoothstep(0.0, 0.12, ty));
            cr = cr + (1.0 - cr) * spec;
            cg = cg + (1.0 - cg) * spec;
            cb = cb + (1.0 - cb) * spec;
        }
        return .{ cr, cg, cb };
    }
    fn chromePixel(fx: f32, fy: f32, style: Style, g: Color, m: f32, pw: f32, ph: f32) u32 {
        const d_panel = roundedRectSdf(fx, fy, m, m, pw, ph, style.corner_radius);
        const panel_cov = coverage(d_panel);

        // Shadow: same shape, nudged down, smooth penumbra — clipped to the outside of the
        // panel so the glass stays clean over the blur.
        const d_shadow = roundedRectSdf(fx, fy - style.shadow_offset_y, m, m, pw, ph, style.corner_radius);
        const shadow = style.shadow_alpha *
            (1.0 - smoothstep(-style.shadow_blur, style.shadow_blur, d_shadow)) *
            (1.0 - panel_cov);

        // 1px highlight ring hugging the panel edge from the inside.
        const ring = coverage(@abs(d_panel + 1.0) - 1.0) * style.border_alpha * panel_cov;

        var glass_cov = panel_cov;
        if (style.glass_fade_width > 0.0) {
            glass_cov *= smoothstep(0.0, style.glass_fade_width, -d_panel);
        }
        const gc = glassColorAt(style, g, m, ph, fy);
        const ga = g.a * glass_cov;
        var pr: f32 = gc[0] * ga;
        var pg: f32 = gc[1] * ga;
        var pb: f32 = gc[2] * ga;
        var pa: f32 = ga + shadow * (1.0 - ga);
        pr = ring + pr * (1.0 - ring);
        pg = ring + pg * (1.0 - ring);
        pb = ring + pb * (1.0 - ring);
        pa = ring + pa * (1.0 - ring);
        return packPremul(pr, pg, pb, pa);
    }

    /// Blit straight-alpha RGBA pixels (zicro's `media.Frame` layout) into the canvas
    /// at `(dst_x, dst_y)`, premultiplying and source-over compositing as it goes,
    /// clipped to both the canvas and a rounded-rect mask matching the panel.
    pub fn blitRgba(
        self: *Canvas,
        dst_x: u32,
        dst_y: u32,
        src: []const u8,
        src_w: u32,
        src_h: u32,
        style: Style,
    ) void {
        const m: f32 = @floatFromInt(style.margin);
        const pw = @as(f32, @floatFromInt(self.width)) - 2.0 * m;
        const ph = @as(f32, @floatFromInt(self.height)) - 2.0 * m;

        const dx_f: f32 = @floatFromInt(dst_x);
        const dy_f: f32 = @floatFromInt(dst_y);
        const sw_f: f32 = @floatFromInt(src_w);
        const sh_f: f32 = @floatFromInt(src_h);

        // When the style asks for no rounding, fade or margin, the panel/content masks are 1
        // everywhere — skip both per-pixel `roundedRectSdf` evals (two sqrts each). Opaque
        // source pixels then become a straight packed write with no blend. This is the opaque
        // full-window present path (ZUER_OPAQUE); the glass path keeps the full SDF masking.
        const trivial = style.margin == 0 and style.corner_radius == 0 and style.content_radius == 0 and
            style.content_fade_width == 0 and style.border_anim_width == 0;

        // Flat-interior fast path for the glass (non-trivial) styles, mirroring the
        // `drawChrome` core: deep enough inside *both* rounded rects every mask is
        // saturated — panel coverage 1, content coverage 1 (or 0 with a border band:
        // the band factor hits zero in the center, so those pixels are skipped whole).
        // Inside the guard band both per-pixel `roundedRectSdf` evals (two sqrts each)
        // vanish; this runs full-frame at 60Hz for glass windows.
        const guard = @max(
            @max(style.corner_radius, style.content_radius),
            @max(style.content_fade_width, style.border_anim_width),
        ) + 1.0;
        const flat_px0 = m + guard;
        const flat_px1 = m + pw - guard;
        const flat_py0 = m + guard;
        const flat_py1 = m + ph - guard;
        const flat_cx0 = dx_f + guard;
        const flat_cx1 = dx_f + sw_f - guard;
        const flat_cy0 = dy_f + guard;
        const flat_cy1 = dy_f + sh_f - guard;

        // Rispetta il clip attivo del canvas (usato dal present parziale di zrame:
        // la regione damage limita quali pixel del frame vengono ricompositi).
        var sy_start: u32 = 0;
        var sy_end: u32 = src_h;
        var sx_start: u32 = 0;
        var sx_end: u32 = src_w;
        if (self.clip) |c| {
            sx_start = @min(src_w, c.x0 -| dst_x);
            sy_start = @min(src_h, c.y0 -| dst_y);
            sx_end = @min(src_w, c.x1 -| dst_x);
            sy_end = @min(src_h, c.y1 -| dst_y);
            if (sx_start >= sx_end or sy_start >= sy_end) return;
        }
        var sy: u32 = sy_start;
        while (sy < sy_end) : (sy += 1) {
            const y = dst_y + sy;
            if (y >= self.height) break;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const row = self.pixels[@as(usize, y) * self.width ..][0..self.width];
            const src_row = src[@as(usize, sy) * src_w * 4 ..][0 .. @as(usize, src_w) * 4];
            var sx: u32 = sx_start;
            while (sx < sx_end) : (sx += 1) {
                const x = dst_x + sx;
                if (x >= self.width) break;
                const sp = src_row[@as(usize, sx) * 4 ..][0..4];

                // Trivial-mask fast path: no SDF, and a fully-opaque source pixel is a direct
                // packed write (ARGB8888, premultiplied == the color for a==255).
                if (trivial) {
                    if (sp[3] == 0) continue;
                    if (sp[3] == 255) {
                        row[x] = 0xFF000000 | (@as(u32, sp[0]) << 16) | (@as(u32, sp[1]) << 8) | @as(u32, sp[2]);
                        continue;
                    }
                }

                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                var mask: f32 = 1.0;
                var content_cov: f32 = 1.0;
                if (!trivial) {
                    const flat = fx >= flat_px0 and fx <= flat_px1 and fy >= flat_py0 and fy <= flat_py1 and
                        fx >= flat_cx0 and fx <= flat_cx1 and fy >= flat_cy0 and fy <= flat_cy1;
                    if (flat) {
                        // Deep interior: with a border band the content faded to zero here.
                        if (style.border_anim_width > 0.0) continue;
                        // Both masks are saturated at 1 here, so an opaque source pixel is a
                        // plain overwrite and a transparent one a no-op: skip the float
                        // unpack/blend/pack round-trip. This is the full-frame hot path for
                        // opaque content (images, video, mesh) under glass styles, where the
                        // `trivial` shortcut above never applies.
                        if (sp[3] == 255) {
                            row[x] = 0xFF000000 | (@as(u32, sp[0]) << 16) | (@as(u32, sp[1]) << 8) | @as(u32, sp[2]);
                            continue;
                        }
                        if (sp[3] == 0) continue;
                        // Otherwise mask and content_cov stay saturated at 1 — no SDF.
                    } else {
                        const d_panel = roundedRectSdf(fx, fy, m, m, pw, ph, style.corner_radius);
                        mask = coverage(d_panel);
                        if (mask <= 0.0) continue;

                        const d_content = roundedRectSdf(fx, fy, dx_f, dy_f, sw_f, sh_f, style.content_radius);
                        content_cov = coverage(d_content);
                        if (content_cov <= 0.0) continue;

                        if (style.content_fade_width > 0.0) {
                            content_cov *= smoothstep(0.0, style.content_fade_width, -d_content);
                        }
                        if (style.border_anim_width > 0.0) {
                            content_cov *= 1.0 - smoothstep(0.0, style.border_anim_width, -d_panel);
                        }
                    }
                }

                const sa = @as(f32, @floatFromInt(sp[3])) / 255.0 * mask * content_cov;
                if (sa <= 0.0) continue;
                const sr = @as(f32, @floatFromInt(sp[0])) / 255.0;
                const sg = @as(f32, @floatFromInt(sp[1])) / 255.0;
                const sb = @as(f32, @floatFromInt(sp[2])) / 255.0;

                const dr, const dg, const db, const da = unpackPremul(row[x]);
                const inv = 1.0 - sa;
                row[x] = packPremul(
                    sr * sa + dr * inv,
                    sg * sa + dg * inv,
                    sb * sa + db * inv,
                    sa + da * inv,
                );
            }
        }
    }

    /// Blit an RGBA8 (straight-alpha, bytes R,G,B,A) sprite into the dst rect, source-over,
    /// nearest-neighbour scaled and honoring clip + canvas [`Format`]. For app icons/thumbnails.
    pub fn blitImage(self: *Canvas, dst_x: i32, dst_y: i32, dst_w: u32, dst_h: u32, src: []const u8, src_w: u32, src_h: u32) void {
        if (dst_w == 0 or dst_h == 0 or src_w == 0 or src_h == 0) return;
        const bx0: u32 = @intCast(@max(0, dst_x));
        const by0: u32 = @intCast(@max(0, dst_y));
        const bx1: u32 = @min(self.width, @as(u32, @intCast(@max(0, dst_x + @as(i32, @intCast(dst_w))))));
        const by1: u32 = @min(self.height, @as(u32, @intCast(@max(0, dst_y + @as(i32, @intCast(dst_h))))));
        const x0, const y0, const x1, const y1 = self.clipBounds(bx0, by0, bx1, by1);
        const inv: f32 = 1.0 / 255.0;
        var py: u32 = y0;
        while (py < y1) : (py += 1) {
            const rel_y: u32 = @intCast(@as(i32, @intCast(py)) - dst_y);
            const sy = @min(src_h - 1, rel_y * src_h / dst_h);
            const row = self.pixels[@as(usize, py) * self.width ..][0..self.width];
            var px: u32 = x0;
            while (px < x1) : (px += 1) {
                const rel_x: u32 = @intCast(@as(i32, @intCast(px)) - dst_x);
                const sx = @min(src_w - 1, rel_x * src_w / dst_w);
                const si = (@as(usize, sy) * src_w + sx) * 4;
                const a = src[si + 3];
                if (a == 0) continue;
                row[px] = self.overColor(
                    row[px],
                    @as(f32, @floatFromInt(src[si])) * inv,
                    @as(f32, @floatFromInt(src[si + 1])) * inv,
                    @as(f32, @floatFromInt(src[si + 2])) * inv,
                    @as(f32, @floatFromInt(a)) * inv,
                );
            }
        }
    }

    /// Like [`blitImage`] but rotated by `angle` radians about the dst-rect centre. Inverse-
    /// rotates each output pixel back into the sprite; nearest-neighbour, alpha-over, clipped.
    pub fn blitImageRot(self: *Canvas, dx: f32, dy: f32, dw: f32, dh: f32, src: []const u8, src_w: u32, src_h: u32, angle: f32) void {
        if (dw <= 0 or dh <= 0 or src_w == 0 or src_h == 0) return;
        const cx = dx + dw * 0.5;
        const cy = dy + dh * 0.5;
        const hd = 0.5 * @sqrt(dw * dw + dh * dh); // half-diagonal → bounding box
        const bx0: u32 = @intFromFloat(@max(0.0, @floor(cx - hd)));
        const by0: u32 = @intFromFloat(@max(0.0, @floor(cy - hd)));
        const bx1: u32 = @min(self.width, @as(u32, @intFromFloat(@max(0.0, @ceil(cx + hd)))));
        const by1: u32 = @min(self.height, @as(u32, @intFromFloat(@max(0.0, @ceil(cy + hd)))));
        const x0, const y0, const x1, const y1 = self.clipBounds(bx0, by0, bx1, by1);
        const ca = @cos(-angle);
        const sa = @sin(-angle);
        const inv: f32 = 1.0 / 255.0;
        var py: u32 = y0;
        while (py < y1) : (py += 1) {
            const ry = @as(f32, @floatFromInt(py)) + 0.5 - cy;
            const row = self.pixels[@as(usize, py) * self.width ..][0..self.width];
            var px: u32 = x0;
            while (px < x1) : (px += 1) {
                const rx = @as(f32, @floatFromInt(px)) + 0.5 - cx;
                const lx = rx * ca - ry * sa; // inverse-rotate into local dst space
                const ly = rx * sa + ry * ca;
                const u = (lx + dw * 0.5) / dw;
                const v = (ly + dh * 0.5) / dh;
                if (u < 0 or u >= 1 or v < 0 or v >= 1) continue;
                const sx: u32 = @min(src_w - 1, @as(u32, @intFromFloat(u * @as(f32, @floatFromInt(src_w)))));
                const sy: u32 = @min(src_h - 1, @as(u32, @intFromFloat(v * @as(f32, @floatFromInt(src_h)))));
                const si = (@as(usize, sy) * src_w + sx) * 4;
                const a = src[si + 3];
                if (a == 0) continue;
                row[px] = self.overColor(
                    row[px],
                    @as(f32, @floatFromInt(src[si])) * inv,
                    @as(f32, @floatFromInt(src[si + 1])) * inv,
                    @as(f32, @floatFromInt(src[si + 2])) * inv,
                    @as(f32, @floatFromInt(a)) * inv,
                );
            }
        }
    }

    /// Fill a rounded rect with a straight-alpha color (source-over). For decorative
    /// content drawn by apps that don't push zicro frames.
    /// Riempie un raccordo CONCAVO (flare stile Chrome-tab): un quadrato `size`×`size` a (x,y)
    /// dove i pixel a distanza >= `size` dal centro (cx,cy) sono riempiti → arco concavo con AA.
    /// Con cx,cy sull'angolo esterno-alto del quadrato ottieni l'ala che allarga la tab in basso.
    pub fn fillConcaveCorner(self: *Canvas, x: f32, y: f32, size: f32, cx: f32, cy: f32, color: Color) void {
        const bx0: u32 = @intFromFloat(@max(0.0, @floor(x)));
        const by0: u32 = @intFromFloat(@max(0.0, @floor(y)));
        const bx1: u32 = @min(self.width, @as(u32, @intFromFloat(@max(0.0, @ceil(x + size)))));
        const by1: u32 = @min(self.height, @as(u32, @intFromFloat(@max(0.0, @ceil(y + size)))));
        const x0, const y0, const x1, const y1 = self.clipBounds(bx0, by0, bx1, by1);
        var py: u32 = y0;
        while (py < y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            const row = self.pixels[@as(usize, py) * self.width ..][0..self.width];
            var px: u32 = x0;
            while (px < x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const dx = fx - cx;
                const dy = fy - cy;
                const dist = @sqrt(dx * dx + dy * dy);
                const cov = coverage(size - dist);
                if (cov <= 0.0) continue;
                row[px] = self.overColor(row[px], color.r, color.g, color.b, color.a * cov);
            }
        }
    }
    pub fn fillRoundedRect(self: *Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, color: Color) void {
        const bx0: u32 = @intFromFloat(@max(0.0, @floor(x - 1)));
        const by0: u32 = @intFromFloat(@max(0.0, @floor(y - 1)));
        const bx1: u32 = @min(self.width, @as(u32, @intFromFloat(@max(0.0, @ceil(x + w + 1)))));
        const by1: u32 = @min(self.height, @as(u32, @intFromFloat(@max(0.0, @ceil(y + h + 1)))));
        const x0, const y0, const x1, const y1 = self.clipBounds(bx0, by0, bx1, by1);
        var py: u32 = y0;
        while (py < y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            const row = self.pixels[@as(usize, py) * self.width ..][0..self.width];
            var px: u32 = x0;
            while (px < x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const cov = coverage(roundedRectSdf(fx, fy, x, y, w, h, radius));
                if (cov <= 0.0) continue;
                const sa = color.a * cov;
                row[px] = self.overColor(row[px], color.r, color.g, color.b, sa);
            }
        }
    }

    /// Fill a rounded rect with independent corner radii (source-over, honoring the
    /// canvas [`Format`]). Same primitive as [`fillRoundedRect`] but takes a [`Corners`]
    /// — for tabs, sheet headers and any panel that rounds only some corners.
    pub fn fillRoundedRectPerCorner(self: *Canvas, x: f32, y: f32, w: f32, h: f32, corners: Corners, color: Color) void {
        const bx0: u32 = @intFromFloat(@max(0.0, @floor(x - 1)));
        const by0: u32 = @intFromFloat(@max(0.0, @floor(y - 1)));
        const bx1: u32 = @min(self.width, @as(u32, @intFromFloat(@max(0.0, @ceil(x + w + 1)))));
        const by1: u32 = @min(self.height, @as(u32, @intFromFloat(@max(0.0, @ceil(y + h + 1)))));
        const x0, const y0, const x1, const y1 = self.clipBounds(bx0, by0, bx1, by1);
        var py: u32 = y0;
        while (py < y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            const row = self.pixels[@as(usize, py) * self.width ..][0..self.width];
            var px: u32 = x0;
            while (px < x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const cov = coverage(roundedRectSdfPerCorner(fx, fy, x, y, w, h, corners));
                if (cov <= 0.0) continue;
                row[px] = self.overColor(row[px], color.r, color.g, color.b, color.a * cov);
            }
        }
    }

    /// Fill a rounded rect with a **vertical gradient** from `top` (at `y`) to `bottom`
    /// (at `y+h`), the two straight colors lerped per scanline. Same AA/SDF coverage and
    /// [`Format`] handling as [`fillRoundedRect`]; the depth cue widgets use for a subtle
    /// top-sheen (macOS) or a tonal accent (the signature theme). Pass equal colors for a
    /// flat fill (a no-op gradient).
    pub fn fillRoundedRectVGradient(self: *Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, top: Color, bottom: Color) void {
        const bx0: u32 = @intFromFloat(@max(0.0, @floor(x - 1)));
        const by0: u32 = @intFromFloat(@max(0.0, @floor(y - 1)));
        const bx1: u32 = @min(self.width, @as(u32, @intFromFloat(@max(0.0, @ceil(x + w + 1)))));
        const by1: u32 = @min(self.height, @as(u32, @intFromFloat(@max(0.0, @ceil(y + h + 1)))));
        const x0, const y0, const x1, const y1 = self.clipBounds(bx0, by0, bx1, by1);
        const inv_h = if (h > 0.0) 1.0 / h else 0.0;
        var py: u32 = y0;
        while (py < y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            // Gradient parameter is constant across the scanline: lerp the color once.
            const g = std.math.clamp((fy - y) * inv_h, 0.0, 1.0);
            const cr = top.r + (bottom.r - top.r) * g;
            const cg = top.g + (bottom.g - top.g) * g;
            const cb = top.b + (bottom.b - top.b) * g;
            const ca = top.a + (bottom.a - top.a) * g;
            const row = self.pixels[@as(usize, py) * self.width ..][0..self.width];
            var px: u32 = x0;
            while (px < x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const cov = coverage(roundedRectSdf(fx, fy, x, y, w, h, radius));
                if (cov <= 0.0) continue;
                row[px] = self.overColor(row[px], cr, cg, cb, ca * cov);
            }
        }
    }

    /// Paint a **soft drop shadow** for the rounded rect `(x,y,w,h,radius)`: solid under
    /// the shape (the widget's own fill, drawn on top afterward, hides it) and a smooth
    /// `blur`-wide penumbra fading outward, offset down by `offset_y`. This is the
    /// elevation lever — the analytic falloff of the same SDF the fill uses, so shadow and
    /// shape share one silhouette. `color.a` is the peak opacity. Honors [`Format`].
    pub fn dropShadowRoundedRect(self: *Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, blur: f32, offset_y: f32, color: Color) void {
        if (color.a <= 0.0) return;
        const b = @max(blur, 0.5);
        const sy = y + offset_y;
        const pad = b + 1.0;
        const bx0: u32 = @intFromFloat(@max(0.0, @floor(x - pad)));
        const by0: u32 = @intFromFloat(@max(0.0, @floor(sy - pad)));
        const bx1: u32 = @min(self.width, @as(u32, @intFromFloat(@max(0.0, @ceil(x + w + pad)))));
        const by1: u32 = @min(self.height, @as(u32, @intFromFloat(@max(0.0, @ceil(sy + h + pad)))));
        const x0, const y0, const x1, const y1 = self.clipBounds(bx0, by0, bx1, by1);
        var py: u32 = y0;
        while (py < y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            const row = self.pixels[@as(usize, py) * self.width ..][0..self.width];
            var px: u32 = x0;
            while (px < x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const d = roundedRectSdf(fx, fy, x, sy, w, h, radius);
                // Solid at/inside the edge, smooth falloff to zero over `blur` outside.
                const shade = 1.0 - smoothstep(0.0, b, @max(d, 0.0));
                if (shade <= 0.0) continue;
                row[px] = self.overColor(row[px], color.r, color.g, color.b, color.a * shade);
            }
        }
    }

    /// Stroke a circular arc from angle `a0` to `a1` (radians, 0 = +x, growing clockwise
    /// in screen space) at radius `radius` around `(cx,cy)`, as a rounded stroke of the
    /// given `width`. The arc is flattened into short capsule segments and the whole span
    /// is composited with a single coverage per pixel (min distance over the segments), so
    /// the joints never darken from double-blending. Honors the canvas [`Format`].
    pub fn drawArc(self: *Canvas, cx: f32, cy: f32, radius: f32, width: f32, a0: f32, a1: f32, color: Color) void {
        const max_pts = 33;
        // One segment per ~12°, clamped to the buffer we have; at least a couple.
        const span = @abs(a1 - a0);
        const want: usize = @intFromFloat(@ceil(span / (std.math.pi / 15.0)));
        const segs = std.math.clamp(want, 2, max_pts - 1);
        var pts: [max_pts][2]f32 = undefined;
        var i: usize = 0;
        while (i <= segs) : (i += 1) {
            const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segs));
            const a = a0 + (a1 - a0) * t;
            pts[i] = .{ cx + radius * @cos(a), cy + radius * @sin(a) };
        }

        const r = width / 2.0;
        const sag = radius * (1.0 - @cos(std.math.pi / 30.0));
        const pad = radius + r + 1.0;
        const bx0: u32 = @intFromFloat(@max(0.0, @floor(cx - pad)));
        const by0: u32 = @intFromFloat(@max(0.0, @floor(cy - pad)));
        const bx1: u32 = @min(self.width, @as(u32, @intFromFloat(@max(0.0, @ceil(cx + pad)))));
        const by1: u32 = @min(self.height, @as(u32, @intFromFloat(@max(0.0, @ceil(cy + pad)))));
        const x0, const y0, const x1, const y1 = self.clipBounds(bx0, by0, bx1, by1);
        var py: u32 = y0;
        while (py < y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            const row = self.pixels[@as(usize, py) * self.width ..][0..self.width];
            var px: u32 = x0;
            while (px < x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                // Ring-band early-out: every segment lies on the circle, so a pixel
                // farther than the stroke half-width (+AA) from the ring can never get
                // ink — skip the whole segment loop (one sqrt instead of up to 32).
                // The bounding box is mostly interior/exterior; the spinner runs at 60Hz.
                const dcx = fx - cx;
                const dcy = fy - cy;
                const dc = @sqrt(dcx * dcx + dcy * dcy);
                // The chords dip inside the circle by up to the sagitta
                // (radius·(1−cos 6°) at 12°/segment) — widen the band so
                // large-radius arcs keep their inner AA pixels.
                if (@abs(dc - radius) - r > 0.5 + sag) continue;
                var d: f32 = std.math.floatMax(f32);
                var s: usize = 0;
                while (s < segs) : (s += 1) {
                    d = @min(d, segmentSdf(fx, fy, pts[s][0], pts[s][1], pts[s + 1][0], pts[s + 1][1]));
                }
                const cov = coverage(d - r);
                if (cov <= 0.0) continue;
                row[px] = self.overColor(row[px], color.r, color.g, color.b, color.a * cov);
            }
        }
    }

    /// Draw an indeterminate loading spinner: a rotating arc whose length breathes,
    /// exactly egui's `Spinner` geometry driven by an elapsed-time `phase` (seconds).
    /// Feed a monotonic clock; the caller owns the tick, so this stays a pure primitive.
    pub fn drawSpinner(self: *Canvas, cx: f32, cy: f32, radius: f32, width: f32, phase: f32, color: Color) void {
        const start = phase * std.math.tau;
        const end = start + (240.0 * std.math.pi / 180.0) * @sin(phase);
        self.drawArc(cx, cy, radius, width, start, end, color);
    }

    /// Draw a determinate progress bar: a rounded `track` the full width, overlaid by a
    /// rounded `fill` covering `progress` (clamped 0..1) of it. `radius` rounds both (pass
    /// `h/2` for a pill). Honors the canvas [`Format`].
    pub fn fillProgressBar(self: *Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, progress: f32, track: Color, fill: Color) void {
        self.fillRoundedRect(x, y, w, h, radius, track);
        const p = std.math.clamp(progress, 0.0, 1.0);
        const fw = w * p;
        // Below a pill's width the fill would render as a lens; skip it so an empty bar
        // reads as empty rather than as a stray dot.
        if (fw < @min(w, 2.0 * radius) - 0.5 and p < 1.0 and fw < 1.0) return;
        self.fillRoundedRect(x, y, @max(fw, 2.0 * radius), h, radius, fill);
    }

    /// Draw an indeterminate progress bar: a rounded `track` with a `fill` chunk that
    /// sweeps back and forth, driven by an elapsed-time `phase` (seconds). The chunk is a
    /// third of the track and eases at the ends (a sine sweep), so it feels alive at rest.
    pub fn fillProgressBarIndeterminate(self: *Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, phase: f32, track: Color, fill: Color) void {
        self.fillRoundedRect(x, y, w, h, radius, track);
        const chunk = w / 3.0;
        // Sine sweep of the chunk's left edge across the free travel [0, w-chunk].
        const travel = @max(0.0, w - chunk);
        const s = (1.0 - @cos(phase * 2.0)) / 2.0; // 0..1, eased at both ends
        const fx = x + travel * s;
        const saved = self.setClip(
            @intFromFloat(@max(0.0, x)),
            @intFromFloat(@max(0.0, y)),
            @intFromFloat(@max(0.0, w)),
            @intFromFloat(@max(0.0, h)),
        );
        defer self.clip = saved;
        self.fillRoundedRect(fx, y, chunk, h, radius, fill);
    }

    /// Stroke the line segment `a`→`b` as a rounded (capsule) stroke of the given
    /// `width`, anti-aliased and source-over composited. The building block for the
    /// procedural window-control glyphs (✕, –). Honors the canvas [`Format`].
    pub fn strokeSegment(self: *Canvas, ax: f32, ay: f32, bx: f32, by: f32, width: f32, color: Color) void {
        const r = width / 2.0;
        const minx = @min(ax, bx) - r - 1.0;
        const miny = @min(ay, by) - r - 1.0;
        const maxx = @max(ax, bx) + r + 1.0;
        const maxy = @max(ay, by) + r + 1.0;
        const bx0: u32 = @intFromFloat(@max(0.0, @floor(minx)));
        const by0: u32 = @intFromFloat(@max(0.0, @floor(miny)));
        const bx1: u32 = @min(self.width, @as(u32, @intFromFloat(@max(0.0, @ceil(maxx)))));
        const by1: u32 = @min(self.height, @as(u32, @intFromFloat(@max(0.0, @ceil(maxy)))));
        const x0, const y0, const x1, const y1 = self.clipBounds(bx0, by0, bx1, by1);
        var py: u32 = y0;
        while (py < y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            const row = self.pixels[@as(usize, py) * self.width ..][0..self.width];
            var px: u32 = x0;
            while (px < x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const cov = coverage(segmentSdf(fx, fy, ax, ay, bx, by) - r);
                if (cov <= 0.0) continue;
                row[px] = self.overColor(row[px], color.r, color.g, color.b, color.a * cov);
            }
        }
    }

    /// Stroke the outline of a rounded rect: coverage of `|sdf| - stroke/2`, so the fill
    /// stays hollow. The maximize ▢ and the restore double-square are drawn with this.
    /// Honors the canvas [`Format`].
    pub fn strokeRoundedRect(self: *Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, stroke: f32, color: Color) void {
        const hs = stroke / 2.0;
        const bx0: u32 = @intFromFloat(@max(0.0, @floor(x - hs - 1)));
        const by0: u32 = @intFromFloat(@max(0.0, @floor(y - hs - 1)));
        const bx1: u32 = @min(self.width, @as(u32, @intFromFloat(@max(0.0, @ceil(x + w + hs + 1)))));
        const by1: u32 = @min(self.height, @as(u32, @intFromFloat(@max(0.0, @ceil(y + h + hs + 1)))));
        const x0, const y0, const x1, const y1 = self.clipBounds(bx0, by0, bx1, by1);
        var py: u32 = y0;
        while (py < y1) : (py += 1) {
            const fy = @as(f32, @floatFromInt(py)) + 0.5;
            const row = self.pixels[@as(usize, py) * self.width ..][0..self.width];
            var px: u32 = x0;
            while (px < x1) : (px += 1) {
                const fx = @as(f32, @floatFromInt(px)) + 0.5;
                const cov = coverage(@abs(roundedRectSdf(fx, fy, x, y, w, h, radius)) - hs);
                if (cov <= 0.0) continue;
                row[px] = self.overColor(row[px], color.r, color.g, color.b, color.a * cov);
            }
        }
    }

    /// Draws `s` with `font` starting at `x` (left edge) and `baseline_y` (the
    /// text baseline), advancing the pen glyph by glyph. Composites the coverage
    /// over the premultiplied pixels (source-over). Use `font.ascent` to convert
    /// a top edge into a baseline if needed.
    pub fn drawText(self: *Canvas, font: *text.Font, x: i32, baseline_y: i32, s: []const u8, opts: TextOpts) void {
        var pen_x: f32 = @floatFromInt(x);
        var prev_cp: ?u32 = null;
        var i: usize = 0;
        while (i < s.len) {
            const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(i + seq, s.len);
            const cp: u32 = std.unicode.utf8Decode(s[i..end]) catch s[i];
            i = end;

            if (prev_cp) |prev| {
                pen_x += font.getKernAdvance(opts.style, opts.size, prev, cp);
            }

            const frac = pen_x - @floor(pen_x);
            const sub_x_i = @as(i32, @intFromFloat(@round(frac * 4.0)));
            const sub_x: u2 = @intCast(sub_x_i & 3);
            const g = font.getGlyph(opts.size, opts.style, sub_x, cp) catch continue;
            const ipen_x = @as(i32, @intFromFloat(@floor(pen_x + 0.5)));

            self.blitGlyph(g, ipen_x, baseline_y, opts.color);
            pen_x += g.advance;
            prev_cp = cp;
        }
    }

    /// Blends a glyph's coverage (straight color) onto the premultiplied canvas.
    fn blitGlyph(self: *Canvas, g: *const text.Glyph, pen_x: i32, baseline_y: i32, color: Color) void {
        if (g.bitmap.len == 0) return;
        const gx0 = pen_x + g.xoff;
        const gy0 = baseline_y + g.yoff;
        const W: i32 = @intCast(self.width);
        const H: i32 = @intCast(self.height);
        // The text color is constant across the glyph: linearize it once, not per pixel.
        const lin_r = srgbToLinear(color.r);
        const lin_g = srgbToLinear(color.g);
        const lin_b = srgbToLinear(color.b);
        var gy: i32 = 0;
        while (gy < g.h) : (gy += 1) {
            const py = gy0 + gy;
            if (py < 0 or py >= H) continue;
            var gx: i32 = 0;
            while (gx < g.w) : (gx += 1) {
                const px = gx0 + gx;
                if (px < 0 or px >= W) continue;
                if (!self.inClip(@intCast(px), @intCast(py))) continue;
                const cov = g.bitmap[@intCast(gy * g.w + gx)];
                if (cov == 0) continue;
                // macOS-style stem darkening + coverage → alpha (LUT: coverage is a byte).
                const a0 = smooth_coverage_lut[cov];
                const sa = color.a * a0;
                if (sa <= 0.0) continue;
                const idx = @as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px));
                const dr, const dg, const db, const da = unpackPremul(self.pixels[idx]);
                const inv = 1.0 - sa;
                // Gamma-correct "over": blend RGB in linear light (the premultiplied
                // channels are ~straight over the chrome's opaque panel), then back to
                // sRGB. The alpha stays linear (geometric coverage).
                self.pixels[idx] = packPremul(
                    linearToSrgb(lin_r * sa + srgbToLinear(dr) * inv),
                    linearToSrgb(lin_g * sa + srgbToLinear(dg) * inv),
                    linearToSrgb(lin_b * sa + srgbToLinear(db) * inv),
                    sa + da * inv,
                );
            }
        }
    }
};

test "drawText produces ink and renders a preview" {
    const gpa = std.testing.allocator;
    const W: u32 = 460;
    const H: u32 = 90;
    const pixels = try gpa.alloc(u32, W * H);
    defer gpa.free(pixels);
    // Opaque dark background.
    @memset(pixels, packPremul(0.07, 0.07, 0.1, 1.0));

    var canvas = Canvas.init(pixels, W, H);
    var font = try text.Font.initDefault(gpa);
    defer font.deinit();

    const v = font.vmetrics(34, .bold);
    canvas.drawText(&font, 20, 16 + v.ascent, "zrame text ✓ Ag", .{ .size = 34, .style = .bold, .color = Color.rgba(235, 238, 250, 1.0) });

    // Many pixels differ from the background (the glyphs left ink).
    const bg = packPremul(0.07, 0.07, 0.1, 1.0);
    var ink: usize = 0;
    for (pixels) |p| {
        if (p != bg) ink += 1;
    }
    try std.testing.expect(ink > 100);
}

test "straight-alpha canvas: fillRoundedRect over opaque RGBA8 background" {
    const gpa = std.testing.allocator;
    const W: u32 = 40;
    const H: u32 = 40;
    const pixels = try gpa.alloc(u32, W * H);
    defer gpa.free(pixels);
    // Opaque red background in straight RGBA8 bytes (R=255,G=0,B=0,A=255).
    @memset(pixels, packStraight(1.0, 0.0, 0.0, 1.0));

    var canvas = Canvas.initRgba8(pixels, W, H);
    // Fully opaque white fill over the whole canvas → center pixel becomes white.
    canvas.fillRoundedRect(0, 0, W, H, 4, Color.rgba(255, 255, 255, 1.0));

    const center = pixels[@as(usize, H / 2) * W + W / 2];
    const r, const g, const b, const a = unpackStraight(center);
    try std.testing.expect(r > 0.98 and g > 0.98 and b > 0.98 and a > 0.98);

    // Half-alpha black over the opaque red leaves a *straight* result: alpha stays 1,
    // RGB darkens toward black (0.5*0 + 0.5*red).
    @memset(pixels, packStraight(1.0, 0.0, 0.0, 1.0));
    canvas.fillRoundedRect(0, 0, W, H, 0, Color.rgba(0, 0, 0, 0.5));
    const cr, const cg, const cb, const ca = unpackStraight(pixels[@as(usize, H / 2) * W + W / 2]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), cr, 0.02);
    try std.testing.expect(cg < 0.02 and cb < 0.02);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), ca, 0.01);
}

test "sdf signs" {
    // Center of a 100x100 rounded rect is deep inside, far corner is outside.
    try std.testing.expect(roundedRectSdf(50, 50, 0, 0, 100, 100, 10) < 0);
    try std.testing.expect(roundedRectSdf(150, 150, 0, 0, 100, 100, 10) > 0);
    // The very corner pixel of the bounding box is outside the rounded shape.
    try std.testing.expect(roundedRectSdf(1, 1, 0, 0, 100, 100, 12) > 0);
}

test "per-corner sdf: uniform matches the single-radius field, asymmetry rounds one corner only" {
    // With all four radii equal, the per-corner field is bit-for-bit the scalar one
    // (this is what keeps the chrome fast-path reference test green).
    var gx: f32 = 0.5;
    while (gx < 100.0) : (gx += 7.0) {
        var gy: f32 = 0.5;
        while (gy < 100.0) : (gy += 7.0) {
            const a = roundedRectSdf(gx, gy, 0, 0, 100, 100, 14);
            const b = roundedRectSdfPerCorner(gx, gy, 0, 0, 100, 100, Corners.all(14));
            try std.testing.expectEqual(a, b);
        }
    }
    // A "tab" (top corners rounded, bottom square): the bottom-left pixel that a big
    // radius would carve away is now *inside* the shape, while the top-left is outside.
    const tab = Corners.top(20);
    try std.testing.expect(roundedRectSdfPerCorner(2, 98, 0, 0, 100, 100, tab) < 0); // bottom-left: square
    try std.testing.expect(roundedRectSdfPerCorner(2, 2, 0, 0, 100, 100, tab) > 0); // top-left: rounded away
}

test "spinner and progress primitives leave ink" {
    const gpa = std.testing.allocator;
    const W: u32 = 120;
    const H: u32 = 60;
    const pixels = try gpa.alloc(u32, W * H);
    defer gpa.free(pixels);

    const bg = packStraight(0.0, 0.0, 0.0, 1.0);
    var canvas = Canvas.initRgba8(pixels, W, H);

    // Spinner: a partial ring, so some pixels change and the very centre stays background.
    @memset(pixels, bg);
    canvas.drawSpinner(30, 30, 18, 4, 0.3, Color.rgba(120, 200, 255, 1.0));
    var ink: usize = 0;
    for (pixels) |p| {
        if (p != bg) ink += 1;
    }
    try std.testing.expect(ink > 20);
    try std.testing.expectEqual(bg, pixels[30 * W + 30]); // hollow centre

    // Determinate bar at 50%: the left edge is filled, past 60% is still track colour.
    @memset(pixels, bg);
    const track = Color.rgba(40, 40, 50, 1.0);
    const fill = Color.rgba(120, 200, 255, 1.0);
    canvas.fillProgressBar(10, 25, 100, 10, 5, 0.5, track, fill);
    const r_lo = unpackStraight(pixels[30 * W + 20]); // ~10% across → filled
    const r_hi = unpackStraight(pixels[30 * W + 100]); // ~90% across → track
    try std.testing.expect(r_lo[2] > r_hi[2]); // fill is bluer (higher B) than the track
}

test "vertical gradient interpolates top→bottom and matches flat fill when colors are equal" {
    const gpa = std.testing.allocator;
    const W: u32 = 60;
    const H: u32 = 60;
    const px = try gpa.alloc(u32, W * H);
    defer gpa.free(px);
    const bg = packStraight(0.0, 0.0, 0.0, 1.0);
    var canvas = Canvas.initRgba8(px, W, H);

    // A gradient from red at the top to blue at the bottom: top row is redder, bottom bluer.
    @memset(px, bg);
    const top = Color.rgba(255, 0, 0, 1.0);
    const bot = Color.rgba(0, 0, 255, 1.0);
    canvas.fillRoundedRectVGradient(6, 6, 48, 48, 6, top, bot);
    const near_top = unpackStraight(px[12 * W + 30]);
    const near_bot = unpackStraight(px[48 * W + 30]);
    try std.testing.expect(near_top[0] > near_bot[0]); // more red up top
    try std.testing.expect(near_bot[2] > near_top[2]); // more blue at the bottom

    // Equal endpoints must be byte-identical to the flat rounded-rect fill.
    const flat = Color.rgba(90, 140, 210, 0.8);
    const a = try gpa.alloc(u32, W * H);
    defer gpa.free(a);
    const b = try gpa.alloc(u32, W * H);
    defer gpa.free(b);
    @memset(a, bg);
    @memset(b, bg);
    var ca = Canvas.initRgba8(a, W, H);
    var cb = Canvas.initRgba8(b, W, H);
    ca.fillRoundedRectVGradient(6, 6, 48, 48, 10, flat, flat);
    cb.fillRoundedRect(6, 6, 48, 48, 10, flat);
    try std.testing.expectEqualSlices(u32, b, a);
}

test "drop shadow is solid under the shape and fades outward to nothing" {
    const gpa = std.testing.allocator;
    const W: u32 = 100;
    const H: u32 = 100;
    const px = try gpa.alloc(u32, W * H);
    defer gpa.free(px);
    // Opaque white background: a black shadow shows as darkened RGB (alpha stays 1).
    const bg = packStraight(1.0, 1.0, 1.0, 1.0);
    var canvas = Canvas.initRgba8(px, W, H);
    @memset(px, bg);

    // Shadow of a centered box, no offset, wide blur.
    canvas.dropShadowRoundedRect(30, 30, 40, 40, 8, 12, 0, Color.rgba(0, 0, 0, 0.6));
    const center = unpackStraight(px[50 * W + 50]);
    const just_out = unpackStraight(px[50 * W + 74]); // ~4px past the right edge
    const far_out = unpackStraight(px[50 * W + 92]); // well beyond the blur
    // Under the shape the shadow is at peak (darkest); it decays with distance; far away it is gone.
    try std.testing.expect(center[0] < just_out[0]);
    try std.testing.expect(just_out[0] < far_out[0]);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), far_out[0], 0.02); // untouched white background
    // Zero-alpha shadow is a no-op.
    const before = px[10 * W + 10];
    canvas.dropShadowRoundedRect(30, 30, 40, 40, 8, 12, 0, Color.rgba(0, 0, 0, 0.0));
    try std.testing.expectEqual(before, px[10 * W + 10]);
}

test "chrome paints premultiplied" {
    const gpa = std.testing.allocator;
    const px = try gpa.alloc(u32, 200 * 160);
    defer gpa.free(px);
    var canvas = Canvas.init(px, 200, 160);
    canvas.drawChrome(.{});
    // Center: glass alpha, premultiplied channels never exceed alpha.
    const c = px[80 * 200 + 100];
    const a = (c >> 24) & 0xff;
    try std.testing.expect(a > 100);
    try std.testing.expect((c >> 16 & 0xff) <= a and (c >> 8 & 0xff) <= a and (c & 0xff) <= a);
    // Corner of the gutter: fully transparent.
    try std.testing.expectEqual(@as(u32, 0), px[0]);
}

test "drawChrome flat-core equals the per-pixel reference" {
    const gpa = std.testing.allocator;
    const w: u32 = 220;
    const h: u32 = 180;
    // Non-trivial fade + radius so the core boundary is exercised near the corners.
    const style = Style{ .glass_fade_width = 6.0, .corner_radius = 16.0 };

    const fast = try gpa.alloc(u32, w * h);
    defer gpa.free(fast);
    var canvas = Canvas.init(fast, w, h);
    canvas.drawChrome(style);

    const m: f32 = @floatFromInt(style.margin);
    const pw = @as(f32, @floatFromInt(w)) - 2.0 * m;
    const ph = @as(f32, @floatFromInt(h)) - 2.0 * m;
    const g = style.glass;
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        var x: u32 = 0;
        while (x < w) : (x += 1) {
            const ref = Canvas.chromePixel(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5, style, g, m, pw, ph);
            try std.testing.expectEqual(ref, fast[y * w + x]);
        }
    }
}
