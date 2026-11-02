//! # zicro.core internals — the shared worker pool
//!
//! A fixed set of worker threads draining one shared job queue. Owned by the
//! [`Runtime`](core.zig) and reached by modules through [`ModuleCtx.offload`], it keeps a
//! module's single receive loop cheap: heavy CPU work is handed here instead of stalling
//! the loop (and, with the bounded bus, dropping later messages). Split out of
//! [`core`](core.zig) — it is an independent job-queue thread pool, unrelated to the
//! module/runtime lifecycle beyond being owned by it.
//!
//! ## Queue policy
//! The queue is a ring buffer that grows on demand (doubling) up to
//! [`Options.max_queued`] pending jobs and never shrinks while the pool lives — so memory
//! is bounded by the configured backlog, not by how many jobs were ever submitted, and a
//! consumed slot is reused immediately. A submission that would exceed the bound is
//! **rejected** with `error.QueueFull` rather than blocking: a job may itself submit
//! follow-ups, and a blocking submit from a worker thread could deadlock the pool against
//! itself. Every accepted job runs exactly once — shutdown drains the queue, it never
//! discards it.
//!
//! A producer that CAN wait — an outside thread, never a job — uses
//! [`WorkerPool.submitWait`] instead: it parks until the backlog has drained to half the
//! bound, then refills. That is the throughput path under sustained overload: retrying
//! `QueueFull` in a loop spins on the very mutex the workers need to drain the queue.
//! From a worker of the same pool `submitWait` never parks (it answers `QueueFull`
//! like `submit`), so a job can never deadlock the pool by waiting for itself.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sync = @import("sync.zig");

/// A type-erased unit of work. `call(ctx)` runs on a pool thread; the caller owns whatever
/// `ctx` points at and reclaims it (a rejected [`WorkerPool.submit`] hands ownership back).
pub const Job = struct {
    call: *const fn (*anyopaque) void,
    ctx: *anyopaque,
};

/// Why [`WorkerPool.submit`] did not accept a job. In every case the job was not queued
/// and will never run; the caller still owns it.
pub const SubmitError = error{
    /// The pool is shutting down (its owner is draining it).
    PoolClosed,
    /// [`Options.max_queued`] jobs are already pending.
    QueueFull,
} || Allocator.Error;

