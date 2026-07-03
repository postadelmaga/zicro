//! # zicro.ipc — cross-process & in-process transports
//!
//! zicro ships the in-process [`LocalBus`](bus.LocalBus) broker in `bus.zig`; this file
//! adds the transports an app needs to host a module *out of process* — an in-process
//! channel pair, a stdio codec (JSON lines or length-prefixed postcard), and the wrapper
//! a supervisor uses to read a spawned child's stdout. Module code written against
//! `ModuleCtx` is unaffected by which transport hosts it — "write once, host anywhere".
//!
//! The wire formats are **byte-compatible with Micro's `ipc` feature**, so a zicro
//! supervisor can host a Rust Micro sidecar and vice versa:
//! * **JSON lines** — one `{"from":…,"channel":…,"payload":…}` object per line;
//! * **postcard** — a big-endian `u32` length prefix, then the postcard encoding of
//!   `{ from, channel, payload_json }` (three LEB128-length-prefixed UTF-8 strings —
//!   reimplemented here, no Rust dependency).
//!
//! Port note (Rust → Zig): Rust returns `Box<dyn Sender>` / `Box<dyn Receiver>` trait
//! objects; here each transport is a concrete type with the same `send` / `recv` /
//! `tryRecv` / `recvTimeout` shape — comptime duck typing plays the trait's role.

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

// --- in-process transport (thread channel, zero wire encoding) --------------------

/// In-process pair: the default path when the "remote" end is just another thread.
/// Envelopes are copied once into the queue, no wire encoding. Both halves must be
/// `deinit`ed.
pub fn channelPair(gpa: Allocator, io: Io) Allocator.Error!struct { PairSender, PairReceiver } {
    const inner = try gpa.create(PairInner);
    inner.* = .{ .gpa = gpa, .io = io };
    return .{ .{ .inner = inner }, .{ .inner = inner } };
}

const PairInner = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    changed: sync.Signal = .{},
    queue: std.ArrayListUnmanaged(OwnedEnvelope) = .empty,
    head: usize = 0,
    sender_alive: bool = true,
    receiver_alive: bool = true,
    refs: std.atomic.Value(usize) = .init(2),

    fn popLocked(inner: *PairInner) ?OwnedEnvelope {
        if (inner.head == inner.queue.items.len) return null;
        const env = inner.queue.items[inner.head];
        inner.head += 1;
        if (inner.head == inner.queue.items.len) {
            inner.queue.clearRetainingCapacity();
            inner.head = 0;
        }
        return env;
    }

    fn release(inner: *PairInner) void {
        if (inner.refs.fetchSub(1, .acq_rel) == 1) {
            while (inner.popLocked()) |env| env.deinit();
            inner.queue.deinit(inner.gpa);
            inner.gpa.destroy(inner);
        }
    }
};

/// The producing half of a [`channelPair`].
pub const PairSender = struct {
    inner: *PairInner,

    /// Queue a copy of `env`. `error.Disconnected` once the receiver is gone.
    pub fn send(self: PairSender, env: *const Envelope) !void {
        const inner = self.inner;
        const owned: OwnedEnvelope = .{ .gpa = inner.gpa, .env = .{
            .from = try inner.gpa.dupe(u8, env.from),
            .channel = try inner.gpa.dupe(u8, env.channel),
            .payload = try inner.gpa.dupe(u8, env.payload),
        } };
        errdefer owned.deinit();
        sync.lock(&inner.mutex, inner.io);
        defer sync.unlock(&inner.mutex, inner.io);
        if (!inner.receiver_alive) return error.Disconnected;
        try inner.queue.append(inner.gpa, owned);
        inner.changed.notifyAll(inner.io);
    }

    pub fn deinit(self: PairSender) void {
        const inner = self.inner;
        sync.lock(&inner.mutex, inner.io);
        inner.sender_alive = false;
        inner.changed.notifyAll(inner.io);
        sync.unlock(&inner.mutex, inner.io);
        inner.release();
    }
};

