//! # zicro.anim — frame-rate-independent animation primitives
//!
//! Pure, dependency-free math the UI layers share: a damped [`Spring`] for springy motion
//! (window resize, panel slides, camera moves), plus the easing curves and the boolean
//! "approach" used for hover/fade. Every motion integrates in fixed substeps, so it looks
//! identical regardless of the frame rate it is ticked at.

const std = @import("std");

// ── spring ────────────────────────────────────────────────────────────────────

/// Spring tuning. `stiffness = ω²`, `damping = 2·ζ·ω` (ω = natural frequency in rad/s,
/// ζ = damping ratio: <1 overshoots, =1 is critical, >1 is sluggish). `rest`/`rest_vel`
/// are the settle thresholds in position and velocity units.
pub const SpringParams = struct {
    stiffness: f32 = 340.0,
    damping: f32 = 24.0,
    rest: f32 = 0.5,
    rest_vel: f32 = 2.0,
};

/// Lively settle (~0.45s) with a small (~7%) overshoot — ω≈18.4, ζ≈0.65. The default.
pub const snappy = SpringParams{ .stiffness = 340.0, .damping = 24.0 };
/// Critically damped: quick but no overshoot — ω≈11, ζ≈1.0.
pub const gentle = SpringParams{ .stiffness = 120.0, .damping = 22.0 };
/// Fast and tight, a hint of overshoot — ω≈26, ζ≈0.79.
pub const stiff = SpringParams{ .stiffness = 700.0, .damping = 42.0 };

/// A one-dimensional damped spring. Drive `pos` toward a moving `target`; retargeting
/// mid-flight keeps the current velocity, so chained moves stay fluid. Tick it with
/// [`step`] each frame and read `pos`.
pub const Spring = struct {
    pos: f32 = 0,
    vel: f32 = 0,
    target: f32 = 0,
    params: SpringParams = .{},
    active: bool = false,

    /// Fixed integration substep. The solver always advances in these increments (a
    /// semi-implicit Euler step, stable even for large `dt`), which is what makes the
    /// motion frame-rate-independent: a 30 Hz tick and a 144 Hz tick trace the same curve.
    pub const substep: f32 = 1.0 / 240.0;

    /// At rest at `value` (target = value, no animation).
    pub fn init(value: f32, params: SpringParams) Spring {
        return .{ .pos = value, .vel = 0, .target = value, .params = params, .active = false };
    }

    /// Jump to `value` and stop.
    pub fn reset(self: *Spring, value: f32) void {
        self.pos = value;
        self.vel = 0;
        self.target = value;
        self.active = false;
    }

    /// Aim at `target` and start moving. Position and velocity are preserved, so calling
    /// this mid-flight bends the trajectory smoothly instead of restarting it.
    pub fn retarget(self: *Spring, target: f32) void {
        self.target = target;
        self.active = true;
    }

    /// Advance by `dt` seconds. Returns true while still in motion; on settle it snaps
    /// exactly onto the target, zeroes velocity and clears `active` (so an idle spring
    /// returns false and costs nothing).
    pub fn step(self: *Spring, dt: f32) bool {
        if (!self.active) return false;
        const k = self.params.stiffness;
        const c = self.params.damping;
        var remaining = dt;
        while (remaining > 0) {
            const st = @min(substep, remaining);
            remaining -= st;
            self.vel += (k * (self.target - self.pos) - c * self.vel) * st;
            self.pos += self.vel * st;
        }
        if (@abs(self.target - self.pos) < self.params.rest and @abs(self.vel) < self.params.rest_vel) {
            self.pos = self.target;
            self.vel = 0;
            self.active = false;
        }
        return self.active;
    }
};

// ── easing & fades ──────────────────────────────────────────────────────────────

/// Seconds for an [`approach`] factor to travel the full 0↔1 range. Matches egui's
/// `animate_bool_responsive` (~1/12 s) so hover/fade timing feels the same as the reference.
pub const anim_time: f32 = 0.0833;

/// Ease-out cubic: fast start, gentle stop (egui's `cubic_out`) — for fades and reveals.
pub fn cubicOut(t: f32) f32 {
    const u = 1.0 - std.math.clamp(t, 0.0, 1.0);
    return 1.0 - u * u * u;
}

