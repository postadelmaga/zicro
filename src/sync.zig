//! Internal synchronization primitives shared by the bus, the media plane and the runtime.
//!
//! Zig 0.16 moved blocking primitives behind the `std.Io` interface: `Io.Mutex` and
//! `Io.Condition` need an `Io` instance, and `Io.Condition` has no timed wait. zicro's
//! module loops are built on *timed* receives (`recvTimeout` is what lets a loop wake up
//! and observe shutdown), so this file adds the one missing piece: [`Signal`], an
//! epoch-counter wait/notify built directly on the `Io` futex — the same construction
//! `Io.Condition` uses internally, plus a timeout.

const std = @import("std");
const Io = std.Io;

/// The clock every deadline and pace in zicro is measured on (monotonic while awake).
pub const clock: Io.Clock = .awake;

/// A shared reference count with the canonical Arc memory ordering. A new holder only
/// needs atomicity, so [`retain`](RefCount.retain) increments `monotonic`; the final
/// [`release`](RefCount.release) must both *observe* every prior holder's writes and
/// *publish* its own before teardown, so it decrements `acq_rel`. `release` returns `true`
/// exactly once — for the last holder, which owns the teardown. Consolidated here so the
/// ordering lives in one place instead of being re-derived at every reference-counted type
/// (the bus's `Shared`/`SpaceSignal`/`Inbox`, the slab `Pool`, the media `Rc`).
pub const RefCount = struct {
    n: std.atomic.Value(usize),

    pub fn init(initial: usize) RefCount {
        return .{ .n = .init(initial) };
    }

    /// Add a reference.
    pub fn retain(rc: *RefCount) void {
        _ = rc.n.fetchAdd(1, .monotonic);
    }

    /// Drop a reference; returns `true` iff this was the last one (run teardown then).
    pub fn release(rc: *RefCount) bool {
        return rc.n.fetchSub(1, .acq_rel) == 1;
    }

    /// The current count — for metrics/asserts, never for a decision that races a drop.
    pub fn count(rc: *const RefCount) usize {
        return rc.n.load(.monotonic);
    }
};

/// A wait/notify epoch counter. Waiters snapshot the epoch, re-check their predicate under
/// the caller's lock, then sleep until the epoch moves (or a timeout passes). Every state
/// change that could unblock a waiter must call [`notifyAll`](Signal.notifyAll).
///
/// Notification is **waiter-gated** (the classic eventcount optimization): `notifyAll`
/// issues the `futexWake` syscall only when a waiter is actually registered. On a hot
/// push/pop path where the other side is busy rather than blocked, a notify is a single
/// atomic add — no syscall, no thundering herd.
pub const Signal = struct {
    epoch: std.atomic.Value(u32) = .init(0),
    /// Threads inside `wait`/`waitTimeout` right now. Gates the wake syscall.
    waiters: std.atomic.Value(u32) = .init(0),

    /// Snapshot the epoch *before* releasing the lock that protects the predicate.
    pub fn prepare(s: *const Signal) u32 {
        return s.epoch.load(.acquire);
    }

    /// Bump the epoch and wake every waiter. Call after mutating the waited-on state.
    ///
    /// The gate cannot miss a wake: the epoch bump and the waiters load are both seq_cst,
    /// and a waiter registers itself (seq_cst) *before* the futex validates the epoch. So
    /// if this load sees zero waiters, any waiter registering later necessarily observes
    /// the bumped epoch in `futexWait` and returns immediately instead of sleeping.
    pub fn notifyAll(s: *Signal, io: Io) void {
        _ = s.epoch.fetchAdd(1, .seq_cst);
        if (s.waiters.load(.seq_cst) != 0) {
            io.futexWake(u32, &s.epoch.raw, std.math.maxInt(u32));
        }
    }

    /// Block until the epoch moves past `snapshot`. Spurious wakeups are allowed — the
    /// caller loops re-checking its predicate.
    pub fn wait(s: *Signal, io: Io, snapshot: u32) void {
        _ = s.waiters.fetchAdd(1, .seq_cst);
        defer _ = s.waiters.fetchSub(1, .release);
        io.futexWaitUncancelable(u32, &s.epoch.raw, snapshot);
    }

    /// Like [`wait`](Signal.wait) but gives up after `timeout`. Spurious wakeups are
    /// allowed; the caller re-checks both its predicate and its deadline.
    pub fn waitTimeout(s: *Signal, io: Io, snapshot: u32, timeout: Io.Timeout) void {
        _ = s.waiters.fetchAdd(1, .seq_cst);
        defer _ = s.waiters.fetchSub(1, .release);
        io.futexWaitTimeout(u32, &s.epoch.raw, snapshot, timeout) catch {};
    }

    /// Spin-then-park: watch the epoch for a short bounded spin (roughly the cost of one
    /// futex round trip) before parking in [`wait`](Signal.wait). In a streaming pipeline
    /// the notifier usually arrives inside the window, so *neither* side pays a syscall —
    /// the waiter never parks and the (waiter-gated) notifier never wakes. Under real
    /// idleness it parks like `wait`, so the energy cost is bounded and tiny.
    pub fn waitSpin(s: *Signal, io: Io, snapshot: u32) void {
        var spins: u32 = spin_budget;
        while (spins > 0) : (spins -= 1) {
            if (s.epoch.load(.acquire) != snapshot) return;
            std.atomic.spinLoopHint();
        }
        s.wait(io, snapshot);
    }
};

