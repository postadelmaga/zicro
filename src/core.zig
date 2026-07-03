//! # zicro.core — the module runtime
//!
//! The micro-kernel: composes the bus and the document into a tiny app shell. A
//! [`Module`] declares the channels it listens on and a `run` loop; the [`Runtime`]
//! subscribes it to the bus and spawns it on its own thread. Modules talk only through
//! their [`ModuleCtx`] (publish + receive) — never directly to each other, which is
//! exactly what keeps them swappable.
//!
//! ## Lifecycle & supervision (thread model, no async)
//! The runtime owns a cooperative [`Shutdown`] signal. A module's loop checks
//! [`ModuleCtx.shouldStop`] and blocks with [`ModuleCtx.recvTimeout`] so it wakes
//! periodically to observe it. [`Runtime.shutdown`] flips the signal; [`Runtime.join`]
//! waits and reports which modules **failed**. Supervision is *fail-fast*: a module whose
//! `run` returns an error is recorded and automatically triggers shutdown of the others —
//! the app winds down cleanly instead of hanging.
//!
//! Port note (Rust → Zig): Rust modules signal failure by panicking (caught with
//! `catch_unwind`). A Zig panic aborts the process and cannot be caught, so the contract
//! here is explicit: `run` returns `anyerror!void`, and a returned error plays the role
//! of the Rust panic — isolated, reported by `join`, and shutdown-triggering.
//!
//! ## Receive fast, compute on the pool, publish back (no head-of-line blocking)
//! A module runs on a *single* thread: if its `run` loop does heavy CPU work inline it
//! stops draining its inbox, and with the bounded bus later messages may be dropped. The
//! cure is to keep the loop cheap and hand the heavy work to the runtime's shared worker
//! pool via [`ModuleCtx.offload`] — the job runs on a pool thread and publishes its
//! result back onto a channel through a captured bus handle.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sync = @import("sync.zig");
const protocol = @import("protocol.zig");
const bus_mod = @import("bus.zig");

pub const LocalBus = bus_mod.LocalBus;
pub const Receiver = bus_mod.Receiver;
pub const Msg = bus_mod.Msg;
pub const BusError = bus_mod.BusError;
pub const Envelope = protocol.Envelope;
pub const Channel = protocol.Channel;
pub const ModuleId = protocol.ModuleId;
pub const Topic = protocol.Topic;

/// A cooperative shutdown signal shared by the runtime and every module. Cheap to copy.
pub const Shutdown = struct {
    flag: *std.atomic.Value(bool),

    /// Whether shutdown has been requested.
    pub fn isTriggered(s: Shutdown) bool {
        return s.flag.load(.acquire);
    }

    /// Request shutdown. Idempotent.
    pub fn trigger(s: Shutdown) void {
        s.flag.store(true, .release);
    }
};

// --- the module interface --------------------------------------------------------------