/// A fixed set of worker threads draining one shared job queue, sized from the CPU count.
/// Owned by the [`Runtime`]. Shutdown is deterministic: close the queue, let the workers
/// finish what is queued, join them — no leaked or detached threads.
pub const WorkerPool = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    changed: sync.Signal = .{},
    /// Woken when the backlog drops to `low_water` (or the pool closes) while a
    /// `submitWait` producer is parked; `space_waiters` (under `mutex`) gates it so the
    /// common dequeue pays nothing.
    space: sync.Signal = .{},
    space_waiters: usize = 0,
    /// Ring storage; `len` jobs start at `head` (wrapping). Grows by doubling.
    ring: []Job = &.{},
    head: usize = 0,
    len: usize = 0,
    max_queued: usize,
    /// Worker count, fixed before the first worker starts (workers read it lock-free).
    n_threads: usize = 1,
    closed: bool = false,
    workers: std.ArrayListUnmanaged(std.Thread) = .empty,

    pub const Options = struct {
        /// Worker threads; `null` = one per CPU.
        threads: ?usize = null,
        /// Upper bound on pending (accepted, not yet started) jobs. 64 Ki jobs is 1 MiB
        /// of queue at most — far beyond any sane backlog, low enough that a producer
        /// permanently outpacing the workers is reported instead of eating the heap.
        max_queued: usize = 1 << 16,
    };

    pub fn create(gpa: Allocator, io: Io, options: Options) !*WorkerPool {
        std.debug.assert(options.max_queued > 0);
        const pool = try gpa.create(WorkerPool);
        pool.* = .{ .gpa = gpa, .io = io, .max_queued = options.max_queued };
        // From here every failure goes through shutdownAndDestroy, which joins the workers
        // already started and frees the pool (it used to leak if the reserve failed).
        errdefer pool.shutdownAndDestroy();
        const size = @max(options.threads orelse (std.Thread.getCpuCount() catch 4), 1);
        pool.n_threads = size;
        try pool.workers.ensureTotalCapacity(gpa, size);
        for (0..size) |_| {
            pool.workers.appendAssumeCapacity(try std.Thread.spawn(.{}, workerLoop, .{pool}));
        }
        return pool;
    }

    /// The pool whose worker the current thread is, if any (`submitWait` must not park
    /// a worker: that worker may be the one that would make room).
    threadlocal var worker_of: ?*WorkerPool = null;

    fn lowWater(pool: *const WorkerPool) usize {
        return pool.max_queued / 2;
    }

    fn workerLoop(pool: *WorkerPool) void {
        worker_of = pool;
        while (true) {
            sync.lock(&pool.mutex, pool.io);
            while (pool.len == 0 and !pool.closed) {
                const snapshot = pool.changed.prepare();
                sync.unlock(&pool.mutex, pool.io);
                pool.changed.wait(pool.io, snapshot);
                sync.lock(&pool.mutex, pool.io);
            }
            if (pool.len == 0) {
                // Closed and drained: this worker exits.
                sync.unlock(&pool.mutex, pool.io);
                return;
            }
            // Batch: under a real backlog (>= 4 batches per worker) take up to 8 jobs per
            // lock — fewer acquisitions of the lock producers also need; measured, it cut
            // submit->run p99 from ~10-13 ms to ~2-3 ms at equal throughput. With a short
            // queue, one: a job then never waits behind a batch-mate while a peer is idle.
            // Trade-off: under a backlog a long job delays the (<= 7) jobs it took with it.
            var batch: [8]Job = undefined;
            const want = if (pool.len >= 4 * batch.len * pool.n_threads) batch.len else 1;
            const n = @min(want, pool.len);
            for (0..n) |k| {
                batch[k] = pool.ring[pool.head];
                pool.head = (pool.head + 1) & (pool.ring.len - 1);
            }
            pool.len -= n;
            // Decided under the lock (a parked producer registered under it too), so the
            // wake cannot be lost; signalled after it, so the producer does not wake
            // straight into a held mutex.
            const wake_producers = pool.space_waiters != 0 and pool.len <= pool.lowWater();
            sync.unlock(&pool.mutex, pool.io);
            if (wake_producers) pool.space.notifyAll(pool.io);
            // Run with the lock released so peers can pull the next one concurrently.
            for (batch[0..n]) |job| job.call(job.ctx);
        }
    }

    /// Enqueue a job. On success the job WILL run exactly once (shutdown drains). On error
    /// it was not queued and the caller still owns its memory — the type-erased `job.ctx`
    /// can only be reclaimed by the caller.
    pub fn submit(pool: *WorkerPool, job: Job) SubmitError!void {
        sync.lock(&pool.mutex, pool.io);
        defer sync.unlock(&pool.mutex, pool.io);
        if (pool.closed) return error.PoolClosed;
        if (pool.len == pool.max_queued) return error.QueueFull;
        if (pool.len == pool.ring.len) try pool.grow();
        pool.ring[(pool.head + pool.len) & (pool.ring.len - 1)] = job;
        pool.len += 1;
        pool.changed.notifyAll(pool.io);
    }

    /// [`submit`](WorkerPool.submit) for a producer that can wait: when the backlog is
    /// at the bound it parks (no spinning on the lock the workers need) until the
    /// workers have drained it to half, instead of answering `QueueFull`. Refused with
    /// `PoolClosed` once shutdown began. Like `submit`, it must not be running when the
    /// owner calls `shutdownAndDestroy` (which frees the pool): an outside producer is
    /// the owner's to stop first — the Runtime's modules are joined before its pool.
    ///
    /// Called from a worker thread of THIS pool it never parks and answers `QueueFull`
    /// exactly like `submit`: a job waiting for queue room could be waiting for itself.
    pub fn submitWait(pool: *WorkerPool, job: Job) SubmitError!void {
        if (worker_of == pool) return pool.submit(job);
        sync.lock(&pool.mutex, pool.io);
        defer sync.unlock(&pool.mutex, pool.io);
        while (!pool.closed and pool.len == pool.max_queued) {
            const snapshot = pool.space.prepare();
            pool.space_waiters += 1;
            sync.unlock(&pool.mutex, pool.io);
            pool.space.wait(pool.io, snapshot);
            sync.lock(&pool.mutex, pool.io);
            pool.space_waiters -= 1;
        }
        if (pool.closed) return error.PoolClosed;
        if (pool.len == pool.ring.len) try pool.grow();
        pool.ring[(pool.head + pool.len) & (pool.ring.len - 1)] = job;
        pool.len += 1;
        pool.changed.notifyAll(pool.io);
    }

    /// Double the ring (power-of-two sizes, so wrapping is a mask), unwrapping the pending
    /// jobs to the front of the new storage. Caller holds the lock.
    fn grow(pool: *WorkerPool) Allocator.Error!void {
        const new_cap = if (pool.ring.len == 0) 16 else pool.ring.len * 2;
        const ring = try pool.gpa.alloc(Job, new_cap);
        for (0..pool.len) |i| ring[i] = pool.ring[(pool.head + i) & (pool.ring.len - 1)];
        pool.gpa.free(pool.ring);
        pool.ring = ring;
        pool.head = 0;
    }

    /// Pending (accepted, not yet started) jobs — for metrics and tests.
    pub fn pending(pool: *WorkerPool) usize {
        sync.lock(&pool.mutex, pool.io);
        defer sync.unlock(&pool.mutex, pool.io);
        return pool.len;
    }

    /// Close the queue, let the workers drain what is queued (every accepted job runs), join
    /// them, free the pool. Jobs running during the drain may still `submit`; they get
    /// `error.PoolClosed`.
    pub fn shutdownAndDestroy(pool: *WorkerPool) void {
        sync.lock(&pool.mutex, pool.io);
        pool.closed = true;
        pool.changed.notifyAll(pool.io);
        pool.space.notifyAll(pool.io); // a parked submitWait must not sleep through close
        sync.unlock(&pool.mutex, pool.io);
        for (pool.workers.items) |worker| worker.join();
        std.debug.assert(pool.len == 0); // drained: nothing accepted was dropped
        pool.workers.deinit(pool.gpa);
        pool.gpa.free(pool.ring);
        pool.gpa.destroy(pool);
    }
};

