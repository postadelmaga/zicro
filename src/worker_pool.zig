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
    /// Ring storage; `len` jobs start at `head` (wrapping). Grows by doubling.
    ring: []Job = &.{},
    head: usize = 0,
    len: usize = 0,
    max_queued: usize,
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
        try pool.workers.ensureTotalCapacity(gpa, size);
        for (0..size) |_| {
            pool.workers.appendAssumeCapacity(try std.Thread.spawn(.{}, workerLoop, .{pool}));
        }
        return pool;
    }

    fn workerLoop(pool: *WorkerPool) void {
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
            const job = pool.ring[pool.head];
            pool.head = (pool.head + 1) & (pool.ring.len - 1);
            pool.len -= 1;
            sync.unlock(&pool.mutex, pool.io);
            // Run with the lock released so peers can pull the next one concurrently.
            job.call(job.ctx);
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
