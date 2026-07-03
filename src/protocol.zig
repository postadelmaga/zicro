//! # zicro.protocol — the wire types every module shares
//!
//! Zero logic, just the data a message needs to be routed: who sent it (a module id), the
//! named channel it rides, and the [`Envelope`] that carries the payload. Routing is **by
//! channel** — a module subscribes to a channel and never inspects another module's
//! internals.
//!
//! Like the parent *Micro* project, channels are **free-form strings**: zicro is the
//! generic core, so an app declares whatever channels it needs (`"tick"`, `"count"`,
//! `"control"`, …) without editing this file.
//!
//! Port note (Rust → Zig): `serde_json::Value` payloads become **JSON text** (`[]const u8`).
//! Producers encode a typed value with `std.json`; consumers decode the text into the type
//! they expect. Same contract — a wrong shape is a decode error, not a silent `null`.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Identifies a module (a message's sender) on the bus.
pub const ModuleId = []const u8;

/// A named channel modules publish to / receive from. Free-form so adding a "topic" is
/// just using a new name — no transport code changes.
pub const Channel = []const u8;

/// How a channel behaves for a *fresh* subscriber. The bus uses this to decide whether a
/// channel's last message may be **replayed** to a new subscriber: replaying durable state
/// re-syncs the joiner; replaying a transient event would spuriously re-fire it.
pub const ChannelKind = enum {
    /// The latest value *is* the truth; replaying it re-syncs a fresh module (e.g. a count).
    state,
    /// One-shot occurrences; replaying repeats them wrongly (e.g. a tick, a shutdown).
    event,
};

/// An addressed message on the bus: who sent it, on which channel, and the payload (JSON
/// text). The channel tells the receiver how to interpret `payload`.
///
/// An `Envelope` is a *view*: it does not own its strings. The bus hands out reference-
/// counted envelopes (`bus.Msg`); [`encodePayload`]/[`decodePayload`] work on any view.
pub const Envelope = struct {
    from: ModuleId,
    channel: Channel,
    payload: []const u8,

    /// Decode the payload into a typed message `T`. The receiver names the type it expects
    /// instead of indexing into dynamic JSON. Call `deinit` on the result when done.
    pub fn decode(env: *const Envelope, comptime T: type, gpa: Allocator) !std.json.Parsed(T) {
        return std.json.parseFromSlice(T, gpa, env.payload, .{ .allocate = .alloc_always });
    }
};

/// Serialize a **typed** message into a JSON payload (caller owns the returned text). This
/// is the typed seam over the generic bus: producers send a real Zig type instead of
/// hand-built JSON, so a field rename is a compile error, not a silent `null`.
pub fn encodePayload(gpa: Allocator, msg: anytype) Allocator.Error![]u8 {
    return std.json.Stringify.valueAlloc(gpa, msg, .{});
}

/// An envelope that owns its strings — what the wire codecs (bridge, ipc) hand back.
pub const OwnedEnvelope = struct {
    gpa: Allocator,
    env: Envelope,

    pub fn deinit(self: *const OwnedEnvelope) void {
        self.gpa.free(self.env.from);
        self.gpa.free(self.env.channel);
        self.gpa.free(self.env.payload);
    }
};

/// Write an envelope as one JSON object — the wire shape shared by every zicro/Micro
/// codec: `{"from":…,"channel":…,"payload":<compact JSON>}`, from/channel JSON-escaped.
/// Payload is re-stringified in compact form to prevent injection of newlines/whitespace.
pub const WriteEnvelopeJsonError = error{ MalformedPayload } || std.Io.Writer.Error;

pub fn writeEnvelopeJson(gpa: Allocator, w: *std.Io.Writer, env: *const Envelope) WriteEnvelopeJsonError!void {
    // Re-parse and re-stringify payload to ensure it's valid compact JSON (no newlines/whitespace).
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, env.payload, .{}) catch return error.MalformedPayload;
    defer parsed.deinit();
    const compact = std.json.Stringify.valueAlloc(gpa, parsed.value, .{}) catch return error.MalformedPayload;
    defer gpa.free(compact);

    try w.print("{{\"from\":{f},\"channel\":{f},\"payload\":{s}}}", .{
        std.json.fmt(env.from, .{}),
        std.json.fmt(env.channel, .{}),
        compact,
    });
}

