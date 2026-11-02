//! The client half of the Z-Scenic wire protocol (Z's `user/scenic/protocol.zig`): one
//! request at a time, with every message that is NOT the awaited reply — unsolicited
//! events — kept instead of mistaken for it.
//!
//! ## Why a dispatcher at all
//! A client receives everything on ONE endpoint: replies (`ok`/`err`/`node_created`) and
//! unsolicited pushes (`key_event`, `pointer_event`, `close_request`, `configure`) share
//! it, and a push can land while a request is in flight (protocol.zig documents this for
//! `close_request` and `configure`). Reading "the next message" as the reply therefore
//! loses the push AND leaves the real reply to be misread as an event later. This is the
//! shape of Z's own reference client (`user/apps/win_client.zig`'s `call`), generalised.
//!
//! ## Semantics
//! * Requests are serialized (the protocol has no request ids): [`call`](Client.call)
//!   sends one and returns its reply — the first reply-tagged message — absorbing every
//!   event that arrives before it.
//! * `close_request` sets [`closed`](Client.closed) and is reported by
//!   [`nextEvent`](Client.nextEvent) before anything else; queued input is moot once
//!   the server has torn the window down. A reply still pending when it arrives is still
//!   awaited (the server answers the request — likely `err`, the root being gone).
//! * `configure` coalesces: only the newest size is kept (a zero-area one is ignored).
//! * `key_event`s queue in a fixed ring of [`event_capacity`] (the kernel endpoint's own
//!   depth, so a server that respects backpressure can never overflow it). Overflow
//!   policy: the NEWEST event is dropped and counted in `dropped_events` — never a
//!   blocking path, never an allocation.
//! * Unknown tags (the wire is not trusted, and a newer server may add pushes) are decoded
//!   with the protocol's own `tagFromRaw`, never `@enumFromInt`: they are counted and
//!   ignored. A capability carried on anything but a reply is closed, never leaked.
//! * A failed receive is an error, never a message read from an untouched buffer.
//!
//! The transport is a comptime parameter, so the whole state machine is tested on the
//! host against a scripted fake server (below) while Z runs it over real endpoints.

const std = @import("std");
const proto = @import("scenic_protocol");
const graph = proto.graph;

/// What a transport's `recv` hands back (Z's `rt.RecvMsg` shape).
pub const Msg = struct { tag: u64, words: [4]u64 = .{ 0, 0, 0, 0 }, cap: ?usize = null };

/// Fixed queue depth for input events — Z's endpoint ring is 16 deep.
pub const event_capacity = 16;

pub const Error = error{
    /// The transport refused a receive (bad/closed endpoint).
    RecvFailed,
};

/// A request's answer.
pub const Reply = union(enum) {
    ok,
    err: proto.Reason,
    node_created: graph.NodeId,
};

/// What the event loop should handle next, in priority order.
pub const Event = union(enum) {
    close,
    configure: proto.Configure,
    key: proto.KeyEvent,
};

