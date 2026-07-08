//! # zicro.bus internals — the subscriber inbox
//!
//! A bounded MPSC ring of shared envelopes ([`Inbox`]), the eventcount publishers block on
//! when a `.block` inbox fills ([`SpaceSignal`]), and the consumer handle ([`Receiver`]).
//! Split out of [`bus`](bus.zig): the queue mechanics (ring, backpressure hysteresis,
//! close/gone flags) are self-contained and stand apart from the broker's routing.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sync = @import("sync.zig");
const message = @import("message.zig");
const Shared = message.Shared;
const Msg = message.Msg;

pub const BusError = error{ Disconnected, OutOfMemory };

/// The bus-wide "an inbox freed space" eventcount. A publisher doing a `.block` fan-out
/// may be waiting on space in *several* inboxes at once, and a futex can only wait on one
/// address — so every pop that empties a slot of a *full* ring signals here instead, and
/// the publisher waits here. Reference-counted (bus + every inbox) because receivers can
/// outlive the bus and still pop. Thanks to the waiter-gated [`sync.Signal`], when no
/// publisher is blocked a notify is a single atomic add.
pub const SpaceSignal = struct {
    gpa: Allocator,
    refs: sync.RefCount,
    signal: sync.Signal = .{},

    pub fn create(gpa: Allocator) Allocator.Error!*SpaceSignal {
        const sp = try gpa.create(SpaceSignal);
        sp.* = .{ .gpa = gpa, .refs = .init(1) };
        return sp;
    }

    fn retain(sp: *SpaceSignal) *SpaceSignal {
        sp.refs.retain();
        return sp;
    }

    pub fn release(sp: *SpaceSignal) void {
        if (sp.refs.release()) sp.gpa.destroy(sp);
    }
};

/// A bounded MPSC ring of shared envelopes. Reference-counted because it is held by the
/// bus (once per subscribed channel) *and* by the receiver; either side may go first.
pub const Inbox = struct {
    gpa: Allocator,
    refs: sync.RefCount,
    mutex: Io.Mutex = .init,
    /// Bumped on every push/close — wakes blocked readers.
    changed: sync.Signal = .{},
    /// The bus-wide space signal — notified when a pop makes a full ring non-full (and on
    /// close/receiver-gone), waking publishers blocked in a `.block` fan-out.
    space: *SpaceSignal,
    items: []*Shared, // ring storage
    head: usize = 0,
    len: usize = 0,
    /// The bus is gone (deinit) — nothing more will ever arrive.
    closed: bool = false,
    /// The receiver is gone — pushes are pointless; publisher prunes on sight.
    receiver_gone: bool = false,

    pub fn create(gpa: Allocator, capacity: usize, initial_refs: usize, space: *SpaceSignal) Allocator.Error!*Inbox {
        const inbox = try gpa.create(Inbox);
        errdefer gpa.destroy(inbox);
        const items = try gpa.alloc(*Shared, @max(capacity, 1));
        inbox.* = .{ .gpa = gpa, .refs = .init(initial_refs), .items = items, .space = space.retain() };
        return inbox;
    }

    pub fn retain(inbox: *Inbox) *Inbox {
        inbox.refs.retain();
        return inbox;
    }

    pub fn release(inbox: *Inbox, io: Io) void {
        if (inbox.refs.release()) {
            // Last holder: drain whatever is still queued.
            sync.lock(&inbox.mutex, io);
            while (inbox.len > 0) {
                inbox.items[inbox.head].release();
                inbox.head = (inbox.head + 1) % inbox.items.len;
                inbox.len -= 1;
            }
            sync.unlock(&inbox.mutex, io);
            inbox.space.release();
            inbox.gpa.free(inbox.items);
            inbox.gpa.destroy(inbox);
        }
    }

    const PushResult = enum { ok, full, gone };

    /// Non-blocking push (both fan-outs). Takes ownership of one reference to `shared`
    /// only on `.ok`. `.gone` means the receiver (or bus) went away — skip, don't retry.
    pub fn tryPush(inbox: *Inbox, io: Io, shared: *Shared) PushResult {
        sync.lock(&inbox.mutex, io);
        defer sync.unlock(&inbox.mutex, io);
        if (inbox.receiver_gone or inbox.closed) return .gone;
        if (inbox.len == inbox.items.len) return .full;
        inbox.items[(inbox.head + inbox.len) % inbox.items.len] = shared.retain();
        inbox.len += 1;
        inbox.changed.notifyAll(io);
        return .ok;
    }

    fn popLocked(inbox: *Inbox, io: Io) ?*Shared {
        if (inbox.len == 0) return null;
        const shared = inbox.items[inbox.head];
        inbox.head = (inbox.head + 1) % inbox.items.len;
        inbox.len -= 1;
        // Publishers block only on a *full* ring — wake them at the half-drained mark
        // (hysteresis), so a blocked publisher refills in bursts of capacity/2 instead of
        // paying one futex round trip per slot. A draining receiver always crosses this
        // mark on its way to empty, so a blocked publisher can never be stranded.
        if (inbox.len == inbox.items.len / 2) inbox.space.signal.notifyAll(io);
        return shared;
    }

    /// Whether the receiver went away. The flag is written under the inbox mutex
    /// (`Receiver.deinit`), so it is read under the same mutex — the broker holds only
    /// its own lock when pruning, and a raw read there would race the writer.
    pub fn isReceiverGone(inbox: *Inbox, io: Io) bool {
        sync.lock(&inbox.mutex, io);
        defer sync.unlock(&inbox.mutex, io);
        return inbox.receiver_gone;
    }

    pub fn markClosed(inbox: *Inbox, io: Io) void {
        sync.lock(&inbox.mutex, io);
        inbox.closed = true;
        inbox.changed.notifyAll(io);
        inbox.space.signal.notifyAll(io); // a blocked publisher must see `closed`
        sync.unlock(&inbox.mutex, io);
    }
};

