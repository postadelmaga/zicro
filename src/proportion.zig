//! # proportion — the substrate's canonical proportion
//!
//! φ (phi), the golden ratio, is the default proportion zicro/zrame reach for when a
//! ratio is otherwise arbitrary (e.g. zrame's responsive density clamp grows the UI up
//! to φ on large displays). Centralising it means "use the golden ratio" is one import
//! (`zicro.phi`), not a magic literal sprinkled across call sites.

/// The golden ratio, φ = (1 + √5) / 2 ≈ 1.618.
pub const phi: f32 = 1.618033988749895;
