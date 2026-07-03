//! # zicro.app — the `sources → world → sinks` composition layer
//!
//! The zicro kernel (bus, core, document) is deliberately generic: everything is just a
//! [`Module`](core.Module) talking over string-named channels. This file adds the one
//! *opinion* that turns that kernel into a framework — a single, documented dataflow
//! spine:
//!
//! ```text
//! sources  ──actions──▶  world  ──state (retained)──▶  sinks
//! (input,               (Doc(S,A))                      (video, audio, ui)
//!  midi-in,             the only stateful node          stateless, read the state
//!  clock, net)          dispatch + undo/redo            render it
//! ```
//!
//! * **Sources** publish *actions* (and events) onto the bus; they own no shared state.
//! * The **world** is the single stateful node: a [`WorldModule`] wraps a
//!   [`Doc(S,A)`](document.Doc), applies each incoming action through the reducer, and
//!   republishes the new state on a **retained** channel.
//! * **Sinks** subscribe to the world's state (and events) and render it; they never
//!   mutate shared state and never talk to a source or another sink directly.
//!
//! [`App`] is a thin builder over [`Runtime`](core.Runtime) that makes this shape the
//! path of least resistance: [`App.world`] spawns the world *and* marks its state
//! channel retained in one call, and [`App.source`] / [`App.sink`] are intent-named
//! spawns so a `main` reads like the diagram above. Nothing here is new transport — it
//! is all the existing kernel, wired with a convention.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const bus_mod = @import("bus.zig");
const core = @import("core.zig");
const document = @import("document.zig");

/// A [`Module`](core.Module) that owns a [`Doc(S,A)`](document.Doc) and exposes it on the
/// bus as the world node: actions in on one channel, state snapshots out on another.
///
/// Build one directly and hand it to [`App.spawn`], or — preferred — let [`App.world`]
/// construct and wire it (it also marks the state channel retained, which is the
/// invariant that makes late sinks re-sync).
pub fn WorldModule(comptime S: type, comptime A: type) type {
    return struct {
        id_: []const u8,
        actions: []const u8,
        state: []const u8,
        doc: document.Doc(S, A),
        subs_buf: [1][]const u8 = undefined,

        const Self = @This();

        /// New world node: `actions` is the channel it reduces, `state` the channel it
        /// republishes the document's state on after every committed action.
        pub fn init(id_: []const u8, actions: []const u8, state: []const u8, doc: document.Doc(S, A)) Self {
            return .{ .id_ = id_, .actions = actions, .state = state, .doc = doc };
        }

        pub fn id(self: *Self) []const u8 {
            return self.id_;
        }

        pub fn subscriptions(self: *Self) []const []const u8 {
            self.subs_buf[0] = self.actions;
            return &self.subs_buf;
        }

        pub fn run(self: *Self, ctx: *core.ModuleCtx) anyerror!void {
            defer self.doc.deinit();

            // Publish the initial snapshot so a sink that subscribes later (the state
            // channel is retained by the App) re-syncs to the starting state immediately.
            ctx.publishMsg(self.state, self.doc.state().*) catch {};

            while (!ctx.shouldStop()) {
                // A receive error means the bus closed: nothing more can arrive.
                const maybe_msg = ctx.recvTimeout(50 * std.time.ns_per_ms) catch break;
                const msg = maybe_msg orelse continue;
                defer msg.deinit();
                // An envelope on the actions channel whose payload isn't our action shape
                // is simply ignored — the world only knows how to reduce `A`.
                const parsed = msg.env().decode(A, ctx.gpa) catch continue;
                defer parsed.deinit();
                // Transactional: a rejected action leaves the document untouched and
                // republishes nothing, so sinks only ever see committed state.
                self.doc.dispatch(&parsed.value) catch continue;
                ctx.publishMsg(self.state, self.doc.state().*) catch {};
            }
        }
    };
}