// --- tests ---------------------------------------------------------------------------------

const testing = std.testing;

const Gate = struct {
    open: std.atomic.Value(bool) = .init(false),
    started: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(usize) = .init(0),

    fn job(ctx: *anyopaque) void {
        const g: *Gate = @ptrCast(@alignCast(ctx));
        _ = g.started.fetchAdd(1, .acq_rel);
        while (!g.open.load(.acquire)) std.atomic.spinLoopHint();
        _ = g.done.fetchAdd(1, .acq_rel);
    }

    fn count(ctx: *anyopaque) void {
        const g: *Gate = @ptrCast(@alignCast(ctx));
        _ = g.done.fetchAdd(1, .acq_rel);
    }
};

fn waitFor(v: *std.atomic.Value(usize), want: usize) void {
    while (v.load(.acquire) < want) std.atomic.spinLoopHint();
}

test "a full queue rejects deterministically and every accepted job still runs" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const pool = try WorkerPool.create(testing.allocator, threaded.io(), .{ .threads = 1, .max_queued = 4 });

    var blocker: Gate = .{};
    try pool.submit(.{ .call = Gate.job, .ctx = &blocker });
    waitFor(&blocker.started, 1); // the only worker is now busy: nothing else dequeues

    var counter: Gate = .{};
    for (0..4) |_| try pool.submit(.{ .call = Gate.count, .ctx = &counter });
    try testing.expectError(error.QueueFull, pool.submit(.{ .call = Gate.count, .ctx = &counter }));
    try testing.expectEqual(@as(usize, 4), pool.pending());

    blocker.open.store(true, .release);
    pool.shutdownAndDestroy(); // drains the 4 accepted jobs
    try testing.expectEqual(@as(usize, 4), counter.done.load(.acquire));
    try testing.expectEqual(@as(usize, 1), blocker.done.load(.acquire));
}