/// A unit of behaviour hosted by the [`Runtime`]: a type-erased instance + vtable.
///
/// Implement a plain struct with:
/// * `pub fn id(self: *T) []const u8` — stable id stamped on everything it publishes;
/// * `pub fn subscriptions(self: *T) []const []const u8` — channels for its inbox
///   (optional; omitting it means a pure producer);
/// * `pub fn run(self: *T, ctx: *ModuleCtx) anyerror!void` — the run loop, on its own
///   thread; it owns its state and ends when it returns.
///
/// Then wrap it with [`Module.of`] (borrowed instance — must outlive `join`) or hand the
/// runtime a heap instance with [`Module.ofOwned`] (destroyed after `run` returns).
pub const Module = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        id: *const fn (*anyopaque) []const u8,
        subscriptions: *const fn (*anyopaque) []const []const u8,
        run: *const fn (*anyopaque, *ModuleCtx) anyerror!void,
        /// Called once after `run` returns (owned modules only): free the instance.
        deinit: ?*const fn (*anyopaque, Allocator) void,
    };

    fn vtableFor(comptime T: type, comptime owned: bool) *const VTable {
        const Impl = struct {
            fn id(ptr: *anyopaque) []const u8 {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.id();
            }
            fn subscriptions(ptr: *anyopaque) []const []const u8 {
                if (comptime std.meta.hasFn(T, "subscriptions")) {
                    const self: *T = @ptrCast(@alignCast(ptr));
                    return self.subscriptions();
                }
                return &.{};
            }
            fn run(ptr: *anyopaque, ctx: *ModuleCtx) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                return self.run(ctx);
            }
            fn deinitFn(ptr: *anyopaque, gpa: Allocator) void {
                const self: *T = @ptrCast(@alignCast(ptr));
                if (comptime std.meta.hasFn(T, "deinit")) self.deinit();
                gpa.destroy(self);
            }
            const vtable: VTable = .{
                .id = id,
                .subscriptions = subscriptions,
                .run = run,
                .deinit = if (owned) deinitFn else null,
            };
        };
        return &Impl.vtable;
    }

    /// Wrap a borrowed instance: the caller keeps ownership and must keep it alive until
    /// [`Runtime.join`] returns.
    pub fn of(comptime T: type, instance: *T) Module {
        return .{ .ptr = instance, .vtable = vtableFor(T, false) };
    }

    /// Wrap a heap instance allocated with the runtime's allocator: the runtime destroys
    /// it (calling `T.deinit` first, if declared) after its `run` returns.
    pub fn ofOwned(comptime T: type, instance: *T) Module {
        return .{ .ptr = instance, .vtable = vtableFor(T, true) };
    }
};

// --- worker pool (offload heavy work off a module's receive loop) -----------------------

const Job = struct {
    call: *const fn (*anyopaque) void,
    ctx: *anyopaque,
};