/// A thin builder over [`Runtime`](core.Runtime) that wires modules and channels in one
/// place, so an app's `main` reads like the dataflow it implements.
///
/// The kernel already lets any module publish/subscribe on any channel; `App` only adds
/// convenience and intent:
/// * [`App.retain`] / [`App.overflow`] declare channel behaviour up front (before
///   anything publishes), instead of scattering `bus.retain(...)` calls.
/// * [`App.source`] / [`App.sink`] are intent-named [`spawn`](App.spawn)s — identical at
///   runtime, but they make the wiring self-documenting.
/// * [`App.world`] builds a [`WorldModule`] from a [`Doc`](document.Doc) *and* marks its
///   state channel retained, enforcing the "world state is durable" invariant in one call.
pub const App = struct {
    gpa: Allocator,
    io: Io,
    bus_ptr: *bus_mod.LocalBus,
    rt: core.Runtime,
    joined: bool = false,

    /// New app with a fresh bus and runtime.
    pub fn init(gpa: Allocator, io: Io) !App {
        const bus_ptr = try gpa.create(bus_mod.LocalBus);
        errdefer gpa.destroy(bus_ptr);
        bus_ptr.* = bus_mod.LocalBus.init(gpa, io);
        const rt = try core.Runtime.init(gpa, io, bus_ptr);
        return .{ .gpa = gpa, .io = io, .bus_ptr = bus_ptr, .rt = rt };
    }

    /// Free the bus. Call after [`App.join`] / [`App.shutdownAndJoin`] (receivers handed
    /// out by [`bus`](App.bus) stay valid — they only go quiet).
    pub fn deinit(app: *App) void {
        app.bus_ptr.deinit();
        app.gpa.destroy(app.bus_ptr);
    }

    /// The bus handle, for code outside a module (a UI, the main thread).
    pub fn bus(app: *App) *bus_mod.LocalBus {
        return app.bus_ptr;
    }

    /// Mark `channel` stateful: its last value is retained and replayed to late
    /// subscribers. Call before anything publishes on it (the world's state channel is
    /// handled for you by [`App.world`]).
    pub fn retain(app: *App, channel: []const u8) !void {
        try app.bus_ptr.retain(channel);
    }

    /// Set the overflow policy for a channel: `.block` for true backpressure on a channel
    /// that must not drop, `.drop` (the default) for real-time feeds.
    pub fn overflow(app: *App, channel: []const u8, policy: bus_mod.Overflow) !void {
        try app.bus_ptr.setOverflow(channel, policy);
    }

    /// Spawn any module on its own thread. [`source`](App.source) / [`sink`](App.sink)
    /// are intent-named aliases — use those at call sites to keep the wiring readable.
    pub fn spawn(app: *App, module: core.Module) !void {
        try app.rt.spawn(module);
    }

    /// Spawn a **source**: a module that produces actions/events onto the bus. (Alias of
    /// [`spawn`](App.spawn); the name documents the module's role in the dataflow.)
    pub fn source(app: *App, module: core.Module) !void {
        try app.spawn(module);
    }

    /// Spawn a **sink**: a module that consumes state/events and renders or outputs
    /// them. (Alias of [`spawn`](App.spawn); the name documents the module's role.)
    pub fn sink(app: *App, module: core.Module) !void {
        try app.spawn(module);
    }

    /// Spawn the **world** node: a [`WorldModule`] reducing `actions` into `doc`'s state
    /// and republishing it on `state`. The `state` channel is marked retained
    /// automatically — a world's state is durable by definition, so a late sink always
    /// re-syncs to it. The doc is moved into the world (deinited when the world stops).
    pub fn world(
        app: *App,
        comptime S: type,
        comptime A: type,
        id: []const u8,
        actions: []const u8,
        state: []const u8,
        doc: document.Doc(S, A),
    ) !void {
        try app.bus_ptr.retain(state);
        const World = WorldModule(S, A);
        const instance = try app.gpa.create(World);
        errdefer app.gpa.destroy(instance);
        instance.* = World.init(id, actions, state, doc);
        try app.spawn(core.Module.ofOwned(World, instance));
    }

    /// How many spawned modules are still running — drops to zero as modules finish.
    /// Cheap liveness for a status overlay; pair with [`LocalBus.channelMetrics`].
    pub fn liveCount(app: *App) usize {
        return app.rt.liveCount();
    }

    /// Ask every module to stop (cooperative — modules observe it via `shouldStop`).
    pub fn shutdown(app: *App) void {
        app.rt.shutdown();
    }

    /// Wait for every module to finish, reporting which ones failed.
    pub fn join(app: *App) core.JoinReport {
        app.joined = true;
        return app.rt.join();
    }

    /// Signal shutdown and then wait — the usual teardown after a blocking UI returns.
    pub fn shutdownAndJoin(app: *App) core.JoinReport {
        app.shutdown();
        return app.join();
    }
};

// --- tests ---------------------------------------------------------------------------------

const testing = std.testing;

const CounterAction = union(enum) {
    add: i64,
    sub: i64,
};

fn reduce(_: ?*anyopaque, state: *i64, action: *const CounterAction) anyerror!void {
    switch (action.*) {
        .add => |n| state.* += n,
        .sub => |n| {
            if (state.* - n < 0) return error.WouldGoNegative;
            state.* -= n;
        },
    }
}

/// A source that fires a fixed list of actions onto the "actions" channel, then returns.
const Feeder = struct {
    actions: []const CounterAction,

    pub fn id(_: *Feeder) []const u8 {
        return "feeder";
    }
    pub fn run(self: *Feeder, ctx: *core.ModuleCtx) anyerror!void {
        for (self.actions) |action| {
            try ctx.publishMsg("actions", action);
        }
    }
};

test "world reduces actions and republishes committed state, retained" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try App.init(testing.allocator, io);
    defer app.deinit();

    var states = try app.bus().subscribe("state");
    defer states.deinit();

    try app.world(i64, CounterAction, "world", "actions", "state", .init(testing.allocator, 0, reduce));
    // add 5, add 3, then a rejected sub 100 (no republish), then add 1 → 0, 5, 8, 9.
    var feeder: Feeder = .{ .actions = &.{
        .{ .add = 5 },
        .{ .add = 3 },
        .{ .sub = 100 },
        .{ .add = 1 },
    } };
    try app.source(core.Module.of(Feeder, &feeder));

    var seen: [4]i64 = undefined;
    for (&seen) |*slot| {
        const msg = try states.recv();
        defer msg.deinit();
        const parsed = try msg.env().decode(i64, testing.allocator);
        defer parsed.deinit();
        slot.* = parsed.value;
    }
    // The initial snapshot, then only the *committed* states — the rejected action
    // republished nothing.
    try testing.expectEqualSlices(i64, &.{ 0, 5, 8, 9 }, &seen);

    var report = app.shutdownAndJoin();
    defer report.deinit();
    try testing.expect(report.isClean());

    // The state channel was retained by App.world: a late joiner re-syncs to 9.
    var late = try app.bus().subscribe("state");
    defer late.deinit();
    const msg = try late.recv();
    defer msg.deinit();
    const parsed = try msg.env().decode(i64, testing.allocator);
    defer parsed.deinit();
    try testing.expectEqual(@as(i64, 9), parsed.value);
}