/// Epoch probes before a spinning waiter gives up and parks — sized so the spin costs
/// about as much as the futex round trip it tries to avoid (~1 µs).
pub const spin_budget: u32 = 400;

/// Lock an `Io.Mutex` without threading cancellation through every caller — zicro threads
/// are plain `std.Thread`s, never canceled Io tasks.
pub fn lock(m: *Io.Mutex, io: Io) void {
    m.lockUncancelable(io);
}

pub fn unlock(m: *Io.Mutex, io: Io) void {
    m.unlock(io);
}

/// Monotonic now, for deadlines and pacing.
pub fn now(io: Io) Io.Clock.Timestamp {
    return Io.Clock.Timestamp.now(io, clock);
}

pub fn durationNs(ns: u64) Io.Clock.Duration {
    return .{ .clock = clock, .raw = .fromNanoseconds(@intCast(ns)) };
}

/// A deadline `ns` nanoseconds from now.
pub fn deadlineAfterNs(io: Io, ns: u64) Io.Clock.Timestamp {
    return now(io).addDuration(durationNs(ns));
}

/// Whether `deadline` has passed.
pub fn expired(io: Io, deadline: Io.Clock.Timestamp) bool {
    return now(io).compare(.gte, deadline);
}

/// Sleep `ns` nanoseconds on the shared clock.
pub fn sleepNs(io: Io, ns: u64) void {
    io.sleep(.fromNanoseconds(@intCast(ns)), clock) catch {};
}

/// Elapsed seconds from `from` to `to` (both on [`clock`]).
pub fn secondsBetween(from: Io.Clock.Timestamp, to: Io.Clock.Timestamp) f64 {
    const ns: f64 = @floatFromInt(from.raw.durationTo(to.raw).nanoseconds);
    return ns / std.time.ns_per_s;
}

test "signal wakes a waiter" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sig: Signal = .{};
    const snapshot = sig.prepare();
    sig.notifyAll(io);
    // The epoch moved, so a wait on the stale snapshot returns immediately.
    sig.wait(io, snapshot);
}

test "waitTimeout returns on timeout" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var sig: Signal = .{};
    const snapshot = sig.prepare();
    // Nothing will notify: this must come back on its own.
    sig.waitTimeout(io, snapshot, .{ .duration = durationNs(5 * std.time.ns_per_ms) });
}
