//! # zicro.document — a generic undoable document (action + reducer)
//!
//! [`Doc`] is the single source of truth for an app's state `S`. State changes are
//! described by **actions** `A` — plain, serializable values — and applied by a single
//! **reducer** `fn(*S, *const A) !void`. Making mutations *data* (not function objects)
//! is the robustness win: an action can be logged, replayed, persisted, or sent across
//! the bus, and the same action stream always reproduces the same state.
//!
//! Every dispatch is **transactional and undoable**: the reducer runs against a *clone*,
//! so a rejected action (an error) leaves the live state untouched; a successful one
//! pushes the previous state onto an undo stack.
//!
//! The file is domain-free on purpose — the app brings the state type, the action type,
//! and the reducer. A counter, a tree, a scene graph all reuse the same machinery.
//!
//! Port note (Rust → Zig): `S: Clone` becomes duck typing — if `S` declares
//! `clone(self, Allocator) !S` / `deinit(self, Allocator) void` they are used; a plain
//! value type (no heap inside) is copied bitwise. The reducer is a plain function
//! pointer plus an optional context pointer (Zig has no capturing closures).

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Default undo depth when none is given.
pub const default_max_depth: usize = 100;

fn cloneState(comptime S: type, gpa: Allocator, s: *const S) !S {
    if (comptime std.meta.hasFn(S, "clone")) return s.clone(gpa);
    return s.*;
}

fn deinitState(comptime S: type, gpa: Allocator, s: *S) void {
    if (comptime std.meta.hasFn(S, "deinit")) s.deinit(gpa);
}

/// Generic undo/redo history for any cloneable state `S`. Holds the present value plus
/// bounded past/future stacks.
pub fn History(comptime S: type) type {
    return struct {
        gpa: Allocator,
        past: std.ArrayListUnmanaged(S) = .empty,
        present: S,
        future: std.ArrayListUnmanaged(S) = .empty,
        max_depth: usize,

        const Self = @This();

        pub fn init(gpa: Allocator, initial: S, max_depth: usize) Self {
            return .{ .gpa = gpa, .present = initial, .max_depth = max_depth };
        }

        pub fn deinit(self: *Self) void {
            for (self.past.items) |*s| deinitState(S, self.gpa, s);
            self.past.deinit(self.gpa);
            for (self.future.items) |*s| deinitState(S, self.gpa, s);
            self.future.deinit(self.gpa);
            deinitState(S, self.gpa, &self.present);
        }

        /// The current state.
        pub fn present_(self: *const Self) *const S {
            return &self.present;
        }

        pub fn canUndo(self: *const Self) bool {
            return self.past.items.len > 0;
        }

        pub fn canRedo(self: *const Self) bool {
            return self.future.items.len > 0;
        }

        /// Record `next` as the new present, pushing the old present onto the undo stack
        /// and clearing the redo stack. The undo stack is capped at `max_depth`.
        pub fn commit(self: *Self, next: S) Allocator.Error!void {
            try self.past.append(self.gpa, self.present);
            self.present = next;
            if (self.past.items.len > self.max_depth) {
                var evicted = self.past.orderedRemove(0);
                deinitState(S, self.gpa, &evicted);
            }
            for (self.future.items) |*s| deinitState(S, self.gpa, s);
            self.future.clearRetainingCapacity();
        }

        /// Step back one state. Returns `false` if there is nothing to undo.
        pub fn undo(self: *Self) bool {
            const prev = self.past.pop() orelse return false;
            self.future.append(self.gpa, self.present) catch |e| switch (e) {
                // Put it back rather than losing a state on OOM.
                error.OutOfMemory => {
                    self.past.appendAssumeCapacity(prev);
                    return false;
                },
            };
            self.present = prev;
            return true;
        }

        /// Step forward one state. Returns `false` if there is nothing to redo.
        pub fn redo(self: *Self) bool {
            const next = self.future.pop() orelse return false;
            self.past.append(self.gpa, self.present) catch |e| switch (e) {
                error.OutOfMemory => {
                    self.future.appendAssumeCapacity(next);
                    return false;
                },
            };
            self.present = next;
            return true;
        }
    };
}

/// The undo/redo verbs as a serializable action an app can route over the bus and turn
/// into [`Doc.undo`] / [`Doc.redo`] calls. (Serializes as `"undo"` / `"redo"`.)
pub const HistoryAction = enum { undo, redo };

