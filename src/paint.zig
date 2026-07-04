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

/// Signed distance from point `(px, py)` to a rounded rectangle: negative inside.
pub fn roundedRectSdf(px: f32, py: f32, x: f32, y: f32, w: f32, h: f32, radius: f32) f32 {
    const hw = w / 2.0;
    const hh = h / 2.0;
    const cx = x + hw;
    const cy = y + hh;
    const qx = @abs(px - cx) - (hw - radius);
    const qy = @abs(py - cy) - (hh - radius);
    const ox = @max(qx, 0.0);
    const oy = @max(qy, 0.0);
    return @sqrt(ox * ox + oy * oy) + @min(@max(qx, qy), 0.0) - radius;
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
fn srgbToLinear(u: f32) f32 {
    return if (u <= 0.04045) u / 12.92 else std.math.pow(f32, (u + 0.055) / 1.055, 2.4);
}

/// Linear light (0..1) → sRGB (0..1).
fn linearToSrgb(u: f32) f32 {
    const x = std.math.clamp(u, 0.0, 1.0);
    return if (x <= 0.0031308) x * 12.92 else 1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
}

/// macOS-style "font smoothing": lifts mid coverage to slightly fatten the
/// strokes (macOS renders text fuller and softer than raw grayscale). Exponent
/// < 1 → fuller.
fn smoothCoverage(a: f32) f32 {
    return std.math.pow(f32, std.math.clamp(a, 0.0, 1.0), 0.72);
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

        var y: u32 = 0;
        while (y < self.height) : (y += 1) {
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const row = self.pixels[@as(usize, y) * self.width ..][0..self.width];
            const core_row = has_core and y >= cy0 and y < cy1;
            var x: u32 = 0;
            while (x < self.width) : (x += 1) {
                if (core_row and x == cx0 and cx1 > cx0) {
                    @memset(row[cx0..cx1], core_px);
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
        const ga = g.a * glass_cov;
        var pr: f32 = g.r * ga;
        var pg: f32 = g.g * ga;
        var pb: f32 = g.b * ga;
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

        var sy: u32 = 0;
        while (sy < src_h) : (sy += 1) {
            const y = dst_y + sy;
            if (y >= self.height) break;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            const row = self.pixels[@as(usize, y) * self.width ..][0..self.width];
            const src_row = src[@as(usize, sy) * src_w * 4 ..][0 .. @as(usize, src_w) * 4];
            var sx: u32 = 0;
            while (sx < src_w) : (sx += 1) {
                const x = dst_x + sx;
                if (x >= self.width) break;
                const fx = @as(f32, @floatFromInt(x)) + 0.5;
                const d_panel = roundedRectSdf(fx, fy, m, m, pw, ph, style.corner_radius);
                const mask = coverage(d_panel);
                if (mask <= 0.0) continue;

                const d_content = roundedRectSdf(fx, fy, dx_f, dy_f, sw_f, sh_f, style.content_radius);
                var content_cov = coverage(d_content);
                if (content_cov <= 0.0) continue;

                if (style.content_fade_width > 0.0) {
                    content_cov *= smoothstep(0.0, style.content_fade_width, -d_content);
                }

                if (style.border_anim_width > 0.0) {
                    content_cov *= 1.0 - smoothstep(0.0, style.border_anim_width, -d_panel);
                }

                const sp = src_row[@as(usize, sx) * 4 ..][0..4];
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

    /// Fill a rounded rect with a straight-alpha color (source-over). For decorative
    /// content drawn by apps that don't push zicro frames.
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

    /// Stroke the line segment `a`→`b` as a rounded (capsule) stroke of the given
    /// `width`, anti-aliased and source-over composited. The building block for the
    /// procedural window-control glyphs (✕, –).
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
                const sa = color.a * cov;
                const dr, const dg, const db, const da = unpackPremul(row[px]);
                const inv = 1.0 - sa;
                row[px] = packPremul(
                    color.r * sa + dr * inv,
                    color.g * sa + dg * inv,
                    color.b * sa + db * inv,
                    sa + da * inv,
                );
            }
        }
    }

    /// Stroke the outline of a rounded rect: coverage of `|sdf| - stroke/2`, so the fill
    /// stays hollow. The maximize ▢ and the restore double-square are drawn with this.
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
                const sa = color.a * cov;
                const dr, const dg, const db, const da = unpackPremul(row[px]);
                const inv = 1.0 - sa;
                row[px] = packPremul(
                    color.r * sa + dr * inv,
                    color.g * sa + dg * inv,
                    color.b * sa + db * inv,
                    sa + da * inv,
                );
            }
        }
    }

    /// Draws `s` with `font` starting at `x` (left edge) and `baseline_y` (the
    /// text baseline), advancing the pen glyph by glyph. Composites the coverage
    /// over the premultiplied pixels (source-over). Use `font.ascent` to convert
    /// a top edge into a baseline if needed.
    pub fn drawText(self: *Canvas, font: *text.Font, x: i32, baseline_y: i32, s: []const u8, opts: TextOpts) void {
        var pen_x: i32 = x;
        var i: usize = 0;
        while (i < s.len) {
            const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
            const end = @min(i + seq, s.len);
            const cp: u32 = std.unicode.utf8Decode(s[i..end]) catch s[i];
            i = end;
            const g = font.getGlyph(opts.size, opts.style, cp) catch continue;
            self.blitGlyph(g, pen_x, baseline_y, opts.color);
            pen_x += g.advance;
        }
    }

    /// Blends a glyph's coverage (straight color) onto the premultiplied canvas.
    fn blitGlyph(self: *Canvas, g: *const text.Glyph, pen_x: i32, baseline_y: i32, color: Color) void {
        if (g.bitmap.len == 0) return;
        const gx0 = pen_x + g.xoff;
        const gy0 = baseline_y + g.yoff;
        const W: i32 = @intCast(self.width);
        const H: i32 = @intCast(self.height);
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
                // macOS-style stem darkening + coverage → alpha.
                const a0 = smoothCoverage(@as(f32, @floatFromInt(cov)) / 255.0);
                const sa = color.a * a0;
                if (sa <= 0.0) continue;
                const idx = @as(usize, @intCast(py)) * self.width + @as(usize, @intCast(px));
                const dr, const dg, const db, const da = unpackPremul(self.pixels[idx]);
                const inv = 1.0 - sa;
                // Gamma-correct "over": blend RGB in linear light (the premultiplied
                // channels are ~straight over the chrome's opaque panel), then back to
                // sRGB. The alpha stays linear (geometric coverage).
                self.pixels[idx] = packPremul(
                    linearToSrgb(srgbToLinear(color.r) * sa + srgbToLinear(dr) * inv),
                    linearToSrgb(srgbToLinear(color.g) * sa + srgbToLinear(dg) * inv),
                    linearToSrgb(srgbToLinear(color.b) * sa + srgbToLinear(db) * inv),
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
