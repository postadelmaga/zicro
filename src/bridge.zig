//! # zicro.bridge — a bus over a byte stream
//!
//! A [`LocalBus`] routes in-process at channel granularity. Because modules are written
//! against the bus, the *same* module can have peers in another process — you just need
//! a transport that carries envelopes across the boundary and republishes them. This
//! file is that transport: it (de)serializes envelopes as length-prefixed frames over
//! any `std.Io.Reader`/`std.Io.Writer` stream (a TCP stream, a pipe, a Unix socket), so
//! a bus on one side and a bus on the other behave like one.
//!
//! Two halves, deliberately one-directional so there is no echo to break:
//! * [`Bridge.egress`] subscribes to a set of channels on the local bus and writes every
//!   envelope to the stream — the *outbound* side.
//! * [`Bridge.ingress`] reads envelopes from the stream and republishes them on the
//!   local bus — the *inbound* side.
//!
//! A full duplex link is just two bridges with the channel sets chosen so a channel is
//! never forwarded both ways (which would loop). The framing helpers
//! [`writeRawFrame`]/[`readRawFrame`] are public for anyone building a different topology.
//!
//! ## Wire layout (identical to the Rust `micro-bridge`)
//! `total_len: u32le` (excluding itself) · `kind: u8` · `channel_len: u16le` · `channel`
//! · `data`. A `kind` of `json` carries a whole envelope as JSON in `data`; `raw` carries
//! opaque bytes for out-of-band uses.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sync = @import("sync.zig");
const protocol = @import("protocol.zig");
const bus_mod = @import("bus.zig");

pub const LocalBus = bus_mod.LocalBus;
pub const Envelope = protocol.Envelope;

/// How often an egress loop wakes to check for shutdown while idle.
const poll_ns: u64 = 100 * std.time.ns_per_ms;

/// Maximum frame size (bytes) for untrusted wire input; prevents allocation DoS.
pub const max_frame_size: usize = 16 * 1024 * 1024; // 16 MiB default

pub const FrameKind = enum(u8) {
    raw = 0,
    json = 1,

    pub fn fromByte(value: u8) error{UnknownFrameKind}!FrameKind {
        return switch (value) {
            0 => .raw,
            1 => .json,
            else => error.UnknownFrameKind,
        };
    }
};

/// One frame on the wire: a channel name, a kind tag, and opaque bytes.
pub const RawFrame = struct {
    channel: []const u8,
    kind: FrameKind,
    data: []const u8,

    /// Free a frame produced by [`readRawFrame`].
    pub fn deinit(frame: *const RawFrame, gpa: Allocator) void {
        gpa.free(frame.channel);
        gpa.free(frame.data);
    }
};

/// Write a raw frame to `w` using the binary layout above.
pub fn writeRawFrame(w: *Io.Writer, frame: RawFrame) !void {
    if (frame.channel.len > std.math.maxInt(u16)) return error.ChannelNameTooLong;
    // total_len excludes total_len itself: kind (1) + channel_len (2) + channel + data.
    const total_len = 1 + 2 + frame.channel.len + frame.data.len;
    if (total_len > std.math.maxInt(u32)) return error.FrameTooLarge;
    try w.writeInt(u32, @intCast(total_len), .little);
    try w.writeInt(u8, @intFromEnum(frame.kind), .little);
    try w.writeInt(u16, @intCast(frame.channel.len), .little);
    try w.writeAll(frame.channel);
    try w.writeAll(frame.data);
    try w.flush();
}