/// A fixed set of worker threads draining one shared job queue, sized from the CPU count.
/// Owned by the [`Runtime`]. Shutdown is deterministic: close the queue, let the workers
/// finish what is queued, join them — no leaked or detached threads.
const WorkerPool = struct {
    gpa: Allocator,
    io: Io,
    mutex: Io.Mutex = .init,
    changed: sync.Signal = .{},
    jobs: std.ArrayListUnmanaged(Job) = .empty,
    head: usize = 0,
    closed: bool = false,
    workers: std.ArrayListUnmanaged(std.Thread) = .empty,

    fn create(gpa: Allocator, io: Io) !*WorkerPool {
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

    /// Enqueue a job. If the pool is already shutting down the job is dropped.
    fn submit(pool: *WorkerPool, job: Job) Allocator.Error!void {
        sync.lock(&pool.mutex, pool.io);
        defer sync.unlock(&pool.mutex, pool.io);
        if (pool.closed) return;
        try pool.jobs.append(pool.gpa, job);
        pool.changed.notifyAll(pool.io);
    }

    /// Close the queue, let the workers drain what is queued, join them, free the pool.
    fn shutdownAndDestroy(pool: *WorkerPool) void {
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

// --- the module context ------------------------------------------------------------------

/// What a module gets to talk to the world: its identity, a handle to publish, the merged
/// inbox of its subscribed channels, the shared shutdown signal, and the runtime's worker
/// pool for offloading heavy work off its receive loop.
pub const ModuleCtx = struct {
    id: []const u8,
    gpa: Allocator,
    io: Io,
    bus_ptr: *LocalBus,
    rx: Receiver,
    shutdown: Shutdown,
    pool: *WorkerPool,

    /// Whether the runtime has asked everyone to stop. A module's loop should check this.
    pub fn shouldStop(ctx: *const ModuleCtx) bool {
        return ctx.shutdown.isTriggered();
    }

    /// Publish a raw JSON payload on `channel`, stamped with this module's id.
    pub fn publish(ctx: *ModuleCtx, channel: Channel, payload: []const u8) BusError!void {
        return ctx.bus_ptr.publish(ctx.id, channel, payload);
    }

    /// Publish a **typed** message on `channel` (serialized to the payload). Preferred
    /// over [`publish`](ModuleCtx.publish): the contract is a real type, not hand-built JSON.
    pub fn publishMsg(ctx: *ModuleCtx, channel: Channel, msg: anytype) BusError!void {
        return ctx.bus_ptr.publishMsg(ctx.id, channel, msg);
    }

    /// Publish a typed message on a [`Topic`] — the compiler-checked form of
    /// [`publishMsg`](ModuleCtx.publishMsg): the topic fixes both the channel *and* the
    /// payload type, so a producer can't send the wrong shape on the wrong channel.
    pub fn publishOn(ctx: *ModuleCtx, topic: anytype, msg: @TypeOf(topic).Payload) BusError!void {
        return ctx.bus_ptr.publishMsg(ctx.id, topic.channel, msg);
    }

    /// Block for the next envelope on a subscribed channel (`error.Disconnected` once the
    /// bus closes).
    pub fn recv(ctx: *ModuleCtx) BusError!Msg {
        return ctx.rx.recv();
    }

    /// Non-blocking poll of the inbox.
    pub fn tryRecv(ctx: *ModuleCtx) BusError!?Msg {
        return ctx.rx.tryRecv();
    }

    /// Block for at most `timeout_ns` (`null` on timeout) — the loop-friendly receive
    /// that lets a module re-check [`shouldStop`](ModuleCtx.shouldStop) without busy-spinning.
    pub fn recvTimeout(ctx: *ModuleCtx, timeout_ns: u64) BusError!?Msg {
        return ctx.rx.recvTimeout(timeout_ns);
    }

    /// The bus handle, for publishing outside `run`'s loop (e.g. from an offloaded job).
    pub fn bus(ctx: *ModuleCtx) *LocalBus {
        return ctx.bus_ptr;
    }

    /// Run `function(args...)` on the runtime's shared **worker pool** instead of this
    /// module's thread, so the receive loop keeps draining its inbox while the heavy work
    /// happens.
    ///
    /// This is the *receive fast, compute on the pool, publish back* pattern: the loop
    /// does the cheap part and hands the expensive part here; the job captures the
    /// [`bus`](ModuleCtx.bus) handle and publishes its result back onto a channel when it
    /// finishes. The job runs concurrently with — and outlives, if need be — the call, so
    /// its arguments must own everything they reference; an error return is swallowed
    /// (like a caught panic in the Rust pool, it must not take a worker down).
    ///
    /// If the runtime is already shutting down (the pool is closed) the job is dropped.
    pub fn offload(ctx: *ModuleCtx, comptime function: anytype, args: anytype) Allocator.Error!void {
        const Args = @TypeOf(args);
        const Closure = struct {
            args: Args,
            gpa: Allocator,

            fn call(ptr: *anyopaque) void {
                const closure: *@This() = @ptrCast(@alignCast(ptr));
                defer closure.gpa.destroy(closure);
                const ret = @call(.auto, function, closure.args);
                switch (@typeInfo(@TypeOf(ret))) {
                    .error_union => _ = ret catch {},
                    else => {},
                }
            }
        };
        const closure = try ctx.gpa.create(Closure);
        closure.* = .{ .args = args, .gpa = ctx.gpa };
        errdefer ctx.gpa.destroy(closure);
        try ctx.pool.submit(.{ .call = Closure.call, .ctx = closure });
    }
};

// --- the runtime ---------------------------------------------------------------------------

/// What [`Runtime.join`] reports after every module has finished.
pub const JoinReport = struct {
    gpa: Allocator,
    /// Ids of modules whose `run` returned an error (isolated to their own thread; they
    /// triggered shutdown). Owned strings.
    failed: []const []const u8,

    pub fn isClean(r: *const JoinReport) bool {
        return r.failed.len == 0;
    }

    pub fn deinit(r: *JoinReport) void {
        for (r.failed) |id| r.gpa.free(id);
        r.gpa.free(r.failed);
    }
};

/// State shared between the runtime and its module threads (heap-pinned so the `Runtime`
/// value itself can move around freely).
const RuntimeShared = struct {
    gpa: Allocator,
    io: Io,
    flag: std.atomic.Value(bool) = .init(false),
    live: std.atomic.Value(usize) = .init(0),
    mutex: Io.Mutex = .init,
    failed: std.ArrayListUnmanaged([]const u8) = .empty,
};

const Entry = struct {
    module: Module,
    ctx: *ModuleCtx,
    thread: std.Thread,
};

/// The in-process host: owns the [`Shutdown`] signal, the shared worker pool, and the
/// threads of the modules it spawned, over a caller-provided [`LocalBus`].
///
/// The pool exists so a module never has to choose between draining its inbox and doing
/// heavy work (see [`ModuleCtx.offload`]). It is sized from the CPU count and shut down
/// deterministically by [`Runtime.join`] — after the modules stop, the queue closes, the
/// workers drain it and join, leaving no detached threads.
pub const Runtime = struct {
    gpa: Allocator,
    io: Io,
    bus_ptr: *LocalBus,
    shared: *RuntimeShared,
    pool: *WorkerPool,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    /// New runtime over an existing bus — the caller keeps bus ownership (and can publish
    /// or subscribe from outside any module, e.g. the app's main thread).
    pub fn init(gpa: Allocator, io: Io, bus_ptr: *LocalBus) !Runtime {
        const shared = try gpa.create(RuntimeShared);
        errdefer gpa.destroy(shared);
        shared.* = .{ .gpa = gpa, .io = io };
        const pool = try WorkerPool.create(gpa, io);
        return .{ .gpa = gpa, .io = io, .bus_ptr = bus_ptr, .shared = shared, .pool = pool };
    }

    /// The shared bus handle.
    pub fn bus(rt: *Runtime) *LocalBus {
        return rt.bus_ptr;
    }

    /// A copy of the shutdown signal, e.g. to hand to code outside a module.
    pub fn shutdownSignal(rt: *Runtime) Shutdown {
        return .{ .flag = &rt.shared.flag };
    }

    /// How many spawned modules are still running. Drops to zero as modules finish (on
    /// shutdown or failure) — pair it with [`LocalBus.channelMetrics`] for a cheap health
    /// view of a running app.
    pub fn liveCount(rt: *Runtime) usize {
        return rt.shared.live.load(.monotonic);
    }

    /// Ask every module to stop (cooperative — modules observe it via `shouldStop`).
    pub fn shutdown(rt: *Runtime) void {
        rt.shutdownSignal().trigger();
    }

    /// Subscribe a module to its channels and start it on a new thread. If its `run`
    /// returns an error, the module is recorded and shutdown is triggered (fail-fast).
    pub fn spawn(rt: *Runtime, module: Module) !void {
        const ctx = try rt.gpa.create(ModuleCtx);
        errdefer rt.gpa.destroy(ctx);
        const rx = try rt.bus_ptr.subscribeMany(module.vtable.subscriptions(module.ptr));
        ctx.* = .{
            .id = module.vtable.id(module.ptr),
            .gpa = rt.gpa,
            .io = rt.io,
            .bus_ptr = rt.bus_ptr,
            .rx = rx,
            .shutdown = .{ .flag = &rt.shared.flag },
            .pool = rt.pool,
        };
        try rt.entries.ensureUnusedCapacity(rt.gpa, 1);
        _ = rt.shared.live.fetchAdd(1, .monotonic);
        const thread = std.Thread.spawn(.{}, moduleThread, .{ module, ctx, rt.shared }) catch |e| {
            _ = rt.shared.live.fetchSub(1, .monotonic);
            ctx.rx.deinit();
            rt.gpa.destroy(ctx);
            return e;
        };
        rt.entries.appendAssumeCapacity(.{ .module = module, .ctx = ctx, .thread = thread });
    }

    fn moduleThread(module: Module, ctx: *ModuleCtx, shared: *RuntimeShared) void {
        const result = module.vtable.run(module.ptr, ctx);
        if (result) |_| {} else |_| {
            // Fail-fast supervision: record who failed and wind the app down.
            sync.lock(&shared.mutex, shared.io);
            const id_copy = shared.gpa.dupe(u8, ctx.id) catch null;
            if (id_copy) |c| shared.failed.append(shared.gpa, c) catch shared.gpa.free(c);
            sync.unlock(&shared.mutex, shared.io);
            (Shutdown{ .flag = &shared.flag }).trigger();
        }
        // This module is no longer running, however it ended. Unsubscribe now so
        // publishers stop delivering (and prune) promptly.
        ctx.rx.deinit();
        _ = shared.live.fetchSub(1, .monotonic);
    }

    /// Wait for every spawned module to finish, returning which ones failed. Modules exit
    /// when the bus closes or when they observe [`Runtime.shutdown`]. Consumes the
    /// runtime; call `report.deinit()` when done with the result.
    pub fn join(rt: *Runtime) JoinReport {
        for (rt.entries.items) |entry| {
            entry.thread.join();
            if (entry.module.vtable.deinit) |deinitFn| deinitFn(entry.module.ptr, rt.gpa);
            rt.gpa.destroy(entry.ctx);
        }
        rt.entries.deinit(rt.gpa);
        // Modules are done: close the queue, let the workers drain it, join them.
        rt.pool.shutdownAndDestroy();
        const failed = rt.shared.failed.toOwnedSlice(rt.shared.gpa) catch &.{};
        const report: JoinReport = .{ .gpa = rt.gpa, .failed = failed };
        rt.gpa.destroy(rt.shared);
        return report;
    }
};

// --- tests ---------------------------------------------------------------------------------

const testing = std.testing;

const Increment = struct { amount: i64 };
const Count = struct { value: i64 };

/// Publishes five increments on "tick", then returns.
const Ticker = struct {
    pub fn id(_: *Ticker) []const u8 {
        return "ticker";
    }
    pub fn run(_: *Ticker, ctx: *ModuleCtx) anyerror!void {
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            try ctx.publishMsg("tick", Increment{ .amount = 1 });
        }
    }
};

/// Reduces increments from "tick" into a running total republished on "count".
const Store = struct {
    total: i64 = 0,

    pub fn id(_: *Store) []const u8 {
        return "store";
    }
    pub fn subscriptions(_: *Store) []const []const u8 {
        return &.{"tick"};
    }
    pub fn run(self: *Store, ctx: *ModuleCtx) anyerror!void {
        while (!ctx.shouldStop()) {
            const msg = (try ctx.recvTimeout(20 * std.time.ns_per_ms)) orelse continue;
            defer msg.deinit();
            const parsed = try msg.env().decode(Increment, ctx.gpa);
            defer parsed.deinit();
            self.total += parsed.value.amount;
            try ctx.publishMsg("count", Count{ .value = self.total });
        }
    }
};

test "modules drive a document over the bus" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bus_ = LocalBus.init(testing.allocator, io);
    defer bus_.deinit();
    try bus_.retain("count");

    var rt = try Runtime.init(testing.allocator, io, &bus_);
    var counts = try bus_.subscribe("count");
    defer counts.deinit();

    var store: Store = .{};
    try rt.spawn(Module.of(Store, &store));
    var ticker: Ticker = .{};
    try rt.spawn(Module.of(Ticker, &ticker));

    var seen: [5]i64 = undefined;
    for (&seen) |*slot| {
        const msg = try counts.recv();
        defer msg.deinit();
        const parsed = try msg.env().decode(Count, testing.allocator);
        defer parsed.deinit();
        slot.* = parsed.value.value;
    }
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3, 4, 5 }, &seen);

    rt.shutdown();
    var report = rt.join();
    defer report.deinit();
    try testing.expect(report.isClean());

    // The retained "count" still replays the final state to a late joiner.
    var late = try bus_.subscribe("count");
    defer late.deinit();
    const msg = try late.recv();
    defer msg.deinit();
    const parsed = try msg.env().decode(Count, testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 5), parsed.value.value);
}

