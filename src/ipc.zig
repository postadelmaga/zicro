//! # zicro.ipc — cross-process & in-process transports
//!
//! zicro ships the in-process [`LocalBus`](bus.LocalBus) broker in `bus.zig`; this file
//! adds the transport an app needs to host a module *out of process*: a stdio codec
//! (JSON lines or length-prefixed postcard) with a sender/receiver pair a supervisor
//! uses to talk to a spawned child. Module code written against `ModuleCtx` is
//! unaffected by which transport hosts it — "write once, host anywhere".
//!
//! The wire formats are **byte-compatible with Micro's `ipc` feature**, so a zicro
//! supervisor can host a Rust Micro sidecar and vice versa:
//! * **JSON lines** — one `{"from":…,"channel":…,"payload":…}` object per line;
//! * **postcard** — a big-endian `u32` length prefix, then the postcard encoding of
//!   `{ from, channel, payload_json }` (three LEB128-length-prefixed UTF-8 strings —
//!   reimplemented here, no Rust dependency).
//!
//! Port note (Rust → Zig): Rust returns `Box<dyn Sender>` / `Box<dyn Receiver>` trait
//! objects; here the transport is a concrete type with the same `send` / `recv` shape —
//! comptime duck typing plays the trait's role.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sync = @import("sync.zig");
const protocol = @import("protocol.zig");

pub const Envelope = protocol.Envelope;
pub const OwnedEnvelope = protocol.OwnedEnvelope;

// --- IPC format selection & sanity limits -----------------------------------------------

pub const IpcFormat = enum { json, postcard };

/// Maximum message size (bytes) for untrusted wire input; prevents allocation DoS.
pub const max_message_size: usize = 16 * 1024 * 1024; // 16 MiB default

/// The env var both ends read (`MICRO_IPC_FORMAT=postcard`); JSON lines by default. A
/// child inherits the supervisor's environment, so setting it once on the parent
/// configures the whole link. Zig 0.16 has no ambient `getenv` (the environment flows
/// through `std.process.Environ`), so fetch the variable yourself and parse it with
/// [`ipcFormatFromEnv`].
pub const ipc_format_env = "MICRO_IPC_FORMAT";

/// Parse the value of [`ipc_format_env`] (pass `null` when unset).
pub fn ipcFormatFromEnv(value: ?[]const u8) IpcFormat {
    const v = value orelse return .json;
    const trimmed = std.mem.trim(u8, v, " \t");
    if (std.ascii.eqlIgnoreCase(trimmed, "postcard")) return .postcard;
    return .json;
}

// --- postcard envelope codec -----------------------------------------------------
//
// postcard encodes a `String` as an unsigned-LEB128 length followed by the UTF-8 bytes,
// and a struct as its fields in order. `PostcardEnvelope { from, channel, payload_json }`
// is therefore three length-prefixed strings back to back.

fn writeVarint(w: *Io.Writer, value: usize) Io.Writer.Error!void {
    var rest = value;
    while (rest >= 0x80) {
        try w.writeByte(@intCast((rest & 0x7f) | 0x80));
        rest >>= 7;
    }
    try w.writeByte(@intCast(rest));
}

fn readVarint(r: *Io.Reader) !usize {
    var value: usize = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = try r.takeByte();
        value |= @as(usize, byte & 0x7f) << shift;
        if (byte & 0x80 == 0) return value;
        if (shift >= 56) return error.VarintTooLong;
        shift += 7;
    }
}

fn writeString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try writeVarint(w, s.len);
    try w.writeAll(s);
}

fn readStringAlloc(gpa: Allocator, r: *Io.Reader) ![]u8 {
    const len = try readVarint(r);
    const out = try gpa.alloc(u8, len);
    errdefer gpa.free(out);
    try r.readSliceAll(out);
    return out;
}

