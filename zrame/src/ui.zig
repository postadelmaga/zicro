//! # zrame.ui — shared widget helpers
//!
//! The panels (`controls`, `menu`, `scroll`) animate through this small surface. The math
//! itself now lives in `zicro.anim` (the common animation home for zicro-based UIs); this
//! module just re-exports it under the `ui.*` names the panels already use, so there is a
//! single source of truth for easing/fade timing.

const anim = @import("zicro").anim;

/// Seconds for `approach` to travel the full 0↔1 range (egui `animate_bool_responsive`).
pub const anim_time = anim.anim_time;
/// Ease-out cubic (egui `cubic_out`) — fades/reveals.
pub const cubicOut = anim.cubicOut;
/// Smoothstep ease-in-out (`3t²−2t³`) — symmetric transitions.
pub const easeInOut = anim.easeInOut;
/// Advance a linear 0..1 factor toward a boolean target by one `dt` step.
pub const approach = anim.approach;
/// Linear interpolation.
pub const lerp = anim.lerp;
/// Map a value between two ranges, clamped to the output.
pub const remapClamp = anim.remapClamp;