test "the ring reuses consumed slots: sustained load never grows past the backlog" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const pool = try WorkerPool.create(testing.allocator, threaded.io(), .{ .threads = 2, .max_queued = 64 });

    // 20k jobs submitted while the workers keep up only partially: the old queue kept every
    // consumed entry until it fully drained once, so its storage tracked the TOTAL count.
    var counter: Gate = .{};
    var accepted: usize = 0;
    for (0..20_000) |_| {
        pool.submit(.{ .call = Gate.count, .ctx = &counter }) catch |e| switch (e) {
            error.QueueFull => {
                std.atomic.spinLoopHint();
                continue;
            },
            else => return e,
        };
        accepted += 1;
    }
    try testing.expect(pool.ring.len <= 64);
    pool.shutdownAndDestroy();
    try testing.expectEqual(accepted, counter.done.load(.acquire));
}

test "submit after shutdown began reports PoolClosed" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const pool = try WorkerPool.create(testing.allocator, threaded.io(), .{ .threads = 1 });
    sync.lock(&pool.mutex, pool.io);
    pool.closed = true; // the first half of shutdownAndDestroy, observed by a racing submitter
    sync.unlock(&pool.mutex, pool.io);
    var counter: Gate = .{};
    try testing.expectError(error.PoolClosed, pool.submit(.{ .call = Gate.count, .ctx = &counter }));
    pool.shutdownAndDestroy();
    try testing.expectEqual(@as(usize, 0), counter.done.load(.acquire));
}

test "create cleans up when it cannot finish" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    // Fail the worker-list reserve (allocation #1, after the pool itself): the pool must
    // not leak (the testing allocator checks).
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 1 });
    try testing.expectError(error.OutOfMemory, WorkerPool.create(failing.allocator(), threaded.io(), .{ .threads = 2 }));
}

// --- concurrency stress ---------------------------------------------------------------------
// These run real threads against the real pool. The properties are counted, not timed:
// every ACCEPTED job runs EXACTLY once (a per-job counter, so a double run or a lost
// job is caught individually), QueueFull/PoolClosed never lose an accepted job, and the
// allocator sees no leak and no double free (testing.allocator is thread-safe).

const Tally = struct {
    runs: []std.atomic.Value(u8),
    fn job(ctx: *anyopaque) void {
        const slot: *std.atomic.Value(u8) = @ptrCast(@alignCast(ctx));
        _ = slot.fetchAdd(1, .acq_rel);
    }
};

test "stress: many producers, tiny bound — every accepted job runs exactly once" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const pool = try WorkerPool.create(testing.allocator, threaded.io(), .{ .threads = 3, .max_queued = 8 });

    const producers = 4;
    const per = 5_000;
    const runs = try testing.allocator.alloc(std.atomic.Value(u8), producers * per);
    defer testing.allocator.free(runs);
    for (runs) |*r| r.* = .init(0);
    var full: std.atomic.Value(usize) = .init(0);

    const P = struct {
        fn produce(p: *WorkerPool, slots: []std.atomic.Value(u8), full_count: *std.atomic.Value(usize)) void {
            for (slots) |*slot| {
                // QueueFull is backpressure, not loss: retry until accepted.
                while (true) {
                    p.submit(.{ .call = Tally.job, .ctx = slot }) catch |e| switch (e) {
                        error.QueueFull => {
                            _ = full_count.fetchAdd(1, .monotonic);
                            std.Thread.yield() catch {};
                            continue;
                        },
                        else => unreachable,
                    };
                    break;
                }
            }
        }
    };
    var threads: [producers]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, P.produce, .{ pool, runs[i * per .. (i + 1) * per], &full });
    for (threads) |t| t.join();
    pool.shutdownAndDestroy(); // drains whatever is still queued

    for (runs, 0..) |*r, i| {
        if (r.load(.acquire) != 1) {
            std.debug.print("job {d} ran {d} times\n", .{ i, r.load(.acquire) });
            return error.TestUnexpectedResult;
        }
    }
    // With 4 producers against a bound of 8 the backpressure path must have been taken —
    // otherwise this test did not exercise what it claims to.
    try testing.expect(full.load(.monotonic) > 0);
}