/// Encode an envelope as postcard bytes (caller frees) — wire-compatible with Micro's
/// `serialize_envelope_postcard`.
pub fn serializeEnvelopePostcard(gpa: Allocator, env: *const Envelope) ![]u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeString(&out.writer, env.from);
    try writeString(&out.writer, env.channel);
    try writeString(&out.writer, env.payload); // payload is already compact JSON text
    return out.toOwnedSlice();
}

/// Decode postcard bytes back into an owned envelope.
pub fn deserializeEnvelopePostcard(gpa: Allocator, bytes: []const u8) !OwnedEnvelope {
    var r: Io.Reader = .fixed(bytes);
    const from = try readStringAlloc(gpa, &r);
    errdefer gpa.free(from);
    const channel = try readStringAlloc(gpa, &r);
    errdefer gpa.free(channel);
    const payload = try readStringAlloc(gpa, &r);
    return .{ .gpa = gpa, .env = .{ .from = from, .channel = channel, .payload = payload } };
}

// --- cross-process transport (stdio JSON-lines or postcard-binary) -----------------

/// Writes envelopes as JSON lines or binary postcard packets to a stream. A supervisor
/// wraps a spawned child's stdin with one; a sidecar wraps its own stdout. Thread-safe
/// (sends are serialized under a lock, like the Rust `Arc<Mutex<dyn Write>>`).
pub const ProcessSender = struct {
    io: Io,
    gpa: Allocator,
    mutex: Io.Mutex = .init,
    writer: *Io.Writer,
    format: IpcFormat,

    /// Wrap `writer` (which must outlive the sender). `format` usually comes from
    /// [`ipcFormatFromEnv`].
    pub fn init(gpa: Allocator, io: Io, writer: *Io.Writer, format: IpcFormat) ProcessSender {
        return .{ .gpa = gpa, .io = io, .writer = writer, .format = format };
    }

    pub fn send(self: *ProcessSender, env: *const Envelope) !void {
        sync.lock(&self.mutex, self.io);
        defer sync.unlock(&self.mutex, self.io);
        switch (self.format) {
            .json => {
                try protocol.writeEnvelopeJson(self.gpa, self.writer, env);
                try self.writer.writeByte('\n');
            },
            .postcard => {
                const bytes = try serializeEnvelopePostcard(self.gpa, env);
                defer self.gpa.free(bytes);
                try self.writer.writeInt(u32, @intCast(bytes.len), .big);
                try self.writer.writeAll(bytes);
            },
        }
        try self.writer.flush();
    }
};

/// Reads envelopes from a stream — the other end of a [`ProcessSender`]. A supervisor
/// wraps a child's piped stdout (the return path); a sidecar wraps its own stdin.
///
/// A piped reader has no portable timed read, so (as in the Rust original) consumers
/// drive the blocking `recv` on a dedicated thread.
pub const ProcessReceiver = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    reader: *Io.Reader,
    format: IpcFormat,

    /// Wrap `reader` (which must outlive the receiver). JSON lines are bounded by the
    /// reader's buffer size — size it for the largest expected envelope.
    pub fn init(gpa: Allocator, io: Io, reader: *Io.Reader, format: IpcFormat) ProcessReceiver {
        return .{ .gpa = gpa, .io = io, .reader = reader, .format = format };
    }

    /// Block until the next envelope. `error.EndOfStream` when the peer closes.
    pub fn recv(self: *ProcessReceiver) !OwnedEnvelope {
        sync.lock(&self.mutex, self.io);
        defer sync.unlock(&self.mutex, self.io);
        switch (self.format) {
            .json => {
                const line = (try self.reader.takeDelimiter('\n')) orelse return error.EndOfStream;
                return try protocol.parseEnvelopeJson(self.gpa, line);
            },
            .postcard => {
                const len = try self.reader.takeInt(u32, .big);
                if (len > max_message_size) return error.MessageTooLarge;
                const buf = try self.gpa.alloc(u8, len);
                defer self.gpa.free(buf);
                try self.reader.readSliceAll(buf);
                return try deserializeEnvelopePostcard(self.gpa, buf);
            },
        }
    }
};

