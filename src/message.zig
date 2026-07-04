//! # zicro.bus internals — the shared, reference-counted envelope
//!
//! [`Shared`] is one published envelope packed into a single pooled slab (header + the
//! three strings), reference-counted so a received [`Msg`] can outlive the bus. Split out
//! of [`bus`](bus.zig) so the inbox queue and the broker can each depend on the envelope
//! without carrying the whole file. Port of Rust's `Arc<Envelope>`-per-subscriber.

const std = @import("std");
const Allocator = std.mem.Allocator;

const sync = @import("sync.zig");
const protocol = @import("protocol.zig");
const pool_mod = @import("pool.zig");
const SlabPool = pool_mod.SlabPool;

const Envelope = protocol.Envelope;
const Channel = protocol.Channel;
const ModuleId = protocol.ModuleId;

pub const Shared = struct {
    refs: sync.RefCount,
    /// The slab pool this envelope's block came from (and returns to). Each in-flight
    /// envelope holds one pool reference, so messages can outlive the bus safely.
    pool: *SlabPool,
    /// Length of the slab (a size class, or exact when oversize) — what gets recycled.
    cap: usize,
    env: Envelope, // slices point into this same slab, right after the header

    /// One slab carries the header *and* the three strings: a publish is a single pool
    /// acquire — recycled, so **zero allocator calls in steady state** — and the envelope
    /// reads from one cache-warm contiguous block.
    pub fn create(pool: *SlabPool, from: ModuleId, channel: Channel, payload: []const u8) Allocator.Error!*Shared {
        const total = @sizeOf(Shared) + from.len + channel.len + payload.len;
        const slab = try pool.acquire(total);
        const s: *Shared = @ptrCast(slab.ptr);
        var off: usize = @sizeOf(Shared);
        const from_d = slab[off..][0..from.len];
        @memcpy(from_d, from);
        off += from.len;
        const channel_d = slab[off..][0..channel.len];
        @memcpy(channel_d, channel);
        off += channel.len;
        const payload_d = slab[off..][0..payload.len];
        @memcpy(payload_d, payload);
        s.* = .{
            .refs = .init(1),
            .pool = pool.retain(),
            .cap = slab.len,
            .env = .{ .from = from_d, .channel = channel_d, .payload = payload_d },
        };
        return s;
    }

    pub fn retain(s: *Shared) *Shared {
        s.refs.retain();
        return s;
    }

    pub fn release(s: *Shared) void {
        if (s.refs.release()) {
            const pool = s.pool;
            const raw: [*]align(pool_mod.slab_align) u8 = @ptrCast(@alignCast(s));
            pool.recycle(raw[0..s.cap]);
            pool.release();
        }
    }
};

/// One received envelope. A cheap handle onto a shared allocation: read it via
/// [`Msg.env`], release it with [`Msg.deinit`].
pub const Msg = struct {
    shared: *Shared,

    pub fn env(m: *const Msg) *const Envelope {
        return &m.shared.env;
    }

    pub fn deinit(m: Msg) void {
        m.shared.release();
    }
};