/// The application document: state `S` behind an undo/redo [`History`], mutated only by
/// dispatching serializable actions `A` through a fixed reducer.
///
/// The reducer is `reduce(ctx, *S, *const A) anyerror!void`: return an error to reject
/// the action — the document then stays unchanged. `ctx` is an optional context pointer
/// for reducers that need one (pass `null` and ignore it otherwise).
pub fn Doc(comptime S: type, comptime A: type) type {
    return struct {
        history: History(S),
        reducer: *const ReduceFn,
        reducer_ctx: ?*anyopaque,

        pub const ReduceFn = fn (ctx: ?*anyopaque, state: *S, action: *const A) anyerror!void;

        const Self = @This();

        /// New document with the default undo depth and the given reducer.
        pub fn init(gpa: Allocator, initial: S, reducer: *const ReduceFn) Self {
            return initDepth(gpa, initial, default_max_depth, reducer, null);
        }

        /// New document with an explicit undo depth and reducer context.
        pub fn initDepth(
            gpa: Allocator,
            initial: S,
            max_depth: usize,
            reducer: *const ReduceFn,
            reducer_ctx: ?*anyopaque,
        ) Self {
            return .{
                .history = .init(gpa, initial, max_depth),
                .reducer = reducer,
                .reducer_ctx = reducer_ctx,
            };
        }

        pub fn deinit(self: *Self) void {
            self.history.deinit();
        }

        /// The current state.
        pub fn state(self: *const Self) *const S {
            return self.history.present_();
        }

        /// Apply an action transactionally: the reducer runs against a clone, and only a
        /// successful result is committed to history. A rejected action leaves the
        /// document untouched.
        pub fn dispatch(self: *Self, action: *const A) anyerror!void {
            var next = try cloneState(S, self.history.gpa, self.state());
            errdefer deinitState(S, self.history.gpa, &next);
            try self.reducer(self.reducer_ctx, &next, action);
            try self.history.commit(next);
        }

        pub fn undo(self: *Self) bool {
            return self.history.undo();
        }

        pub fn redo(self: *Self) bool {
            return self.history.redo();
        }

        pub fn canUndo(self: *const Self) bool {
            return self.history.canUndo();
        }

        pub fn canRedo(self: *const Self) bool {
            return self.history.canRedo();
        }
    };
}

// --- tests ---------------------------------------------------------------------------------

const CounterAction = union(enum) {
    add: i64,
    /// Rejected when it would take the counter negative.
    sub: i64,
};

fn reduce(_: ?*anyopaque, state: *i64, action: *const CounterAction) anyerror!void {
    switch (action.*) {
        .add => |n| state.* += n,
        .sub => |n| {
            if (state.* - n < 0) return error.WouldGoNegative;
            state.* -= n;
        },
    }
}

fn testDoc() Doc(i64, CounterAction) {
    return .init(std.testing.allocator, 0, reduce);
}

test "dispatch then undo redo" {
    var d = testDoc();
    defer d.deinit();
    try d.dispatch(&.{ .add = 5 });
    try d.dispatch(&.{ .add = 3 });
    try std.testing.expectEqual(@as(i64, 8), d.state().*);

    try std.testing.expect(d.undo());
    try std.testing.expectEqual(@as(i64, 5), d.state().*);
    try std.testing.expect(d.redo());
    try std.testing.expectEqual(@as(i64, 8), d.state().*);
}

test "rejected action leaves state and history untouched" {
    var d = testDoc();
    defer d.deinit();
    try d.dispatch(&.{ .add = 2 });
    try std.testing.expectError(error.WouldGoNegative, d.dispatch(&.{ .sub = 10 }));
    try std.testing.expectEqual(@as(i64, 2), d.state().*);
    // Only the successful add is on the undo stack.
    try std.testing.expect(d.undo());
    try std.testing.expectEqual(@as(i64, 0), d.state().*);
    try std.testing.expect(!d.canUndo());
}

test "new dispatch clears redo" {
    var d = testDoc();
    defer d.deinit();
    try d.dispatch(&.{ .add = 1 });
    _ = d.undo();
    try std.testing.expect(d.canRedo());
    try d.dispatch(&.{ .add = 9 });
    try std.testing.expect(!d.canRedo());
    try std.testing.expectEqual(@as(i64, 9), d.state().*);
}

test "actions are data: replaying reproduces state" {
    const gpa = std.testing.allocator;
    // The whole point of action+reducer: a recorded action log replays to the same state.
    const log = [_]CounterAction{ .{ .add = 10 }, .{ .sub = 4 }, .{ .add = 1 } };
    // Round-trip the log through JSON to prove actions are serializable data.
    const json = try std.json.Stringify.valueAlloc(gpa, log, .{});
    defer gpa.free(json);
    const replayed = try std.json.parseFromSlice([3]CounterAction, gpa, json, .{});
    defer replayed.deinit();

    var d = testDoc();
    defer d.deinit();
    for (&replayed.value) |*a| try d.dispatch(a);
    try std.testing.expectEqual(@as(i64, 7), d.state().*);
}