/// Read a raw frame from `r`. Returns `null` on clean EOF, an error on I/O trouble or a
/// malformed frame. The caller owns the result (`frame.deinit(gpa)`).
pub fn readRawFrame(gpa: Allocator, r: *Io.Reader) !?RawFrame {
    const total_len = r.takeInt(u32, .little) catch |e| switch (e) {
        error.EndOfStream => return null, // clean EOF between frames
        else => return e,
    };
    if (total_len < 3) return error.FrameTooSmall;
    if (total_len > max_frame_size) return error.FrameTooLarge;

    const kind = try FrameKind.fromByte(try r.takeByte());
    const channel_len = try r.takeInt(u16, .little);
    if (3 + @as(usize, channel_len) > total_len) return error.InvalidChannelLength;
    const data_len = total_len - 3 - channel_len;

    const channel = try gpa.alloc(u8, channel_len);
    errdefer gpa.free(channel);
    try r.readSliceAll(channel);
    if (!std.unicode.utf8ValidateSlice(channel)) return error.InvalidChannelName;

    const data = try gpa.alloc(u8, data_len);
    errdefer gpa.free(data);
    try r.readSliceAll(data);

    return .{ .channel = channel, .kind = kind, .data = data };
}

/// Write one envelope to `w` by serializing it as a JSON payload inside a `RawFrame`.
pub fn writeFrame(gpa: Allocator, w: *Io.Writer, env: *const Envelope) !void {
    var data: std.Io.Writer.Allocating = .init(gpa);
    defer data.deinit();
    try protocol.writeEnvelopeJson(gpa, &data.writer, env);
    try writeRawFrame(w, .{ .channel = env.channel, .kind = .json, .data = data.writer.buffered() });
}

/// A decoded envelope from [`readFrame`] — owns its strings.
pub const OwnedEnvelope = protocol.OwnedEnvelope;

/// Read one framed envelope from `r` by parsing the raw frame and decoding its JSON.
/// Returns `null` on clean EOF.
pub fn readFrame(gpa: Allocator, r: *Io.Reader) !?OwnedEnvelope {
    const frame = (try readRawFrame(gpa, r)) orelse return null;
    defer frame.deinit(gpa);
    if (frame.kind != .json) return error.ExpectedJsonFrame;
    return try protocol.parseEnvelopeJson(gpa, frame.data);
}

/// A running one-directional link between a bus and a stream. Stop it (and join its
/// thread) with [`Bridge.stop`].
pub const Bridge = struct {
    gpa: Allocator,
    stop_flag: *std.atomic.Value(bool),
    thread: std.Thread,

    /// **Outbound**: forward every envelope published on `channels` of `bus` to `writer`.
    /// The loop wakes every [`poll_ns`] to observe [`Bridge.stop`], so it shuts down
    /// promptly even when the channels are idle. `writer` must stay valid until `stop`.
    pub fn egress(gpa: Allocator, bus: *LocalBus, channels: []const []const u8, writer: *Io.Writer) !Bridge {
        const rx = try bus.subscribeMany(channels);
        const stop_flag = try gpa.create(std.atomic.Value(bool));
        errdefer gpa.destroy(stop_flag);
        stop_flag.* = .init(false);
        const thread = try std.Thread.spawn(.{}, egressLoop, .{ gpa, rx, writer, stop_flag });
        return .{ .gpa = gpa, .stop_flag = stop_flag, .thread = thread };
    }

    fn egressLoop(gpa: Allocator, rx_in: bus_mod.Receiver, writer: *Io.Writer, stop_flag: *std.atomic.Value(bool)) void {
        var rx = rx_in;
        defer rx.deinit();
        while (!stop_flag.load(.acquire)) {
            const maybe_msg = rx.recvTimeout(poll_ns) catch break; // local bus closed
            const msg = maybe_msg orelse continue; // idle tick: re-check stop
            defer msg.deinit();
            writeFrame(gpa, writer, msg.env()) catch break; // peer gone or stream broken
        }
    }

    /// **Inbound**: read envelopes from `reader` and republish them on `bus`. The read
    /// blocks until a frame arrives or the peer closes; close the underlying stream if
    /// you need [`Bridge.stop`] to interrupt a quiet link promptly rather than at the
    /// next frame.
    pub fn ingress(gpa: Allocator, bus: *LocalBus, reader: *Io.Reader) !Bridge {
        const stop_flag = try gpa.create(std.atomic.Value(bool));
        errdefer gpa.destroy(stop_flag);
        stop_flag.* = .init(false);
        const thread = try std.Thread.spawn(.{}, ingressLoop, .{ gpa, bus, reader, stop_flag });
        return .{ .gpa = gpa, .stop_flag = stop_flag, .thread = thread };
    }

    fn ingressLoop(gpa: Allocator, bus: *LocalBus, reader: *Io.Reader, stop_flag: *std.atomic.Value(bool)) void {
        while (!stop_flag.load(.acquire)) {
            const maybe_env = readFrame(gpa, reader) catch break;
            const owned = maybe_env orelse break; // peer closed cleanly
            defer owned.deinit();
            bus.publish(owned.env.from, owned.env.channel, owned.env.payload) catch {};
        }
    }

    /// Signal the bridge's thread to stop and wait for it.
    pub fn stop(bridge: Bridge) void {
        bridge.stop_flag.store(true, .release);
        bridge.thread.join();
        bridge.gpa.destroy(bridge.stop_flag);
    }
};