const Waiter = struct {
    pub fn id(_: *Waiter) []const u8 {
        return "waiter";
    }
    pub fn subscriptions(_: *Waiter) []const []const u8 {
        return &.{"nothing-ever-comes"};
    }
    pub fn run(_: *Waiter, ctx: *ModuleCtx) anyerror!void {
        while (!ctx.shouldStop()) {
            _ = try ctx.recvTimeout(10 * std.time.ns_per_ms);
        }
    }
};

test "shutdown stops a long lived module" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bus_ = LocalBus.init(testing.allocator, io);
    defer bus_.deinit();
    var rt = try Runtime.init(testing.allocator, io, &bus_);

    var waiter: Waiter = .{};
    try rt.spawn(Module.of(Waiter, &waiter));
    sync.sleepNs(io, 30 * std.time.ns_per_ms);

    rt.shutdown();
    var report = rt.join();
    defer report.deinit();
    try testing.expect(report.isClean());
}

const Bomb = struct {
    pub fn id(_: *Bomb) []const u8 {
        return "bomb";
    }
    pub fn run(_: *Bomb, _: *ModuleCtx) anyerror!void {
        return error.Boom;
    }
};

test "module failure is isolated and reported" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bus_ = LocalBus.init(testing.allocator, io);
    defer bus_.deinit();
    var rt = try Runtime.init(testing.allocator, io, &bus_);
    const sig = rt.shutdownSignal();

    var waiter: Waiter = .{};
    try rt.spawn(Module.of(Waiter, &waiter));
    var bomb: Bomb = .{};
    try rt.spawn(Module.of(Bomb, &bomb));

    var report = rt.join();
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.failed.len);
    try testing.expectEqualStrings("bomb", report.failed[0]);
    _ = sig; // the flag lives in rt.shared, freed by join — checked implicitly by join returning
}

