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
const hooks = @import("hooks.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const sync = @import("sync.zig");
const protocol = @import("protocol.zig");
const bus_mod = @import("bus.zig");
const worker_pool = @import("worker_pool.zig");
const WorkerPool = worker_pool.WorkerPool;

pub const LocalBus = bus_mod.LocalBus;
pub const Receiver = bus_mod.Receiver;
pub const Msg = bus_mod.Msg;
pub const BusError = bus_mod.BusError;
pub const Envelope = protocol.Envelope;
pub const Channel = protocol.Channel;
pub const ModuleId = protocol.ModuleId;
pub const Topic = protocol.Topic;

/// A cooperative shutdown signal shared by the runtime, every module, and any code outside
/// the runtime that holds a handle.
///
/// ## Ownership
/// The flag lives in its own reference-counted control block, independent of the
/// [`Runtime`]: the runtime holds one reference, each module context holds one, and every
/// handle obtained from [`Runtime.shutdownSignal`] or [`clone`](Shutdown.clone) holds one.
/// The block is freed when the LAST reference is released, so a handle that outlives the
/// runtime (retained across `join`, even across `Runtime.deinit`) stays valid: `trigger`
/// on it is a harmless no-op from the runtime's point of view, never a write into freed
/// memory.
///
/// A plain struct copy (`const s2 = s;`) is a *borrow*, not a new reference — exactly like
/// copying an `ArrayList`. Anything that keeps a handle beyond the scope that gave it to
/// you must call [`clone`](Shutdown.clone) and later [`deinit`](Shutdown.deinit); a
/// forgotten `deinit` is a leak the testing allocator reports, never a dangling pointer.
///
/// `isTriggered`/`trigger` are lock-free and safe from any thread; `clone`/`deinit` are too.
/// The hot path (`isTriggered`, called by every module loop) is a single acquire load.
pub const Shutdown = struct {
    state: *State,

    const State = struct {
        flag: std.atomic.Value(bool) = .init(false),
        refs: sync.RefCount = .init(1),
        gpa: Allocator,
    };

    /// A fresh signal holding one reference (released by [`deinit`](Shutdown.deinit)).
    pub fn create(gpa: Allocator) Allocator.Error!Shutdown {
        const state = try gpa.create(State);
        state.* = .{ .gpa = gpa };
        return .{ .state = state };
    }

    /// Whether shutdown has been requested.
    pub fn isTriggered(s: Shutdown) bool {
        return s.state.flag.load(.acquire);
    }

    /// Request shutdown. Idempotent.
    pub fn trigger(s: Shutdown) void {
        s.state.flag.store(true, .release);
    }

    /// A new owning reference to the same signal. Release it with [`deinit`](Shutdown.deinit).
    pub fn clone(s: Shutdown) Shutdown {
        s.state.refs.retain();
        return .{ .state = s.state };
    }

    /// Release this reference; the control block is freed with the last one. The handle
    /// must not be used afterwards.
    pub fn deinit(s: *Shutdown) void {
        if (s.state.refs.release()) s.state.gpa.destroy(s.state);
        s.* = undefined;
    }
};

// --- the module interface --------------------------------------------------------------

/// A unit of behaviour hosted by the [`Runtime`]: a type-erased instance + vtable.
///
/// Implement a plain struct with (every method `pub` — a non-`pub` optional hook is
/// silently skipped by reflection since Zig 0.17, see hooks.zig):
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
                if (comptime hooks.has(T, "subscriptions")) {
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
                if (comptime hooks.has(T, "deinit")) self.deinit();
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

// --- the module context ------------------------------------------------------------------

/// What a module gets to talk to the world: its identity, a handle to publish, the merged
/// inbox of its subscribed channels, the shared shutdown signal, and the runtime's worker
/// pool for offloading heavy work off its receive loop.
///
/// ## Lifetime
/// The runtime keeps a context alive until [`Runtime.join`] has (1) joined the module's
/// thread and (2) drained the worker pool — so a job offloaded by this module may keep
/// using the context (and the module instance) until it finishes. Nothing may use it after
/// `join` returns.
pub const ModuleCtx = struct {
    id: []const u8,
    gpa: Allocator,
    io: Io,
    bus_ptr: *LocalBus,
    rx: Receiver,
    /// Owned by the context (one reference, released by `join`). Borrow it freely while
    /// the context is alive; [`Shutdown.clone`] it to keep a handle beyond that.
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
    /// A job the pool **accepted** always runs, even across shutdown: `join` drains the
    /// queue before tearing anything down. A job it did **not** accept is reported, never
    /// dropped silently: `error.PoolClosed` once `join` has closed the pool (only an
    /// offloaded job can still be running then, offloading a follow-up), `error.QueueFull`
    /// when the backlog is at the pool's bound (see [`WorkerPool.Options`]). On any error
    /// the job has not run and will not run; its arguments are dropped with it.
    pub fn offload(ctx: *ModuleCtx, comptime function: anytype, args: anytype) OffloadError!void {
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
        // A rejected job is never run, so Closure.call's deferred destroy never fires:
        // reclaim the closure here.
        errdefer ctx.gpa.destroy(closure);
        try ctx.pool.submit(.{ .call = Closure.call, .ctx = closure });
    }
};

/// Why [`ModuleCtx.offload`] did not accept a job.
pub const OffloadError = worker_pool.SubmitError;

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
/// value itself can move around freely). Lives until [`Runtime.deinit`]; nothing outside
/// the runtime ever holds a pointer to it (escaping handles are [`Shutdown`]s, which own
/// their own control block).
const RuntimeShared = struct {
    gpa: Allocator,
    io: Io,
    live: std.atomic.Value(usize) = .init(0),
    mutex: Io.Mutex = .init,
    failed: std.ArrayListUnmanaged([]const u8) = .empty,
};

const Entry = struct {
    module: Module,
    ctx: *ModuleCtx,
    thread: std.Thread,
};

/// Tuning for [`Runtime.initOptions`].
pub const Options = struct {
    /// The worker pool (see [`ModuleCtx.offload`]).
    pool: WorkerPool.Options = .{},
};

/// Why [`Runtime.spawn`] refused a module.
pub const SpawnError = error{
    /// Shutdown was requested, or the runtime was already joined or deinitialized: no
    /// module may start once winding down has begun.
    RuntimeStopped,
} || Allocator.Error || BusError || std.Thread.SpawnError;

/// The in-process host: owns the [`Shutdown`] signal, the shared worker pool, and the
/// threads of the modules it spawned, over a caller-provided [`LocalBus`].
///
/// The pool exists so a module never has to choose between draining its inbox and doing
/// heavy work (see [`ModuleCtx.offload`]). It is sized from the CPU count and shut down
/// deterministically by [`Runtime.join`] — after the modules stop, the queue closes, the
/// workers drain it and join, leaving no detached threads.
///
/// ## Lifecycle
/// ```text
///   running ──shutdown()──▶ stopping ──join()──▶ joined ──deinit()──▶ deinitialized
///      └───────────────────────join()──────────────▲
/// ```
/// * [`shutdown`](Runtime.shutdown) — request stop. Idempotent; a no-op once joined or
///   deinitialized. Never touches freed memory.
/// * [`join`](Runtime.join) — wait for every module, then drain the pool, then release
///   module contexts and owned instances, in that order. Idempotent: a second call
///   returns an empty report.
/// * [`spawn`](Runtime.spawn) — only while `running`; otherwise `error.RuntimeStopped`.
///   All-or-nothing: on any error nothing is left registered.
/// * [`deinit`](Runtime.deinit) — final destruction. Joins first if the caller did not
///   (after requesting shutdown, so it cannot hang on a well-behaved module).
///
/// ## Threads
/// The `Runtime` value has ONE owner: call its methods from one thread at a time (the
/// owner's). To stop the runtime from another thread — a signal handler, a UI thread — give
/// that thread its own handle from [`shutdownSignal`](Runtime.shutdownSignal): handles are
/// thread-safe and outlive the runtime safely.
pub const Runtime = struct {
    gpa: Allocator,
    io: Io,
    bus_ptr: *LocalBus,
    shared: *RuntimeShared,
    pool: *WorkerPool,
    signal: Shutdown,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    phase: Phase = .running,

    /// Owner-side lifecycle position. `stopping` is not stored: it is `running` with the
    /// shutdown signal triggered (the signal can be triggered from any thread, so it is the
    /// single source of truth for "stop requested").
    const Phase = enum { running, joined, deinitialized };

    /// Where the runtime is in its lifecycle (see the type's doc).
    pub const State = enum { running, stopping, joined, deinitialized };

    /// New runtime over an existing bus — the caller keeps bus ownership (and can publish
    /// or subscribe from outside any module, e.g. the app's main thread).
    pub fn init(gpa: Allocator, io: Io, bus_ptr: *LocalBus) !Runtime {
        return initOptions(gpa, io, bus_ptr, .{});
    }

    /// [`init`](Runtime.init) with explicit tuning.
    pub fn initOptions(gpa: Allocator, io: Io, bus_ptr: *LocalBus, options: Options) !Runtime {
        const shared = try gpa.create(RuntimeShared);
        errdefer gpa.destroy(shared);
        shared.* = .{ .gpa = gpa, .io = io };
        var signal = try Shutdown.create(gpa);
        errdefer signal.deinit();
        const pool = try WorkerPool.create(gpa, io, options.pool);
        return .{ .gpa = gpa, .io = io, .bus_ptr = bus_ptr, .shared = shared, .pool = pool, .signal = signal };
    }

    /// The shared bus handle.
    pub fn bus(rt: *Runtime) *LocalBus {
        return rt.bus_ptr;
    }

    /// The current lifecycle state.
    pub fn state(rt: *const Runtime) State {
        return switch (rt.phase) {
            .running => if (rt.signal.isTriggered()) .stopping else .running,
            .joined => .joined,
            .deinitialized => .deinitialized,
        };
    }

    /// A new **owning** handle on the shutdown signal, e.g. to hand to code outside a
    /// module or to another thread. The caller must `deinit()` it; it stays valid (and
    /// safe to `trigger`) for as long as the caller holds it, regardless of what happens
    /// to the runtime. Asserts the runtime is not deinitialized.
    pub fn shutdownSignal(rt: *Runtime) Shutdown {
        std.debug.assert(rt.phase != .deinitialized);
        return rt.signal.clone();
    }

    /// How many spawned modules are still running. Drops to zero as modules finish (on
    /// shutdown or failure) — pair it with [`LocalBus.channelMetrics`] for a cheap health
    /// view of a running app. Always 0 once joined.
    pub fn liveCount(rt: *Runtime) usize {
        if (rt.phase != .running) return 0;
        return rt.shared.live.load(.monotonic);
    }

    /// Ask every module to stop (cooperative — modules observe it via `shouldStop`).
    /// Idempotent; a no-op after `join`/`deinit`.
    pub fn shutdown(rt: *Runtime) void {
        if (rt.phase != .running) return;
        rt.signal.trigger();
    }

    /// Subscribe a module to its channels and start it on a new thread. If its `run`
    /// returns an error, the module is recorded and shutdown is triggered (fail-fast).
    ///
    /// Refused with `error.RuntimeStopped` once shutdown was requested (or after
    /// `join`/`deinit`). Transactional: on ANY error the module is not registered, holds
    /// no subscription, and the runtime is exactly as before the call. A borrowed
    /// instance stays the caller's; an owned one (`Module.ofOwned`) also stays the
    /// caller's to free on error.
    pub fn spawn(rt: *Runtime, module: Module) SpawnError!void {
        if (rt.phase != .running or rt.signal.isTriggered()) return error.RuntimeStopped;

        // Everything fallible first, each step undone by the ones after it failing; the
        // final append cannot fail (capacity reserved up front).
        try rt.entries.ensureUnusedCapacity(rt.gpa, 1);
        const ctx = try rt.gpa.create(ModuleCtx);
        errdefer rt.gpa.destroy(ctx);
        var rx = try rt.bus_ptr.subscribeMany(module.vtable.subscriptions(module.ptr));
        errdefer rx.deinit();
        var signal = rt.signal.clone();
        errdefer signal.deinit();
        ctx.* = .{
            .id = module.vtable.id(module.ptr),
            .gpa = rt.gpa,
            .io = rt.io,
            .bus_ptr = rt.bus_ptr,
            .rx = rx,
            .shutdown = signal,
            .pool = rt.pool,
        };
        _ = rt.shared.live.fetchAdd(1, .monotonic);
        errdefer _ = rt.shared.live.fetchSub(1, .monotonic);
        const thread = try std.Thread.spawn(.{}, moduleThread, .{ module, ctx, rt.shared });
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
            ctx.shutdown.trigger();
        }
        // This module is no longer running, however it ended. Unsubscribe now so
        // publishers stop delivering (and prune) promptly.
        ctx.rx.deinit();
        _ = shared.live.fetchSub(1, .monotonic);
    }

    /// Wait for every spawned module to finish, returning which ones failed. Modules exit
    /// when the bus closes or when they observe [`Runtime.shutdown`]; `join` itself does
    /// not request shutdown (a runtime of finite modules may be joined while running).
    ///
    /// Teardown order — each step only starts once nothing can depend on the previous one:
    /// 1. join every module thread (no module code runs any more, so nothing new can be
    ///    offloaded by a module);
    /// 2. close the worker pool and DRAIN it: every accepted job runs to completion, while
    ///    the module contexts and instances it may reference are still alive (a job that
    ///    offloads a follow-up now gets `error.PoolClosed`);
    /// 3. only then release the contexts and call owned modules' `deinit`.
    ///
    /// Idempotent: a second call (or a call after `deinit`) returns an empty report.
    /// Call `report.deinit()` when done with the result.
    pub fn join(rt: *Runtime) JoinReport {
        if (rt.phase != .running) return .{ .gpa = rt.gpa, .failed = &.{} };

        rt.bus_ptr.notifyAllInboxes(); // wake modules blocked in recvTimeout(); modules check shouldStop()
        for (rt.entries.items) |entry| entry.thread.join();
        rt.pool.shutdownAndDestroy();
        for (rt.entries.items) |entry| {
            if (entry.module.vtable.deinit) |deinitFn| deinitFn(entry.module.ptr, rt.gpa);
            entry.ctx.shutdown.deinit();
            rt.gpa.destroy(entry.ctx);
        }
        rt.entries.deinit(rt.gpa);
        rt.entries = .empty;
        rt.phase = .joined;

        // Every module thread is gone: `failed` is ours alone now.
        const failed = rt.shared.failed.toOwnedSlice(rt.gpa) catch blk: {
            for (rt.shared.failed.items) |id| rt.gpa.free(id);
            rt.shared.failed.deinit(rt.gpa);
            rt.shared.failed = .empty;
            break :blk &.{};
        };
        return .{ .gpa = rt.gpa, .failed = failed };
    }

    /// Final destruction. If the runtime was not joined yet, requests shutdown and joins
    /// it first (discarding the report). Outstanding [`Shutdown`] handles stay valid —
    /// they own their control block. Idempotent; the value must not be used afterwards
    /// except for further no-op `shutdown`/`join`/`deinit` calls and `state()`.
    pub fn deinit(rt: *Runtime) void {
        if (rt.phase == .deinitialized) return;
        if (rt.phase == .running) {
            rt.shutdown();
            var report = rt.join();
            report.deinit();
        }
        rt.gpa.destroy(rt.shared);
        rt.signal.deinit();
        rt.* = .{
            .gpa = rt.gpa,
            .io = rt.io,
            .bus_ptr = rt.bus_ptr,
            .shared = undefined,
            .pool = undefined,
            .signal = undefined,
            .phase = .deinitialized,
        };
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
    defer rt.deinit();

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
    defer rt.deinit();

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
    defer rt.deinit();
    var sig = rt.shutdownSignal(); // an owning handle: valid across join, released below
    defer sig.deinit();

    var waiter: Waiter = .{};
    try rt.spawn(Module.of(Waiter, &waiter));
    var bomb: Bomb = .{};
    try rt.spawn(Module.of(Bomb, &bomb));

    var report = rt.join();
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.failed.len);
    try testing.expectEqualStrings("bomb", report.failed[0]);
    // The bomb tripped the shared signal (fail-fast), and the handle still reads it after
    // join — it owns its control block (this read was a use-after-free before).
    try testing.expect(sig.isTriggered());
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
    defer rt.deinit();

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
    defer rt.deinit();

    var done: std.atomic.Value(usize) = .init(0);
    var oneshot: OneShot = .{ .done = &done };
    try rt.spawn(Module.of(OneShot, &oneshot));

    var report = rt.join();
    defer report.deinit();
    try testing.expect(report.isClean());
    try testing.expectEqual(@as(usize, 1), done.load(.acquire));
}

// --- lifecycle regression tests ------------------------------------------------------------
//
// Each scenario runs twice: under `std.heap.page_allocator`, where every free unmaps its
// page, so a use-after-free is a deterministic SEGFAULT instead of a silent read of a
// recycled block (the original `join()` → `shutdown()` bug was invisible to the GPA until
// 0.17 happened to recycle it); and under `testing.allocator`, which reports leaks — the
// check that every reference (contexts, signal handles, subscriptions) is released.

fn lifecycleCase(comptime body: fn (*Runtime, Io) anyerror!void) !void {
    inline for (.{ std.heap.page_allocator, testing.allocator }) |gpa| {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var bus_ = LocalBus.init(gpa, io);
        defer bus_.deinit();
        var rt = try Runtime.initOptions(gpa, io, &bus_, .{ .pool = .{ .threads = 2 } });
        defer rt.deinit();
        try body(&rt, io);
    }
}

test "lifecycle: shutdown after join (was a use-after-free segfault)" {
    try lifecycleCase(struct {
        fn body(rt: *Runtime, _: Io) !void {
            var report = rt.join();
            report.deinit();
            rt.shutdown(); // wrote into the freed `shared` block before the fix
            rt.shutdown();
            try testing.expectEqual(Runtime.State.joined, rt.state());
            try testing.expectEqual(@as(usize, 0), rt.liveCount());
        }
    }.body);
}

test "lifecycle: double shutdown, then join" {
    try lifecycleCase(struct {
        fn body(rt: *Runtime, _: Io) !void {
            var waiter: Waiter = .{};
            try rt.spawn(Module.of(Waiter, &waiter));
            rt.shutdown();
            rt.shutdown();
            try testing.expectEqual(Runtime.State.stopping, rt.state());
            var report = rt.join();
            defer report.deinit();
            try testing.expect(report.isClean());
        }
    }.body);
}

test "lifecycle: double join returns an empty second report" {
    try lifecycleCase(struct {
        fn body(rt: *Runtime, _: Io) !void {
            var bomb: Bomb = .{};
            try rt.spawn(Module.of(Bomb, &bomb));
            var first = rt.join();
            defer first.deinit();
            try testing.expectEqual(@as(usize, 1), first.failed.len);
            var second = rt.join(); // iterated the freed entry list before the fix
            defer second.deinit();
            try testing.expect(second.isClean());
        }
    }.body);
}

test "lifecycle: spawn is refused once shutdown began, and after join" {
    try lifecycleCase(struct {
        fn body(rt: *Runtime, _: Io) !void {
            var waiter: Waiter = .{};
            // Requested through an outside handle, as a UI thread would.
            var handle = rt.shutdownSignal();
            defer handle.deinit();
            handle.trigger();
            try testing.expectError(error.RuntimeStopped, rt.spawn(Module.of(Waiter, &waiter)));
            try testing.expectEqual(@as(usize, 0), rt.liveCount());
            var report = rt.join();
            report.deinit();
            // After join the pool is gone: this used the destroyed pool before the fix.
            try testing.expectError(error.RuntimeStopped, rt.spawn(Module.of(Waiter, &waiter)));
        }
    }.body);
}

test "lifecycle: every call after deinit is a defined no-op" {
    try lifecycleCase(struct {
        fn body(rt: *Runtime, _: Io) !void {
            var waiter: Waiter = .{};
            try rt.spawn(Module.of(Waiter, &waiter));
            rt.deinit(); // not joined: deinit requests shutdown and joins itself
            try testing.expectEqual(Runtime.State.deinitialized, rt.state());
            rt.shutdown();
            var report = rt.join();
            defer report.deinit();
            try testing.expect(report.isClean());
            try testing.expectError(error.RuntimeStopped, rt.spawn(Module.of(Waiter, &waiter)));
            rt.deinit(); // the helper's deferred deinit is a third one
        }
    }.body);
}

test "lifecycle: shutdown handles outlive join and deinit, any number of copies" {
    inline for (.{ std.heap.page_allocator, testing.allocator }) |gpa| {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var bus_ = LocalBus.init(gpa, io);
        defer bus_.deinit();
        var rt = try Runtime.init(gpa, io, &bus_);

        var handles: [8]Shutdown = undefined;
        handles[0] = rt.shutdownSignal();
        for (handles[1..]) |*h| h.* = handles[0].clone();

        var waiter: Waiter = .{};
        try rt.spawn(Module.of(Waiter, &waiter));
        handles[3].trigger(); // any copy stops the runtime
        var report = rt.join();
        report.deinit();
        rt.deinit(); // the runtime's own reference is gone; the handles keep the block

        for (handles) |h| try testing.expect(h.isTriggered());
        handles[5].trigger(); // harmless after the runtime is gone
        // Released out of order; the LAST release frees the block (testing.allocator
        // would report a leak otherwise, page_allocator a fault on early free).
        for ([_]usize{ 2, 7, 0, 5, 1, 6, 3, 4 }) |i| handles[i].deinit();
    }
}

test "lifecycle: concurrent shutdown requests from many threads" {
    for (0..25) |_| {
        try lifecycleCase(struct {
            fn trig(handle: Shutdown, go: *std.atomic.Value(bool)) void {
                var h = handle;
                defer h.deinit();
                while (!go.load(.acquire)) std.atomic.spinLoopHint();
                h.trigger();
                h.trigger();
            }
            fn body(rt: *Runtime, _: Io) !void {
                var waiter: Waiter = .{};
                try rt.spawn(Module.of(Waiter, &waiter));
                var go: std.atomic.Value(bool) = .init(false);
                var threads: [8]std.Thread = undefined;
                for (&threads) |*t| t.* = try std.Thread.spawn(.{}, trig, .{ rt.shutdownSignal(), &go });
                go.store(true, .release);
                rt.shutdown(); // the owner races the outside handles
                var report = rt.join();
                defer report.deinit();
                for (threads) |t| t.join();
                try testing.expect(report.isClean());
                try testing.expectEqual(Runtime.State.joined, rt.state());
            }
        }.body);
    }
}

/// Shared between an owned module, the job it offloads and the test driving both.
const DrainProbe = struct {
    gate: std.atomic.Value(bool) = .init(false),
    job_started: std.atomic.Value(bool) = .init(false),
    job_done: std.atomic.Value(bool) = .init(false),
    ctx_alive: std.atomic.Value(bool) = .init(false),
    followup_closed: std.atomic.Value(bool) = .init(false),
    deinit_before_job: std.atomic.Value(bool) = .init(false),
    deinited: std.atomic.Value(bool) = .init(false),
};

fn noopJob() void {}

/// An OWNED module that offloads one slow job capturing both its context and itself.
const Offloader = struct {
    probe: *DrainProbe,

    pub fn id(_: *Offloader) []const u8 {
        return "offloader";
    }
    pub fn run(self: *Offloader, ctx: *ModuleCtx) anyerror!void {
        try ctx.offload(slowJob, .{ ctx, self });
    }
    pub fn deinit(self: *Offloader) void {
        if (!self.probe.job_done.load(.acquire)) self.probe.deinit_before_job.store(true, .release);
        self.probe.deinited.store(true, .release);
    }

    fn slowJob(ctx: *ModuleCtx, self: *Offloader) void {
        const probe = self.probe; // a freed `self` faults here under page_allocator
        probe.job_started.store(true, .release);
        while (!probe.gate.load(.acquire)) std.atomic.spinLoopHint();
        // join is now tearing down: the context must still be alive...
        probe.ctx_alive.store(std.mem.eql(u8, ctx.id, "offloader") and ctx.shouldStop() == ctx.shutdown.isTriggered(), .release);
        // ...and a follow-up is refused loudly, not dropped silently.
        if (ctx.offload(noopJob, .{})) |_| {} else |e| probe.followup_closed.store(e == error.PoolClosed, .release);
        probe.job_done.store(true, .release);
    }
};

test "lifecycle: join drains running jobs before releasing contexts and owned modules" {
    inline for (.{ std.heap.page_allocator, testing.allocator }) |gpa| {
        var threaded: std.Io.Threaded = .init(gpa, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var bus_ = LocalBus.init(gpa, io);
        defer bus_.deinit();
        var rt = try Runtime.initOptions(gpa, io, &bus_, .{ .pool = .{ .threads = 1 } });
        defer rt.deinit();

        var probe: DrainProbe = .{};
        const instance = try gpa.create(Offloader);
        instance.* = .{ .probe = &probe };
        try rt.spawn(Module.ofOwned(Offloader, instance));

        // Open the gate only once join has closed the pool — i.e. while it is tearing
        // down. Under the old order (contexts and instances destroyed right after the
        // module threads joined) the job would now touch freed memory.
        const Opener = struct {
            fn run(pool: *WorkerPool, p: *DrainProbe) void {
                while (!p.job_started.load(.acquire)) std.atomic.spinLoopHint();
                while (true) {
                    sync.lock(&pool.mutex, pool.io);
                    const closed = pool.closed;
                    sync.unlock(&pool.mutex, pool.io);
                    if (closed) break;
                    std.atomic.spinLoopHint();
                }
                p.gate.store(true, .release);
            }
        };
        const opener = try std.Thread.spawn(.{}, Opener.run, .{ rt.pool, &probe });

        var report = rt.join(); // blocks until the job finished
        defer report.deinit();
        opener.join();
        try testing.expect(report.isClean());
        try testing.expect(probe.job_done.load(.acquire));
        try testing.expect(probe.ctx_alive.load(.acquire));
        try testing.expect(probe.followup_closed.load(.acquire));
        try testing.expect(probe.deinited.load(.acquire));
        try testing.expect(!probe.deinit_before_job.load(.acquire));
    }
}

test "lifecycle: a refused spawn leaves nothing behind, at every allocation failure" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var spawned = false;
    var refused: usize = 0;
    var fail_index: usize = 0;
    while (!spawned) : (fail_index += 1) {
        // The bus allocates with its own allocator, so subscription memory is what a
        // leaked receiver would strand — testing.allocator reports it at the end.
        var bus_ = LocalBus.init(testing.allocator, io);
        defer bus_.deinit();
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var rt = Runtime.initOptions(failing.allocator(), io, &bus_, .{ .pool = .{ .threads = 1 } }) catch continue;
        defer rt.deinit();

        var waiter: Waiter = .{};
        if (rt.spawn(Module.of(Waiter, &waiter))) |_| {
            spawned = true;
        } else |e| {
            try testing.expectEqual(error.OutOfMemory, e);
            refused += 1;
            try testing.expectEqual(@as(usize, 0), rt.entries.items.len);
            try testing.expectEqual(@as(usize, 0), rt.liveCount());
            // The runtime is still fully usable after the refusal.
            try testing.expectEqual(Runtime.State.running, rt.state());
        }
        rt.shutdown();
        var report = rt.join();
        report.deinit();
    }
    try testing.expect(refused > 0);
}