/// The consuming half of a [`channelPair`].
pub const PairReceiver = struct {
    inner: *PairInner,

    /// Block until the next envelope; `error.Disconnected` once the sender is gone and
    /// the queue is drained.
    pub fn recv(self: PairReceiver) error{Disconnected}!OwnedEnvelope {
        const inner = self.inner;
        while (true) {
            sync.lock(&inner.mutex, inner.io);
            if (inner.popLocked()) |env| {
                sync.unlock(&inner.mutex, inner.io);
                return env;
            }
            if (!inner.sender_alive) {
                sync.unlock(&inner.mutex, inner.io);
                return error.Disconnected;
            }
            const snapshot = inner.changed.prepare();
            sync.unlock(&inner.mutex, inner.io);
            inner.changed.wait(inner.io, snapshot);
        }
    }

    /// Non-blocking poll: `null` when nothing is queued.
    pub fn tryRecv(self: PairReceiver) error{Disconnected}!?OwnedEnvelope {
        const inner = self.inner;
        sync.lock(&inner.mutex, inner.io);
        defer sync.unlock(&inner.mutex, inner.io);
        if (inner.popLocked()) |env| return env;
        if (!inner.sender_alive) return error.Disconnected;
        return null;
    }

    /// Block for at most `timeout_ns`; `null` on timeout.
    pub fn recvTimeout(self: PairReceiver, timeout_ns: u64) error{Disconnected}!?OwnedEnvelope {
        const inner = self.inner;
        const deadline = sync.deadlineAfterNs(inner.io, timeout_ns);
        while (true) {
            sync.lock(&inner.mutex, inner.io);
            if (inner.popLocked()) |env| {
                sync.unlock(&inner.mutex, inner.io);
                return env;
            }
            if (!inner.sender_alive) {
                sync.unlock(&inner.mutex, inner.io);
                return error.Disconnected;
            }
            const snapshot = inner.changed.prepare();
            sync.unlock(&inner.mutex, inner.io);
            if (sync.expired(inner.io, deadline)) return null;
            inner.changed.waitTimeout(inner.io, snapshot, .{ .deadline = deadline });
        }
    }

    pub fn deinit(self: PairReceiver) void {
        const inner = self.inner;
        sync.lock(&inner.mutex, inner.io);
        inner.receiver_alive = false;
        inner.changed.notifyAll(inner.io);
        sync.unlock(&inner.mutex, inner.io);
        inner.release();
    }
};

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
/// drive `recv` on a dedicated thread: `tryRecv` never blocks but only ever reports
/// what a `recv` loop has not yet claimed (i.e. nothing), and `recvTimeout` is
/// best-effort — it simply blocks on the next frame.
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

    /// Never blocks; a stdio stream cannot be polled portably, so this reports nothing
    /// (drive the stream with a `recv` thread instead).
    pub fn tryRecv(self: *ProcessReceiver) !?OwnedEnvelope {
        _ = self;
        return null;
    }

    /// Best-effort: blocks on the next frame regardless of `timeout_ns` (see type docs).
    pub fn recvTimeout(self: *ProcessReceiver, timeout_ns: u64) !?OwnedEnvelope {
        _ = timeout_ns;
        return try self.recv();
    }
};

/// Build a [`ProcessReceiver`] over an arbitrary reader — the parent's **return path**:
/// wrap a spawned child's piped stdout so envelopes the sidecar emits flow back in, one
/// per `recv()`. Same wire format as the sidecar's own stdio pair.
pub fn receiverFromReader(gpa: Allocator, io: Io, reader: *Io.Reader, format: IpcFormat) ProcessReceiver {
    return ProcessReceiver.init(gpa, io, reader, format);
}

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
    const long = "[" ++ "1," ** 100 ++ "1]";
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

test "channel pair delivers in order and reports disconnect" {
    const gpa = testing.allocator;
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const tx, const rx = try channelPair(gpa, io);
    defer rx.deinit();

    try tx.send(&.{ .from = "a", .channel = "x", .payload = "1" });
    try tx.send(&.{ .from = "a", .channel = "x", .payload = "2" });
    tx.deinit();

    const first = (try rx.tryRecv()).?;
    defer first.deinit();
    try testing.expectEqualStrings("1", first.env.payload);
    const second = try rx.recv();
    defer second.deinit();
    try testing.expectEqualStrings("2", second.env.payload);
    // Sender gone and queue drained → disconnected, like the Rust mpsc pair.
    try testing.expectError(error.Disconnected, rx.recv());
    try testing.expectError(error.Disconnected, rx.tryRecv());
}