/// `Transport` must provide:
/// * `fn send(*Transport, tag: u64, words: [4]u64, carry: ?usize) void`
/// * `fn recv(*Transport) Error!Msg` (blocking)
/// * `fn closeHandle(*Transport, handle: usize) void`
pub fn Client(comptime Transport: type) type {
    return struct {
        const Self = @This();

        transport: Transport,
        /// The server sent `close_request`: the window is gone server-side.
        closed: bool = false,
        configure_pending: ?proto.Configure = null,
        keys: [event_capacity]proto.KeyEvent = undefined,
        key_head: usize = 0,
        key_len: usize = 0,
        /// Input events dropped because the ring was full (see the module doc).
        dropped_events: u64 = 0,
        /// Messages ignored: unknown tags, client-bound requests, replies with no request
        /// outstanding. Nonzero means a protocol mismatch worth a log line, not a crash.
        ignored: u64 = 0,

        pub fn init(transport: Transport) Self {
            return .{ .transport = transport };
        }

        /// Send one request and wait for ITS reply, keeping every event that arrives
        /// first. `carry` is a capability to send along (copied, not moved — the caller
        /// still owns its handle).
        pub fn call(self: *Self, tag: proto.Tag, words: [4]u64, carry: ?usize) Error!Reply {
            self.transport.send(@intFromEnum(tag), words, carry);
            while (true) {
                const m = try self.transport.recv();
                if (self.absorb(m)) |reply| return reply;
            }
        }

        /// Send a request that has no reply (`disconnect`).
        pub fn sendOneWay(self: *Self, tag: proto.Tag, words: [4]u64) void {
            self.transport.send(@intFromEnum(tag), words, null);
        }

        /// The next thing for the event loop: `close` first, then the newest `configure`,
        /// then queued keys; blocks on the transport only when nothing is pending.
        pub fn nextEvent(self: *Self) Error!Event {
            while (true) {
                if (self.closed) return .close;
                if (self.configure_pending) |c| {
                    self.configure_pending = null;
                    return .{ .configure = c };
                }
                if (self.key_len > 0) {
                    const k = self.keys[self.key_head];
                    self.key_head = (self.key_head + 1) % event_capacity;
                    self.key_len -= 1;
                    return .{ .key = k };
                }
                const m = try self.transport.recv();
                if (self.absorb(m)) |_| self.ignored += 1; // a reply nobody asked for
            }
        }

        /// Classify one message: a reply is returned, an event is recorded (null).
        fn absorb(self: *Self, m: Msg) ?Reply {
            const tag = proto.tagFromRaw(m.tag) orelse {
                self.dropCap(m);
                self.ignored += 1;
                return null;
            };
            switch (tag) {
                // node_created may legitimately carry nothing else; replies never carry a cap
                // in this protocol, but if one did it is the caller's business, not ours.
                .ok => return .ok,
                .err => return .{ .err = proto.Err.decode(m.words).reason },
                .node_created => return .{ .node_created = proto.NodeCreated.decode(m.words).node },
                else => {},
            }
            self.dropCap(m);
            switch (tag) {
                .close_request => self.closed = true,
                .configure => {
                    const c = proto.Configure.decode(m.words);
                    if (c.w != 0 and c.h != 0) self.configure_pending = c else self.ignored += 1;
                },
                .key_event => {
                    if (self.key_len == event_capacity) {
                        self.dropped_events += 1;
                    } else {
                        self.keys[(self.key_head + self.key_len) % event_capacity] = proto.KeyEvent.decode(m.words);
                        self.key_len += 1;
                    }
                },
                // Hit-tested clicks arrive in absolute SCREEN coordinates and this protocol
                // phase never tells a client where its window is, so they cannot be mapped
                // to content coordinates yet: consumed, not delivered.
                .pointer_event => {},
                // Client->server requests (and the parent-only spawn_request) never come
                // from a server: a mismatch, ignored.
                else => self.ignored += 1,
            }
            return null;
        }

        fn dropCap(self: *Self, m: Msg) void {
            if (m.cap) |h| self.transport.closeHandle(h);
        }
    };
}

// --- tests: a scripted fake server ---------------------------------------------------------

const testing = std.testing;

/// Replays a fixed inbound script and records what the client sent. An exhausted script
/// fails the receive — so a client bug that would block forever fails the test instead.
pub const FakeTransport = struct {
    inbound: []const Msg,
    next: usize = 0,
    sent: [32]Msg = undefined,
    sent_len: usize = 0,
    closed_handles: [8]usize = undefined,
    closed_len: usize = 0,

    pub fn send(t: *FakeTransport, tag: u64, words: [4]u64, carry: ?usize) void {
        t.sent[t.sent_len] = .{ .tag = tag, .words = words, .cap = carry };
        t.sent_len += 1;
    }
    pub fn recv(t: *FakeTransport) Error!Msg {
        if (t.next == t.inbound.len) return error.RecvFailed;
        defer t.next += 1;
        return t.inbound[t.next];
    }
    pub fn closeHandle(t: *FakeTransport, h: usize) void {
        t.closed_handles[t.closed_len] = h;
        t.closed_len += 1;
    }
};

fn tagged(tag: proto.Tag, words: [4]u64) Msg {
    return .{ .tag = @intFromEnum(tag), .words = words };
}

const commit_req = (proto.NodeOnly{ .node = .{ .index = 0, .gen = 0 } }).encode();

test "events arriving before a reply are kept, not taken as the reply" {
    const script = [_]Msg{
        tagged(.key_event, (proto.KeyEvent{ .code = 30, .pressed = true }).encode()),
        tagged(.configure, (proto.Configure{ .w = 300, .h = 200 }).encode()),
        tagged(.close_request, .{ 0, 0, 0, 0 }),
        tagged(.ok, .{ 0, 0, 0, 0 }),
    };
    var c = Client(FakeTransport).init(.{ .inbound = &script });
    try testing.expectEqual(Reply.ok, try c.call(.commit, commit_req, null));
    try testing.expectEqual(@as(u64, @intFromEnum(proto.Tag.commit)), c.transport.sent[0].tag);
    // Every push survived the call; close outranks the rest.
    try testing.expect(c.closed);
    try testing.expectEqual(Event.close, try c.nextEvent());
    try testing.expectEqual(Event.close, try c.nextEvent()); // sticky: the window is gone
    try testing.expectEqual(@as(usize, 1), c.key_len);
    try testing.expectEqual(@as(u32, 300), c.configure_pending.?.w);
}