/// A job that keeps re-submitting itself: the shape of "offload during drain".
const Chain = struct {
    pool: *WorkerPool,
    accepted: std.atomic.Value(usize) = .init(0),
    ran: std.atomic.Value(usize) = .init(0),
    closed_seen: std.atomic.Value(usize) = .init(0),

    fn job(ctx: *anyopaque) void {
        const c: *Chain = @ptrCast(@alignCast(ctx));
        _ = c.ran.fetchAdd(1, .acq_rel);
        c.pool.submit(.{ .call = job, .ctx = c }) catch |e| switch (e) {
            error.PoolClosed => {
                _ = c.closed_seen.fetchAdd(1, .monotonic);
                return;
            },
            error.QueueFull => return, // this link of the chain ends; others continue
            error.OutOfMemory => unreachable,
        };
        _ = c.accepted.fetchAdd(1, .acq_rel);
    }
};

test "stress: jobs offloading follow-ups across shutdown — accepted == ran, no hang" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    for (0..20) |_| {
        const pool = try WorkerPool.create(testing.allocator, threaded.io(), .{ .threads = 4, .max_queued = 64 });
        var chain: Chain = .{ .pool = pool };
        for (0..16) |_| {
            try pool.submit(.{ .call = Chain.job, .ctx = &chain });
            _ = chain.accepted.fetchAdd(1, .acq_rel);
        }
        // Let the chains spin a little so shutdown lands mid-flight, then close.
        while (chain.ran.load(.acquire) < 2_000) std.atomic.spinLoopHint();
        pool.shutdownAndDestroy();
        // Every accepted submission ran — the drain did not drop the follow-ups accepted
        // just before close — and the chains that outlived close were told PoolClosed.
        try testing.expectEqual(chain.accepted.load(.acquire), chain.ran.load(.acquire));
        try testing.expect(chain.closed_seen.load(.monotonic) > 0);
    }
}

test "stress: submitWait producers never see QueueFull, every job runs exactly once" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const pool = try WorkerPool.create(testing.allocator, threaded.io(), .{ .threads = 2, .max_queued = 8 });

    const producers = 4;
    const per = 5_000;
    const runs = try testing.allocator.alloc(std.atomic.Value(u8), producers * per);
    defer testing.allocator.free(runs);
    for (runs) |*r| r.* = .init(0);

    const P = struct {
        fn produce(p: *WorkerPool, slots: []std.atomic.Value(u8)) void {
            for (slots) |*slot| p.submitWait(.{ .call = Tally.job, .ctx = slot }) catch unreachable;
        }
    };
    var threads: [producers]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, P.produce, .{ pool, runs[i * per .. (i + 1) * per] });
    for (threads) |t| t.join();
    try testing.expect(pool.pending() <= 8); // the bound held throughout (checked at the end)
    pool.shutdownAndDestroy();
    for (runs) |*r| try testing.expectEqual(@as(u8, 1), r.load(.acquire));
}

