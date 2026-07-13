//! # gesture — recognizer multi-touch condiviso dai backend finestra
//!
//! Logica PURA (nessuna dipendenza dal windowing): i backend (web, android, …) inoltrano
//! QUI i punti touch grezzi e ricevono eventi di alto livello. Un dito diventa un normale
//! evento puntatore (così tap/drag/UI funzionano identici al mouse); due dita diventano un
//! PINCH semantico (scala + centro + traslazione), che l'app interpreta a modo suo (zoom
//! del palco, ecc.). Vivendo nel substrato è condiviso da tutti i backend invece di essere
//! reimplementato per piattaforma.

const std = @import("std");

pub const Phase = enum(u32) { down = 0, move = 1, up = 2 };

/// Gesto a due dita. `scale` è il rapporto di zoom INCREMENTALE dall'ultimo campione
/// (1 = invariato); `(cx,cy)` il centro delle dita; `(dx,dy)` la traslazione del centro
/// dall'ultimo campione. L'app applica lo zoom ancorato a (cx,cy) e/o il pan di (dx,dy).
pub const Gesture = struct {
    scale: f32 = 1,
    cx: f32 = 0,
    cy: f32 = 0,
    dx: f32 = 0,
    dy: f32 = 0,
};

/// Un evento emesso dal recognizer. I `pointer_*` vanno inoltrati al path mouse del
/// backend (tasto sinistro); `pinch` al callback gesti dell'app.
pub const Out = union(enum) {
    pointer_down: struct { x: f32, y: f32 },
    pointer_move: struct { x: f32, y: f32 },
    pointer_up: struct { x: f32, y: f32 },
    pinch: Gesture,
};

pub const Recognizer = struct {
    pub const max_touch = 8;
    const Pt = struct { id: i32 = -1, x: f32 = 0, y: f32 = 0 };

    pts: [max_touch]Pt = [_]Pt{.{}} ** max_touch,
    n: usize = 0,
    pinching: bool = false,
    prev_dist: f32 = 0,
    prev_cx: f32 = 0,
    prev_cy: f32 = 0,

    fn find(self: *const Recognizer, id: i32) ?usize {
        var i: usize = 0;
        while (i < self.n) : (i += 1) if (self.pts[i].id == id) return i;
        return null;
    }

    /// Consuma un campione touch; scrive fino a 2 eventi in `out` e ne ritorna la slice.
    /// `x,y` in px nello spazio contenuto del backend.
    pub fn push(self: *Recognizer, id: i32, phase: Phase, x: f32, y: f32, out: *[2]Out) []const Out {
        switch (phase) {
            .down => if (self.n < max_touch and self.find(id) == null) {
                self.pts[self.n] = .{ .id = id, .x = x, .y = y };
                self.n += 1;
            },
            .move => if (self.find(id)) |i| {
                self.pts[i].x = x;
                self.pts[i].y = y;
            },
            .up => if (self.find(id)) |i| {
                self.pts[i] = self.pts[self.n - 1];
                self.n -= 1;
            },
        }

        var k: usize = 0;
        if (self.n >= 2) {
            const a = self.pts[0];
            const b = self.pts[1];
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            const dist = @sqrt(dx * dx + dy * dy);
            const cx = (a.x + b.x) * 0.5;
            const cy = (a.y + b.y) * 0.5;
            if (!self.pinching) {
                // 1→2 dita: chiudi l'eventuale gesto a un dito in corso.
                out[k] = .{ .pointer_up = .{ .x = a.x, .y = a.y } };
                k += 1;
                self.pinching = true;
                self.prev_dist = dist;
                self.prev_cx = cx;
                self.prev_cy = cy;
            } else if (phase == .move and dist > 1 and self.prev_dist > 1) {
                out[k] = .{ .pinch = .{
                    .scale = dist / self.prev_dist,
                    .cx = cx,
                    .cy = cy,
                    .dx = cx - self.prev_cx,
                    .dy = cy - self.prev_cy,
                } };
                k += 1;
                self.prev_dist = dist;
                self.prev_cx = cx;
                self.prev_cy = cy;
            }
            return out[0..k];
        }

        // meno di 2 dita
        if (self.pinching) {
            // fine pinch: niente ripresa del singolo dito finché non si staccano tutte.
            self.pinching = false;
            self.prev_dist = 0;
            return out[0..0];
        }
        if (self.n == 1) {
            const t = self.pts[0];
            switch (phase) {
                // motion PRIMA della press (come il path pointer): porta la pos del mouse
                // dell'app sul punto toccato, così il click colpisce lì.
                .down => {
                    out[0] = .{ .pointer_move = .{ .x = t.x, .y = t.y } };
                    out[1] = .{ .pointer_down = .{ .x = t.x, .y = t.y } };
                    k = 2;
                },
                .move => {
                    out[0] = .{ .pointer_move = .{ .x = t.x, .y = t.y } };
                    k = 1;
                },
                .up => {},
            }
        } else if (phase == .up) {
            // ultimo dito sollevato → rilascio del tasto sinistro sintetico.
            out[0] = .{ .pointer_up = .{ .x = x, .y = y } };
            k = 1;
        }
        return out[0..k];
    }
};

test "un dito → eventi puntatore; due dita → pinch" {
    var r = Recognizer{};
    var out: [2]Out = undefined;
    // giù un dito → move + down
    const e1 = r.push(1, .down, 10, 10, &out);
    try std.testing.expectEqual(@as(usize, 2), e1.len);
    try std.testing.expect(e1[0] == .pointer_move and e1[1] == .pointer_down);
    // secondo dito → pointer_up (annulla il singolo)
    const e2 = r.push(2, .down, 20, 10, &out);
    try std.testing.expect(e2.len == 1 and e2[0] == .pointer_up);
    // allontana un dito → pinch con scale > 1
    const e3 = r.push(2, .move, 40, 10, &out);
    try std.testing.expect(e3.len == 1 and e3[0] == .pinch and e3[0].pinch.scale > 1);
    // stacca un dito → nessun evento, esce dal pinch
    const e4 = r.push(2, .up, 40, 10, &out);
    try std.testing.expectEqual(@as(usize, 0), e4.len);
}