/// Parse the JSON object written by [`writeEnvelopeJson`] back into an owned envelope.
pub fn parseEnvelopeJson(gpa: Allocator, bytes: []const u8) !OwnedEnvelope {
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.MalformedEnvelope;
    const obj = parsed.value.object;
    const from_v = obj.get("from") orelse return error.MalformedEnvelope;
    const channel_v = obj.get("channel") orelse return error.MalformedEnvelope;
    const payload_v = obj.get("payload") orelse return error.MalformedEnvelope;
    if (from_v != .string or channel_v != .string) return error.MalformedEnvelope;

    const from = try gpa.dupe(u8, from_v.string);
    errdefer gpa.free(from);
    const channel = try gpa.dupe(u8, channel_v.string);
    errdefer gpa.free(channel);
    const payload = try std.json.Stringify.valueAlloc(gpa, payload_v, .{});
    return .{ .gpa = gpa, .env = .{ .from = from, .channel = channel, .payload = payload } };
}

/// A **typed** view of a channel: a channel name bound, at the type level, to the payload
/// type `T` that rides on it. It carries no data of `T` (just a name), so it is trivially
/// copyable, and it makes the bus contract checkable by the compiler: [`Topic.encode`]
/// only accepts a `T`, [`Topic.decode`] only yields a `T`, so a producer and a consumer
/// that share a `Topic(T)` can never disagree on the shape.
///
/// The bus stays string-routed underneath — `Topic(T)` is a zero-cost ergonomic skin, not
/// a new transport.
pub fn Topic(comptime T: type) type {
    return struct {
        channel: Channel,

        /// The payload type this topic carries — lets generic code (`publishOn`) name it.
        pub const Payload = T;

        const Self = @This();

        /// Bind a channel name to the payload type `T`.
        pub fn init(channel: Channel) Self {
            return .{ .channel = channel };
        }

        /// Serialize a `T` for this topic's channel (caller owns the returned text).
        pub fn encode(self: Self, gpa: Allocator, msg: T) Allocator.Error![]u8 {
            _ = self;
            return encodePayload(gpa, msg);
        }

        /// Decode an envelope's payload as this topic's `T`. (The caller is expected to
        /// only pass envelopes from this topic's channel; the type is what the topic
        /// guarantees.)
        pub fn decode(self: Self, gpa: Allocator, env: *const Envelope) !std.json.Parsed(T) {
            _ = self;
            return env.decode(T, gpa);
        }
    };
}

test "payload round-trips a typed message" {
    const gpa = std.testing.allocator;
    const Tick = struct { amount: i64 };

    const payload = try encodePayload(gpa, Tick{ .amount = 3 });
    defer gpa.free(payload);

    const env: Envelope = .{ .from = "ticker", .channel = "tick", .payload = payload };
    const back = try env.decode(Tick, gpa);
    defer back.deinit();
    try std.testing.expectEqual(@as(i64, 3), back.value.amount);

    // Wrong shape surfaces as an error, not a silent default.
    const Other = struct { name: []const u8 };
    if (env.decode(Other, gpa)) |parsed| {
        parsed.deinit();
        return error.TestExpectedDecodeFailure;
    } else |_| {}
}

test "topic round-trips and targets its channel" {
    const gpa = std.testing.allocator;
    const Tick = struct { n: i64 };
    const tick: Topic(Tick) = .init("tick");

    const payload = try tick.encode(gpa, .{ .n = 7 });
    defer gpa.free(payload);
    try std.testing.expectEqualStrings("tick", tick.channel);

    const env: Envelope = .{ .from = "clock", .channel = tick.channel, .payload = payload };
    const back = try tick.decode(gpa, &env);
    defer back.deinit();
    try std.testing.expectEqual(@as(i64, 7), back.value.n);
}