/// Smoothstep ease-in-out (`3t²−2t³`) over 0..1 — for symmetric transitions.
pub fn easeInOut(t: f32) f32 {
    const x = std.math.clamp(t, 0.0, 1.0);
    return x * x * (3.0 - 2.0 * x);
}

/// Smoothstep between two edges: 0 below `edge0`, 1 above `edge1`, `3t²−2t³` between.
pub fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    if (edge1 == edge0) return if (x < edge0) 0.0 else 1.0;
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Advance a linear 0..1 `factor` toward `target` by one `dt` step (reaching either end in
/// [`anim_time`]). Store the linear factor; apply [`cubicOut`]/[`easeInOut`] when you read
/// it. Returns the new factor — compare to the old to know whether it still moved.
pub fn approach(factor: f32, target: bool, dt: f32) f32 {
    const step_amt = dt / anim_time;
    return std.math.clamp(factor + (if (target) step_amt else -step_amt), 0.0, 1.0);
}

/// Linear interpolation.
pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

/// Map `v` from `[in0,in1]` to `[out0,out1]`, clamped to the output range.
pub fn remapClamp(v: f32, in0: f32, in1: f32, out0: f32, out1: f32) f32 {
    if (in1 == in0) return out0;
    const t = std.math.clamp((v - in0) / (in1 - in0), 0.0, 1.0);
    return out0 + (out1 - out0) * t;
}

// ── tests ─────────────────────────────────────────────────────────────────────

test "spring settles onto its target and goes inactive" {
    var s = Spring.init(0, snappy);
    s.retarget(100);
    var t: f32 = 0;
    // 3 s is well past the ~0.45 s settle time.
    while (t < 3.0) : (t += 0.016) {
        if (!s.step(0.016)) break;
    }
    try std.testing.expect(!s.active);
    try std.testing.expectEqual(@as(f32, 100), s.pos);
    try std.testing.expectEqual(@as(f32, 0), s.vel);
}

test "an idle spring is free" {
    var s = Spring.init(42, snappy);
    try std.testing.expect(!s.step(0.016)); // no retarget → no motion, no cost
    try std.testing.expectEqual(@as(f32, 42), s.pos);
}

test "snappy overshoots, gentle does not" {
    var over: f32 = 0;
    var sn = Spring.init(0, snappy);
    sn.retarget(100);
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        _ = sn.step(0.004);
        over = @max(over, sn.pos);
    }
    try std.testing.expect(over > 100.0); // underdamped → crosses the target

    var peak: f32 = 0;
    var ge = Spring.init(0, gentle);
    ge.retarget(100);
    i = 0;
    while (i < 400) : (i += 1) {
        _ = ge.step(0.004);
        peak = @max(peak, ge.pos);
    }
    try std.testing.expect(peak <= 100.5); // critically damped → no meaningful overshoot
}

test "spring is ~frame-rate independent" {
    // Same total time, different tick sizes → nearly the same trajectory.
    var coarse = Spring.init(0, snappy);
    coarse.retarget(200);
    var fine = Spring.init(0, snappy);
    fine.retarget(200);
    var t: f32 = 0;
    while (t < 0.2) : (t += 0.033) _ = coarse.step(0.033);
    t = 0;
    while (t < 0.2) : (t += 0.004) _ = fine.step(0.004);
    try std.testing.expectApproxEqAbs(coarse.pos, fine.pos, 2.0); // within 2 of 200
}

test "easing endpoints and remapClamp bounds" {
    try std.testing.expectApproxEqAbs(@as(f32, 0), cubicOut(0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), cubicOut(1), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), easeInOut(0), 1e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 1), easeInOut(1), 1e-6);
    try std.testing.expectEqual(@as(f32, 5), remapClamp(-3, 0, 10, 5, 25));
    try std.testing.expectEqual(@as(f32, 25), remapClamp(999, 0, 10, 5, 25));
    try std.testing.expectApproxEqAbs(@as(f32, 15), remapClamp(5, 0, 10, 5, 25), 1e-5);
}

test "approach saturates both ends" {
    var f: f32 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) f = approach(f, true, 0.016);
    try std.testing.expectEqual(@as(f32, 1.0), f);
    i = 0;
    while (i < 8) : (i += 1) f = approach(f, false, 0.016);
    try std.testing.expectEqual(@as(f32, 0.0), f);
}