test "configure coalesces to the newest size and outranks queued keys" {
    const script = [_]Msg{
        tagged(.key_event, (proto.KeyEvent{ .code = 31, .pressed = true }).encode()),
        tagged(.configure, (proto.Configure{ .w = 100, .h = 100 }).encode()),
        tagged(.configure, (proto.Configure{ .w = 0, .h = 50 }).encode()), // degenerate: ignored
        tagged(.configure, (proto.Configure{ .w = 640, .h = 480 }).encode()),
        tagged(.err, (proto.Err{ .reason = .bad_geometry }).encode()),
    };
    var c = Client(FakeTransport).init(.{ .inbound = &script });
    try testing.expectEqual(Reply{ .err = .bad_geometry }, try c.call(.attach_surface, .{ 0, 0, 0, 0 }, null));
    const ev = try c.nextEvent();
    try testing.expectEqual(@as(u32, 640), ev.configure.w);
    try testing.expectEqual(@as(u32, 480), ev.configure.h);
    try testing.expectEqual(@as(u32, 31), (try c.nextEvent()).key.code);
    try testing.expectEqual(@as(u64, 1), c.ignored);
}

test "unknown and high-bit tags are ignored, never read as a known message" {
    const key_tag: u64 = @intFromEnum(proto.Tag.key_event);
    const script = [_]Msg{
        .{ .tag = 0x99, .words = .{ 30, 1, 0, 0 } }, // a tag this client does not know
        .{ .tag = (1 << 32) | key_tag, .words = .{ 30, 1, 0, 0 } }, // truncation would alias key_event
        .{ .tag = 0xDEAD_BEEF, .cap = 7 }, // and its carried cap must not leak
        .{ .tag = @intFromEnum(proto.Tag.create_node) }, // a request, server-bound only
        tagged(.key_event, (proto.KeyEvent{ .code = 44, .pressed = false }).encode()),
    };
    var c = Client(FakeTransport).init(.{ .inbound = &script });
    const ev = try c.nextEvent();
    try testing.expectEqual(@as(u32, 44), ev.key.code); // the ONLY real key in the script
    try testing.expect(!ev.key.pressed);
    try testing.expectEqual(@as(u64, 4), c.ignored);
    try testing.expectEqual(@as(usize, 1), c.transport.closed_len);
    try testing.expectEqual(@as(usize, 7), c.transport.closed_handles[0]);
}

test "a failed receive is an error from call and from nextEvent" {
    var c = Client(FakeTransport).init(.{ .inbound = &.{} });
    try testing.expectError(error.RecvFailed, c.call(.commit, commit_req, null));
    try testing.expectError(error.RecvFailed, c.nextEvent());
}

test "the key ring keeps order, drops the newest on overflow, and counts it" {
    var script: [event_capacity + 4]Msg = undefined;
    for (&script, 0..) |*m, i| m.* = tagged(.key_event, (proto.KeyEvent{ .code = @intCast(i), .pressed = true }).encode());
    var with_reply: [script.len + 1]Msg = undefined;
    @memcpy(with_reply[0..script.len], &script);
    with_reply[script.len] = tagged(.ok, .{ 0, 0, 0, 0 });
    var c = Client(FakeTransport).init(.{ .inbound = &with_reply });
    _ = try c.call(.commit, commit_req, null);
    try testing.expectEqual(@as(u64, 4), c.dropped_events);
    for (0..event_capacity) |i| try testing.expectEqual(@as(u32, @intCast(i)), (try c.nextEvent()).key.code);
    try testing.expectError(error.RecvFailed, c.nextEvent()); // ring empty, script exhausted
}

test "a reply with no request outstanding is ignored by the event loop" {
    const script = [_]Msg{
        tagged(.ok, .{ 0, 0, 0, 0 }),
        tagged(.close_request, .{ 0, 0, 0, 0 }),
    };
    var c = Client(FakeTransport).init(.{ .inbound = &script });
    try testing.expectEqual(Event.close, try c.nextEvent());
    try testing.expectEqual(@as(u64, 1), c.ignored);
}

test "node_created and err replies decode" {
    const id = graph.NodeId{ .index = 5, .gen = 2 };
    const script = [_]Msg{
        tagged(.node_created, (proto.NodeCreated{ .node = id }).encode()),
        tagged(.err, (proto.Err{ .reason = .no_pool }).encode()),
    };
    var c = Client(FakeTransport).init(.{ .inbound = &script });
    const r = try c.call(.create_node, .{ 0, 0, 0, 0 }, null);
    try testing.expect(graph.NodeId.eql(id, r.node_created));
    try testing.expectEqual(Reply{ .err = .no_pool }, try c.call(.attach_surface, .{ 0, 0, 0, 0 }, null));
}
