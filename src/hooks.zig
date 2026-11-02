//! Optional hooks found by reflection — the ONE rule every such site follows.
//!
//! Several generic types call a method only if the wrapped type declares it: a module's
//! `deinit`/`subscriptions` (core.zig), a document state's `clone`/`deinit`
//! (document.zig), a media payload's `deinit` (media.zig), an audio sink's `playRaw`
//! (audio.zig). They all ask [`has`].
//!
//! ## The contract: a hook must be `pub`
//! Since Zig 0.17, `@hasDecl` and `std.meta.hasFn` see only `pub` declarations — even
//! from the same file — and say so by returning `false`, not by failing to compile. A
//! hook written as plain `fn deinit` is therefore **silently skipped**: the code compiles
//! and the cleanup never runs (a leak, or a missing fast path). The language offers no way
//! to detect the non-`pub` declaration from here, so the rule is stated once, in this file,
//! pinned by the tests below, and every hook site links to it.

const std = @import("std");

/// Whether `T` declares a `pub fn name`. A non-`pub` `fn name` reads as absent (see the
/// module doc); so does any non-container `T` (e.g. a plain integer state).
pub inline fn has(comptime T: type, comptime name: []const u8) bool {
    return std.meta.hasFn(T, name);
}

const testing = std.testing;

const WithPub = struct {
    pub fn deinit(_: *WithPub) void {}
};
const WithPrivate = struct {
    fn deinit(_: *WithPrivate) void {}
};
const WithConst = struct {
    pub const deinit = 3; // a declaration, but not a function: not a hook
};
const Without = struct {};

test "a pub hook is found" {
    try testing.expect(has(WithPub, "deinit"));
}

test "an absent hook, a non-function decl and a non-container type are not hooks" {
    try testing.expect(!has(Without, "deinit"));
    try testing.expect(!has(WithConst, "deinit"));
    try testing.expect(!has(i64, "deinit"));
}

test "a NON-pub hook is invisible (Zig 0.17) — this is why hooks must be pub" {
    // If a future Zig makes this visible again, this test fails and the contract above
    // (and every site relying on it) can be revisited.
    try testing.expect(!has(WithPrivate, "deinit"));
    _ = WithPrivate.deinit; // the declaration exists; reflection just cannot see it
}
