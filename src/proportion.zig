//! # proportion — golden-ratio design constants for the substrate
//!
//! φ (phi), the golden ratio, is the default proportion zicro/zrame reach for when
//! a ratio is otherwise arbitrary: type scales, panel splits, the responsive density
//! clamp (`zrame` grows the UI up to φ on large displays), and so on. Centralising it
//! here means "use the golden ratio" is one import (`zicro.phi`), not a magic literal
//! sprinkled across call sites — so the whole stack shares one canonical value.

/// The golden ratio, φ = (1 + √5) / 2 ≈ 1.618.
pub const phi: f32 = 1.618033988749895;
/// 1/φ = φ − 1 ≈ 0.618 — the fraction the MAJOR part takes of a golden split.
pub const inv_phi: f32 = 0.618033988749895;
/// φ² = φ + 1 ≈ 2.618 — two golden steps (e.g. a coarse type-scale jump).
pub const phi2: f32 = 2.618033988749895;

/// The larger part of a golden split of `whole` (`major = whole/φ`, so major/minor = φ).
pub fn goldenMajor(whole: f32) f32 {
    return whole * inv_phi;
}
/// The smaller part of a golden split of `whole` (`minor = whole/φ²`).
pub fn goldenMinor(whole: f32) f32 {
    return whole * (1.0 - inv_phi);
}

test "golden split reconstitutes the whole in φ:1 proportion" {
    const std = @import("std");
    const w: f32 = 100;
    const major = goldenMajor(w);
    const minor = goldenMinor(w);
    try std.testing.expectApproxEqAbs(w, major + minor, 1e-3);
    try std.testing.expectApproxEqAbs(phi, major / minor, 1e-3);
}
