//! # zicro.input — the input source
//!
//! Input is the **source** end of zicro's `sources → world → sinks` dataflow. A real UI
//! frontend owns the OS event loop and pumps raw, device-specific events on its main
//! thread. This file does *not* depend on any of those: it defines a small,
//! **device-neutral** [`InputEvent`] vocabulary and an [`InputMapper`] that turns those
//! events into the app's own **actions** and publishes them on the bus, so the `world`
//! can reduce them like any other message.
//!
//! ## Why no windowing dependency
//! Translating a concrete frontend's events into [`InputEvent`] is intentionally left to
//! the **app**. Keeping that mapping outside the framework means zicro never pins a
//! windowing stack or its version; an app can target any toolkit, a test harness, or a
//! replay log without this file changing. The app writes a tiny `toolkit event →
//! InputEvent` adapter once; everything downstream speaks the neutral vocabulary.
//!
//! ## The shape of a mapping
//! An app declares an action type `A` and a [`Topic`](protocol.Topic) for the channel
//! those actions ride. It builds an [`InputMapper`] with a function
//! `fn(*const InputEvent) ?A`: returning a value emits an action, returning `null`
//! ignores the event. Ignoring is the common case — most raw events (mouse moves,
//! modifier-only keys, keys the app doesn't bind) map to nothing, and that is **not**
//! an error.

const std = @import("std");

const protocol = @import("protocol.zig");
const bus_mod = @import("bus.zig");

/// A device-neutral key. Deliberately a *small* set — printable characters arrive as
/// [`Key.char`] (the frontend has already resolved layout/IME to a character), and the
/// few named keys are the ones an app commonly binds. An app that needs more extends its
/// own adapter; the framework stays minimal.
pub const Key = union(enum) {
    char: u21,
    escape,
    enter,
    space,
    backspace,
    tab,
    up,
    down,
    left,
    right,
};

/// A device-neutral mouse button.
pub const MouseButton = enum { left, right, middle };

/// A device-neutral input event — the only vocabulary this file exposes to the rest of
/// the app. Press/release are split into `key_down`/`key_up` (and a `pressed` flag for
/// the mouse) so a mapper can bind either edge, e.g. fire on key *down* but stop on key
/// *up*.
pub const InputEvent = union(enum) {
    key_down: Key,
    key_up: Key,
    mouse_moved: struct { x: f64, y: f64 },
    mouse_button: struct { button: MouseButton, pressed: bool },
    wheel: struct { delta: f32 },
};

/// Translates [`InputEvent`]s into app actions and publishes them on the bus.
///
/// It owns the three things needed to emit an action: the shared bus, the module id
/// stamped on every envelope it sends (so consumers can see input is the source), and
/// the [`Topic`](protocol.Topic) naming the channel + payload type of the actions. The
/// map function is the app's policy — the only domain knowledge here.
pub fn InputMapper(comptime A: type) type {
    return struct {
        bus: *bus_mod.LocalBus,
        id: []const u8,
        topic: protocol.Topic(A),
        map: *const fn (*const InputEvent) ?A,

        const Self = @This();

        /// Build a mapper. `id` is the source name stamped on published envelopes;
        /// `topic` binds the action channel to `A`; `map` decides, per event, whether
        /// (and which) action to emit.
        pub fn init(
            bus: *bus_mod.LocalBus,
            id: []const u8,
            topic: protocol.Topic(A),
            map: *const fn (*const InputEvent) ?A,
        ) Self {
            return .{ .bus = bus, .id = id, .topic = topic, .map = map };
        }

        /// Run one event through the mapping. If it yields an action, encode it on the
        /// topic (stamped with this mapper's id) and publish it; if it yields `null`, do
        /// nothing and succeed — an unmapped event is normal, not an error. The only
        /// error is a genuine encode/publish failure.
        pub fn feed(self: *const Self, event: *const InputEvent) bus_mod.BusError!void {
            const action = self.map(event) orelse return;
            return self.bus.publishMsg(self.id, self.topic.channel, action);
        }

        /// Feed a batch of events in order — convenience for draining a frame's worth of
        /// events. Stops at the first publish error (none of which a pure mapping
        /// function can cause).
        pub fn feedAll(self: *const Self, events: []const InputEvent) bus_mod.BusError!void {
            for (events) |*event| try self.feed(event);
        }
    };
}

// --- tests ---------------------------------------------------------------------------------

const testing = std.testing;

const Move = enum { left, right, jump };

fn mapMove(ev: *const InputEvent) ?Move {
    return switch (ev.*) {
        .key_down => |key| switch (key) {
            .left => .left,
            .right => .right,
            .space => .jump,
            else => null,
        },
        else => null,
    };
}

fn decodeMove(msg: bus_mod.Msg) !Move {
    defer msg.deinit();
    const parsed = try msg.env().decode(Move, testing.allocator);
    defer parsed.deinit();
    return parsed.value;
}

test "maps bound events to actions and ignores the rest" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var bus = bus_mod.LocalBus.init(testing.allocator, threaded.io());
    defer bus.deinit();

    const topic: protocol.Topic(Move) = .init("move");
    var rx = try bus.subscribe(topic.channel);
    defer rx.deinit();

    const mapper = InputMapper(Move).init(&bus, "input", topic, mapMove);

    // A mix of bound and unbound events; only three are bound.
    try mapper.feedAll(&.{
        .{ .key_down = .left },
        .{ .mouse_moved = .{ .x = 1.0, .y = 2.0 } }, // unmapped → nothing
        .{ .key_down = .right },
        .{ .key_up = .left }, // unmapped (only key_down is bound) → nothing
        .{ .key_down = .space },
    });

    // Exactly the mapped actions arrived, in order.
    try testing.expectEqual(Move.left, try decodeMove((try rx.tryRecv()).?));
    try testing.expectEqual(Move.right, try decodeMove((try rx.tryRecv()).?));
    try testing.expectEqual(Move.jump, try decodeMove((try rx.tryRecv()).?));
    // …and nothing else: the unmapped events produced no envelopes.
    try testing.expectEqual(null, try rx.tryRecv());
}

fn alwaysJump(_: *const InputEvent) ?Move {
    return .jump;
}

test "published action is stamped with the source id" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    var bus = bus_mod.LocalBus.init(testing.allocator, threaded.io());
    defer bus.deinit();

    const topic: protocol.Topic(Move) = .init("move");
    var rx = try bus.subscribe(topic.channel);
    defer rx.deinit();

    const mapper = InputMapper(Move).init(&bus, "kbd", topic, alwaysJump);
    try mapper.feed(&.{ .wheel = .{ .delta = 1.0 } });

    const msg = (try rx.tryRecv()).?;
    try testing.expectEqualStrings("kbd", msg.env().from);
    try testing.expectEqual(Move.jump, try decodeMove(msg));
}