// --- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "ipc format parsing mirrors the Rust env contract" {
    try testing.expectEqual(IpcFormat.json, ipcFormatFromEnv(null));
    try testing.expectEqual(IpcFormat.json, ipcFormatFromEnv("garbage"));
    try testing.expectEqual(IpcFormat.postcard, ipcFormatFromEnv("postcard"));
    try testing.expectEqual(IpcFormat.postcard, ipcFormatFromEnv(" POSTCARD "));
}

test "postcard codec round-trips and matches the Micro wire format" {
    const gpa = testing.allocator;
    const env: Envelope = .{ .from = "a", .channel = "x", .payload = "{\"n\":5}" };

    const bytes = try serializeEnvelopePostcard(gpa, &env);
    defer gpa.free(bytes);
    // postcard: three LEB128-length-prefixed strings — locked so interop can't drift.
    try testing.expectEqualSlices(u8, "\x01a\x01x\x07{\"n\":5}", bytes);

    const back = try deserializeEnvelopePostcard(gpa, bytes);
    defer back.deinit();
    try testing.expectEqualStrings("a", back.env.from);
    try testing.expectEqualStrings("x", back.env.channel);
    try testing.expectEqualStrings("{\"n\":5}", back.env.payload);
}

test "varint survives multi-byte lengths" {
    const gpa = testing.allocator;
    // A payload longer than 127 bytes forces a two-byte LEB128 length.
    // `**` left the language in 0.17 and `@splat` cannot build a pattern, so the
    // 100 "1," pairs are laid down at comptime: "[" + 200 bytes + "1]" = 203.
    const long_buf = comptime blk: {
        var buf: [203]u8 = undefined;
        buf[0] = '[';
        for (0..100) |i| buf[1 + i * 2 ..][0..2].* = "1,".*;
        buf[201..][0..2].* = "1]".*;
        break :blk buf;
    };
    const long: []const u8 = &long_buf;
    const env: Envelope = .{ .from = "sidecar", .channel = "scene", .payload = long };
    const bytes = try serializeEnvelopePostcard(gpa, &env);
    defer gpa.free(bytes);
    const back = try deserializeEnvelopePostcard(gpa, bytes);
    defer back.deinit();
    try testing.expectEqualStrings(long, back.env.payload);
}

test "receiver over a reader round-trips json lines" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Two envelopes as JSON lines, exactly as a child's stdout would emit them.
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const env: Envelope = .{ .from = "sidecar", .channel = "scene", .payload = "{\"hello\":\"world\"}" };
    var sender = ProcessSender.init(gpa, io, &out.writer, .json);
    try sender.send(&env);
    try sender.send(&env);

    var in: Io.Reader = .fixed(out.writer.buffered());
    var rx = ProcessReceiver.init(gpa, io, &in, .json);

    const got = try rx.recv();
    defer got.deinit();
    try testing.expectEqualStrings("sidecar", got.env.from);
    try testing.expectEqualStrings("scene", got.env.channel);
    try testing.expectEqualStrings("{\"hello\":\"world\"}", got.env.payload);

    // Second line still decodes; then EOF surfaces as an error.
    const second = try rx.recv();
    second.deinit();
    try testing.expectError(error.EndOfStream, rx.recv());
}

test "process pair round-trips postcard packets" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const env: Envelope = .{ .from = "child", .channel = "state", .payload = "[1,2,3]" };
    var sender = ProcessSender.init(gpa, io, &out.writer, .postcard);
    try sender.send(&env);

    var in: Io.Reader = .fixed(out.writer.buffered());
    var rx = ProcessReceiver.init(gpa, io, &in, .postcard);
    const got = try rx.recv();
    defer got.deinit();
    try testing.expectEqualStrings("[1,2,3]", got.env.payload);
    try testing.expectError(error.EndOfStream, rx.recv());
}
