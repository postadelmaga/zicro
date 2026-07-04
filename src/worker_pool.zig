//! # zicro.core internals — the shared worker pool
//!
//! A fixed set of worker threads draining one shared job queue. Owned by the
//! [`Runtime`](core.zig) and reached by modules through [`ModuleCtx.offload`], it keeps a
//! module's single receive loop cheap: heavy CPU work is handed here instead of stalling
//! the loop (and, with the bounded bus, dropping later messages). Split out of
//! [`core`](core.zig) — it is an independent job-queue thread pool, unrelated to the
//! module/runtime lifecycle beyond being owned by it.

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

/// A fixed set of worker threads draining one shared job queue, sized from the CPU count.
/// Owned by the [`Runtime`]. Shutdown is deterministic: close the queue, let the workers
/// finish what is queued, join them — no leaked or detached threads.
pub const WorkerPool = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    changed: sync.Signal = .{},
    jobs: std.ArrayListUnmanaged(Job) = .empty,
    head: usize = 0,
    closed: bool = false,
    workers: std.ArrayListUnmanaged(std.Thread) = .empty,

    pub fn create(gpa: Allocator, io: Io) !*WorkerPool {
        const pool = try gpa.create(WorkerPool);
        pool.* = .{ .gpa = gpa, .io = io };
        const size = @max(std.Thread.getCpuCount() catch 4, 1);
        try pool.workers.ensureTotalCapacity(gpa, size);
        for (0..size) |_| {
            const worker = std.Thread.spawn(.{}, workerLoop, .{pool}) catch |e| {
                pool.shutdownAndDestroy();
                return e;
            };
            pool.workers.appendAssumeCapacity(worker);
        }
        return pool;
    }

    fn workerLoop(pool: *WorkerPool) void {
        while (true) {
            sync.lock(&pool.mutex, pool.io);
            while (pool.head == pool.jobs.items.len and !pool.closed) {
                const snapshot = pool.changed.prepare();
                sync.unlock(&pool.mutex, pool.io);
                pool.changed.wait(pool.io, snapshot);
                sync.lock(&pool.mutex, pool.io);
            }
            if (pool.head == pool.jobs.items.len) {
                // Closed and drained: this worker exits.
                sync.unlock(&pool.mutex, pool.io);
                return;
            }
            const job = pool.jobs.items[pool.head];
            pool.head += 1;
            if (pool.head == pool.jobs.items.len) {
                pool.jobs.clearRetainingCapacity();
                pool.head = 0;
            }
            sync.unlock(&pool.mutex, pool.io);
            // Run with the lock released so peers can pull the next one concurrently.
            job.call(job.ctx);
        }
    }

    /// Enqueue a job. Returns `true` if the job was accepted, `false` if the pool is
    /// already shutting down (in which case the caller still owns the job's memory and
    /// must free it — the type-erased `job.ctx` can only be reclaimed by the caller).
    pub fn submit(pool: *WorkerPool, job: Job) Allocator.Error!bool {
        sync.lock(&pool.mutex, pool.io);
        defer sync.unlock(&pool.mutex, pool.io);
        if (pool.closed) return false;
        try pool.jobs.append(pool.gpa, job);
        pool.changed.notifyAll(pool.io);
        return true;
    }

    /// Close the queue, let the workers drain what is queued, join them, free the pool.
    pub fn shutdownAndDestroy(pool: *WorkerPool) void {
        sync.lock(&pool.mutex, pool.io);
        pool.closed = true;
        pool.changed.notifyAll(pool.io);
        sync.unlock(&pool.mutex, pool.io);
        for (pool.workers.items) |worker| worker.join();
        pool.workers.deinit(pool.gpa);
        pool.jobs.deinit(pool.gpa);
        pool.gpa.destroy(pool);
    }
};