/// Receives envelopes from the bus — the merged inbox of one `subscribe*` call.
pub const Receiver = struct {
    inbox: *Inbox,
    io: Io,

    /// Block until the next envelope. `error.Disconnected` once the bus is gone and the
    /// inbox is drained.
    pub fn recv(r: *Receiver) BusError!Msg {
        while (true) {
            sync.lock(&r.inbox.mutex, r.io);
            if (r.inbox.popLocked(r.io)) |shared| {
                sync.unlock(&r.inbox.mutex, r.io);
                return .{ .shared = shared };
            }
            if (r.inbox.closed) {
                sync.unlock(&r.inbox.mutex, r.io);
                return error.Disconnected;
            }
            const snapshot = r.inbox.changed.prepare();
            sync.unlock(&r.inbox.mutex, r.io);
            r.inbox.changed.waitSpin(r.io, snapshot);
        }
    }

    /// Non-blocking poll: `null` when nothing is ready.
    pub fn tryRecv(r: *Receiver) BusError!?Msg {
        sync.lock(&r.inbox.mutex, r.io);
        defer sync.unlock(&r.inbox.mutex, r.io);
        if (r.inbox.popLocked(r.io)) |shared| return .{ .shared = shared };
        if (r.inbox.closed) return error.Disconnected;
        return null;
    }

    /// Block for at most `timeout_ns`. `null` on timeout — lets a module's loop wake
    /// periodically to check a shutdown flag without a busy spin.
    pub fn recvTimeout(r: *Receiver, timeout_ns: u64) BusError!?Msg {
        const deadline = sync.deadlineAfterNs(r.io, timeout_ns);
        while (true) {
            sync.lock(&r.inbox.mutex, r.io);
            if (r.inbox.popLocked(r.io)) |shared| {
                sync.unlock(&r.inbox.mutex, r.io);
                return .{ .shared = shared };
            }
            if (r.inbox.closed) {
                sync.unlock(&r.inbox.mutex, r.io);
                return error.Disconnected;
            }
            const snapshot = r.inbox.changed.prepare();
            sync.unlock(&r.inbox.mutex, r.io);
            if (sync.expired(r.io, deadline)) return null;
            r.inbox.changed.waitTimeout(r.io, snapshot, .{ .deadline = deadline });
        }
    }

    /// Unsubscribe: publishers stop delivering here and prune the inbox lazily.
    pub fn deinit(r: *Receiver) void {
        sync.lock(&r.inbox.mutex, r.io);
        r.inbox.receiver_gone = true;
        // Drain now so retained references don't linger until the bus prunes us.
        while (r.inbox.popLocked(r.io)) |shared| shared.release();
        r.inbox.changed.notifyAll(r.io);
        r.inbox.space.signal.notifyAll(r.io); // a blocked publisher must see `receiver_gone`
        sync.unlock(&r.inbox.mutex, r.io);
        r.inbox.release(r.io);
    }
};