fn bumpJob(done: *std.atomic.Value(usize)) void {
    _ = done.fetchAdd(1, .acq_rel);
}

const Spammer = struct {
    done: *std.atomic.Value(usize),

    pub fn id(_: *Spammer) []const u8 {
        return "spammer";
    }
    pub fn run(self: *Spammer, ctx: *ModuleCtx) anyerror!void {
        // Queue a burst of jobs, then return immediately: join must still drain them all.
        var i: usize = 0;
        while (i < 200) : (i += 1) {
            try ctx.offload(bumpJob, .{self.done});
        }
    }
};

test "pool drains queued jobs and shuts down cleanly" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bus_ = LocalBus.init(testing.allocator, io);
    defer bus_.deinit();
    var rt = try Runtime.init(testing.allocator, io, &bus_);

    var done: std.atomic.Value(usize) = .init(0);
    var spammer: Spammer = .{ .done = &done };
    try rt.spawn(Module.of(Spammer, &spammer));

    var report = rt.join();
    defer report.deinit();
    try testing.expect(report.isClean());
    try testing.expectEqual(@as(usize, 200), done.load(.acquire));
}

fn failingJob(done: *std.atomic.Value(usize)) anyerror!void {
    _ = done.fetchAdd(1, .acq_rel);
    return error.JobFailed;
}

const OneShot = struct {
    done: *std.atomic.Value(usize),

    pub fn id(_: *OneShot) []const u8 {
        return "oneshot";
    }
    pub fn run(self: *OneShot, ctx: *ModuleCtx) anyerror!void {
        try ctx.offload(failingJob, .{self.done});
    }
};

test "a failing job does not poison the pool" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var bus_ = LocalBus.init(testing.allocator, io);
    defer bus_.deinit();
    var rt = try Runtime.init(testing.allocator, io, &bus_);

    var done: std.atomic.Value(usize) = .init(0);
    var oneshot: OneShot = .{ .done = &done };
    try rt.spawn(Module.of(OneShot, &oneshot));

    var report = rt.join();
    defer report.deinit();
    try testing.expect(report.isClean());
    try testing.expectEqual(@as(usize, 1), done.load(.acquire));
}