test "submitWait parks while full and resumes once the workers drain" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const pool = try WorkerPool.create(testing.allocator, threaded.io(), .{ .threads = 1, .max_queued = 2 });
    var blocker: Gate = .{};
    try pool.submit(.{ .call = Gate.job, .ctx = &blocker });
    waitFor(&blocker.started, 1); // the only worker is busy
    var counter: Gate = .{};
    try pool.submit(.{ .call = Gate.count, .ctx = &counter });
    try pool.submit(.{ .call = Gate.count, .ctx = &counter }); // full now
    try testing.expectError(error.QueueFull, pool.submit(.{ .call = Gate.count, .ctx = &counter }));

    var accepted: std.atomic.Value(bool) = .init(false);
    const W = struct {
        fn go(p: *WorkerPool, c: *Gate, done: *std.atomic.Value(bool)) void {
            p.submitWait(.{ .call = Gate.count, .ctx = c }) catch unreachable;
            done.store(true, .release);
        }
    };
    const t = try std.Thread.spawn(.{}, W.go, .{ pool, &counter, &accepted });
    // It cannot get in while the worker is blocked: the queue stays full.
    for (0..1000) |_| std.Thread.yield() catch {};
    try testing.expect(!accepted.load(.acquire));
    blocker.open.store(true, .release); // drain -> low water -> the producer is woken
    t.join();
    try testing.expect(accepted.load(.acquire));
    pool.shutdownAndDestroy();
    try testing.expectEqual(@as(usize, 3), counter.done.load(.acquire));
}

test "submitWait from a worker never parks: a full pool answers QueueFull (no self-deadlock)" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const pool = try WorkerPool.create(testing.allocator, threaded.io(), .{ .threads = 1, .max_queued = 1 });
    const J = struct {
        pool: *WorkerPool,
        filler: Gate = .{},
        verdict: std.atomic.Value(u8) = .init(0), // 1 = QueueFull, 2 = accepted, 3 = other
        fn job(ctx: *anyopaque) void {
            const j: *@This() = @ptrCast(@alignCast(ctx));
            // Fill the one slot, then ask to wait for room: only THIS worker could make
            // it, so parking here would hang the pool for ever.
            j.pool.submit(.{ .call = Gate.count, .ctx = &j.filler }) catch {};
            j.pool.submitWait(.{ .call = Gate.count, .ctx = &j.filler }) catch |e| {
                j.verdict.store(if (e == error.QueueFull) 1 else 3, .release);
                return;
            };
            j.verdict.store(2, .release);
        }
    };
    var j: J = .{ .pool = pool };
    try pool.submit(.{ .call = J.job, .ctx = &j });
    // The verdict arrives while the pool is OPEN — a parked worker would hang here.
    while (j.verdict.load(.acquire) == 0) std.Thread.yield() catch {};
    pool.shutdownAndDestroy();
    try testing.expectEqual(@as(u8, 1), j.verdict.load(.acquire));
    try testing.expectEqual(@as(usize, 1), j.filler.done.load(.acquire));
}

test "submitWait after shutdown began is refused" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const pool = try WorkerPool.create(testing.allocator, threaded.io(), .{ .threads = 1 });
    const Probe = struct {
        pool: *WorkerPool,
        got: ?SubmitError = null,
        noop: Gate = .{},
        fn job(ctx: *anyopaque) void {
            const p: *@This() = @ptrCast(@alignCast(ctx));
            // Running during the drain: close already happened.
            while (true) {
                sync.lock(&p.pool.mutex, p.pool.io);
                const closed = p.pool.closed;
                sync.unlock(&p.pool.mutex, p.pool.io);
                if (closed) break;
                std.Thread.yield() catch {};
            }
            p.pool.submitWait(.{ .call = Gate.count, .ctx = &p.noop }) catch |e| {
                p.got = e;
            };
        }
    };
    var probe: Probe = .{ .pool = pool };
    try pool.submit(.{ .call = Probe.job, .ctx = &probe });
    pool.shutdownAndDestroy();
    try testing.expectEqual(@as(?SubmitError, error.PoolClosed), probe.got);
}

test "a short queue is never batched: a quick job runs while a long one blocks its worker" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const pool = try WorkerPool.create(testing.allocator, threaded.io(), .{ .threads = 2 });
    var blocker: Gate = .{};
    var quick: Gate = .{};
    try pool.submit(.{ .call = Gate.job, .ctx = &blocker });
    try pool.submit(.{ .call = Gate.count, .ctx = &quick });
    // Had one worker taken both, the quick job would wait for the blocker.
    waitFor(&quick.done, 1);
    try testing.expectEqual(@as(usize, 0), blocker.done.load(.acquire));
    blocker.open.store(true, .release);
    pool.shutdownAndDestroy();
}