// --- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "frame round-trips through a buffer" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    const env: Envelope = .{ .from = "a", .channel = "x", .payload = "{\"n\":5}" };
    try writeFrame(gpa, &out.writer, &env);

    var in: std.Io.Reader = .fixed(out.writer.buffered());
    const back = (try readFrame(gpa, &in)).?;
    defer back.deinit();
    try testing.expectEqualStrings("a", back.env.from);
    try testing.expectEqualStrings("x", back.env.channel);
    try testing.expectEqualStrings("{\"n\":5}", back.env.payload);
    // A second read hits clean EOF.
    try testing.expectEqual(null, try readFrame(gpa, &in));
}

test "raw frame round-trips through a buffer" {
    const gpa = testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();

    try writeRawFrame(&out.writer, .{
        .channel = "raw-pty-output",
        .kind = .raw,
        .data = &.{ 0x01, 0x02, 0x03, 0xff, 0x00 },
    });

    var in: std.Io.Reader = .fixed(out.writer.buffered());
    const back = (try readRawFrame(gpa, &in)).?;
    defer back.deinit(gpa);
    try testing.expectEqualStrings("raw-pty-output", back.channel);
    try testing.expectEqual(FrameKind.raw, back.kind);
    try testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03, 0xff, 0x00 }, back.data);
    // A second read hits clean EOF.
    try testing.expectEqual(null, try readRawFrame(gpa, &in));
}

test "egress then ingress carries a bus across a byte stream" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Side A: publish on "x", egress captures it into a byte buffer.
    var bus_a = LocalBus.init(gpa, io);
    defer bus_a.deinit();
    var captured: std.Io.Writer.Allocating = .init(gpa);
    defer captured.deinit();
    {
        const out = Bridge.egress(gpa, &bus_a, &.{"x"}, &captured.writer) catch unreachable;
        try bus_a.publish("mod-a", "x", "{\"n\":7}");
        try bus_a.publish("mod-a", "x", "{\"n\":8}");
        sync.sleepNs(io, 50 * std.time.ns_per_ms); // let the egress thread drain
        out.stop();
    }

    // Side B: ingress replays the captured bytes onto a second bus.
    var bus_b = LocalBus.init(gpa, io);
    defer bus_b.deinit();
    var rx = try bus_b.subscribe("x");
    defer rx.deinit();
    {
        var in: std.Io.Reader = .fixed(captured.writer.buffered());
        const inb = Bridge.ingress(gpa, &bus_b, &in) catch unreachable;
        defer inb.stop(); // the reader EOFs, so the thread ends on its own
        const first = try rx.recv();
        defer first.deinit();
        try testing.expectEqualStrings("mod-a", first.env().from);
        try testing.expectEqualStrings("{\"n\":7}", first.env().payload);
        const second = try rx.recv();
        defer second.deinit();
        try testing.expectEqualStrings("{\"n\":8}", second.env().payload);
    }
}
