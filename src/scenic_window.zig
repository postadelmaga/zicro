//! The Z-Scenic window backend, generic over its host (Z#76 phase 2). `window_z.zig`
//! instantiates it over Z's real endpoints and VMOs; the tests below run the very same
//! code against a scripted fake server, so the handshake, the event loop, resize and
//! teardown are checked on every `zig build check-z`, not only by booting Z.
//!
//! ## Protocol (Z `user/scenic/protocol.zig`, canonical form)
//! ```text
//!   register_pool{root} + VMO ─▶ ok     hand the pixel memory over once
//!   attach_surface{root,w,h,pitch} ─▶ ok point the root at a buffer inside it
//!   commit{root}            ─▶ ok        make it visible
//!   … then park: key_event → on_key, redraw, commit
//!                configure{w,h} → new VMO, register_pool, attach, commit
//!                close_request → leave run(); deinit sends disconnect
//! ```
//! Every reply is checked: a refusal fails `init` (no half-attached window is ever
//! returned) or ends `run` with an error — never a silent blank window. Messages are read
//! through [`scenic_client`](scenic_client.zig), so an event that arrives while a request
//! is in flight is kept, not mistaken for its reply.
//!
//! ## Root node
//! The server never sends a client its root id; the spawner packs it into the spawn
//! argument (`index` in bits 0..6, `gen` in bits 56..61 — win_client.zig's layout). An
//! argument of 0 decodes to `{0, 0}`, which is exactly the root `zicro_host.zig` creates,
//! so the host that spawns without an argument keeps working.
//!
//! ## Single-threaded
//! `run()`'s own loop is the only thing that ever touches window state — no
//! presentRgba-from-another-thread split to guard.
//!
//! `Host` must provide everything `scenic_client.Client` needs from a transport, plus:
//! * `fn allocSurface(*Host, bytes: usize, w: u32, h: u32) ?Surface` — pixel memory and a
//!   handle to grant (null when there is none);
//! * `fn freeSurface(*Host, Surface) void` — unmap it and close the handle.

const std = @import("std");
const window = @import("window.zig");
const paint = @import("paint.zig");
const proto = @import("scenic_protocol");
const graph = proto.graph;
const scenic_client = @import("scenic_client.zig");

/// Client-owned pixel memory: a VMO handle (granted to the server by `register_pool`,
/// which COPIES it — this side still has to close it) and its mapping.
pub const Surface = struct {
    handle: usize,
    pixels: []u32,
    width: u32,
    height: u32,
};

pub const Error = error{
    /// The server refused `register_pool`/`attach_surface` (the reason is in
    /// `last_refusal`): bad geometry, no pool, not our root, ...
    AttachRefused,
    /// The server refused a `commit`.
    CommitRefused,
    /// A reply of the wrong kind (e.g. `node_created` to a `commit`).
    UnexpectedReply,
    /// The server closed the window before the first frame was up.
    ClosedDuringInit,
    /// No pixel memory for the surface.
    OutOfMemory,
} || scenic_client.Error;

/// Decode the root node from a spawn argument (see the module doc).
pub fn rootFromSpawnArg(arg: usize) graph.NodeId {
    return .{ .index = @intCast(arg & 0x7F), .gen = @intCast((arg >> 56) & 0x3F) };
}

pub fn WindowOver(comptime Host: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        opts: window.Options,
        client: scenic_client.Client(Host),
        surface: Surface,
        width: u32,
        height: u32,
        root: graph.NodeId,
        /// Set by the app (e.g. an `exit` command in `on_key`) to leave `run()`; the server
        /// closing the window ends `run()` too (`client.closed`).
        closed: bool = false,
        /// The reason of the last refused request, for diagnostics.
        last_refusal: ?proto.Reason = null,

        /// The spawn argument the root id is decoded from (see the module doc). Set it
        /// before `init` — Z's process entry receives it as `main`'s argument.
        pub var spawn_arg: usize = 0;

        /// Bring the window up: allocate the first surface, draw it, run the canonical
        /// handshake. Every failure releases what was acquired and returns an error — the
        /// caller never gets a window without a surface.
        pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: window.Options) !*Self {
            return initHost(gpa, io, opts, .{}, spawn_arg);
        }

        /// `init` with an explicit host value and spawn argument (tests drive this).
        pub fn initHost(gpa: std.mem.Allocator, io: std.Io, opts: window.Options, host: Host, arg: usize) !*Self {
            _ = io; // never used: this backend does no std.Io I/O (see window_z.zig)
            const self = try gpa.create(Self);
            errdefer gpa.destroy(self);
            self.* = .{
                .gpa = gpa,
                .opts = opts,
                .client = .init(host),
                .surface = undefined,
                .width = opts.width,
                .height = opts.height,
                .root = rootFromSpawnArg(arg),
            };
            // A window that never came up still ends its session, so the server is not
            // left holding a client that will never send another request.
            errdefer self.client.sendOneWay(.disconnect, .{ 0, 0, 0, 0 });
            self.surface = try self.newSurface(opts.width, opts.height);
            errdefer self.client.transport.freeSurface(self.surface);
            // Draw before attaching: the first frame is real content, not a blank flash.
            self.redraw();
            try self.attach(self.surface);
            try self.commit();
            if (self.client.closed) return error.ClosedDuringInit;
            return self;
        }

        /// End the session: `disconnect` (the protocol's terminal message, also the only
        /// sensible answer to `close_request`), then release the surface and the window.
        pub fn deinit(self: *Self) void {
            self.client.sendOneWay(.disconnect, .{ 0, 0, 0, 0 });
            self.client.transport.freeSurface(self.surface);
            self.gpa.destroy(self);
        }

        /// The event loop: returns when the server closes the window or the app sets
        /// `closed`; an error when the server refuses a frame or the endpoint fails.
        ///
        /// No implicit clear-to-black before `on_draw` (unlike a typical immediate-mode
        /// backend): pixels carry over between frames, so an app whose background is
        /// expensive to repaint (a `paint.Canvas.drawChrome` glass panel under soft-float)
        /// can paint it once and touch only what changed. A resize hands `on_draw` a fresh
        /// (zeroed) buffer, so such an app must repaint fully when the size changes.
        pub fn run(self: *Self) !void {
            while (!self.closed) {
                switch (try self.client.nextEvent()) {
                    .close => return,
                    .configure => |c| try self.resize(c.w, c.h),
                    .key => |k| {
                        if (self.opts.on_key) |cb| cb(self.platform(), k.code, @intFromBool(k.pressed), self.opts.user);
                        if (self.closed) return; // the app asked to leave: no frame owed
                        self.redraw();
                        try self.commit();
                    },
                }
            }
        }

        /// Re-render at the size the window manager chose. A new surface is allocated,
        /// drawn and registered; the old one is released only once the server accepted
        /// the new pool. Out of memory is not fatal: the old buffer stays attached (the
        /// compositor scales it, as it does until any client re-renders).
        fn resize(self: *Self, w: u32, h: u32) Error!void {
            if (w == self.width and h == self.height) return;
            const fresh = self.newSurface(w, h) catch |e| switch (e) {
                error.OutOfMemory => return, // keep the old frame on screen
            };
            const old = self.surface;
            self.surface = fresh;
            self.width = w;
            self.height = h;
            self.redraw();
            self.attach(fresh) catch |e| {
                // Re-registering replaces the server's pool even when attach then fails,
                // so the old buffer is not attached any more either: release the new one
                // and report — continuing would paint into memory nobody shows.
                self.surface = old;
                self.width = old.width;
                self.height = old.height;
                self.client.transport.freeSurface(fresh);
                return e;
            };
            self.client.transport.freeSurface(old);
            try self.commit();
        }

        fn newSurface(self: *Self, w: u32, h: u32) error{OutOfMemory}!Surface {
            const bytes = std.math.mul(usize, @as(usize, w) * 4, h) catch return error.OutOfMemory;
            return self.client.transport.allocSurface(bytes, w, h) orelse error.OutOfMemory;
        }

        fn attach(self: *Self, s: Surface) Error!void {
            const node = proto.NodeOnly{ .node = self.root };
            try self.expectOk(try self.client.call(.register_pool, node.encode(), s.handle), error.AttachRefused);
            const as = proto.AttachSurface{ .node = self.root, .width = s.width, .height = s.height, .pitch = s.width * 4 };
            try self.expectOk(try self.client.call(.attach_surface, as.encode(), null), error.AttachRefused);
        }

        fn commit(self: *Self) Error!void {
            const r = try self.client.call(.commit, (proto.NodeOnly{ .node = self.root }).encode(), null);
            try self.expectOk(r, error.CommitRefused);
        }

        fn expectOk(self: *Self, r: scenic_client.Reply, refused: Error) Error!void {
            switch (r) {
                .ok => {},
                .err => |reason| {
                    self.last_refusal = reason;
                    return refused;
                },
                .node_created => return error.UnexpectedReply,
            }
        }

        fn redraw(self: *Self) void {
            var canvas = paint.Canvas.init(self.surface.pixels, self.width, self.height);
            const content = window.Rect{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
            if (self.opts.on_draw) |draw| draw(&canvas, content, self.opts.user);
        }

        /// The pointer type `window.Options`' callbacks take. On Z it IS this type; in the
        /// host tests (where `window.Window` is another backend) the tests' callbacks
        /// ignore it, so a cast is all that is needed.
        fn platform(self: *Self) *window.Window {
            return if (comptime Self == window.Window) self else @ptrCast(self);
        }

        // Not used by shell_z.zig's on_draw-only flow.
        pub fn presentRgba(self: *Self, w: u32, h: u32, rgba: []const u8) void {
            _ = self;
            _ = w;
            _ = h;
            _ = rgba;
        }
        pub fn toggleFullscreen(self: *Self) void {
            _ = self;
        }
        pub fn setMinimized(self: *Self) void {
            _ = self;
        }
    };
}

// --- tests: the whole backend against a scripted fake server -------------------------------

const testing = std.testing;
const Msg = scenic_client.Msg;

/// A fake Z: scripted replies/pushes in, requests recorded, surfaces from the testing
/// allocator (so a leaked surface fails the test).
const FakeHost = struct {
    inbound: []const Msg,
    next: usize = 0,
    sent: *std.ArrayList(Msg),
    gpa: std.mem.Allocator,
    live_surfaces: *usize,
    next_handle: usize = 100,
    fail_alloc_at: ?usize = null, // 0-based surface allocation index to refuse
    allocs: usize = 0,

    pub fn send(h: *FakeHost, tag: u64, words: [4]u64, carry: ?usize) void {
        h.sent.append(h.gpa, .{ .tag = tag, .words = words, .cap = carry }) catch @panic("test OOM");
    }
    pub fn recv(h: *FakeHost) scenic_client.Error!Msg {
        if (h.next == h.inbound.len) return error.RecvFailed; // a would-be hang fails instead
        defer h.next += 1;
        return h.inbound[h.next];
    }
    pub fn closeHandle(_: *FakeHost, _: usize) void {}
    pub fn allocSurface(h: *FakeHost, bytes: usize, w: u32, hh: u32) ?Surface {
        defer h.allocs += 1;
        if (h.fail_alloc_at) |i| if (i == h.allocs) return null;
        const px = h.gpa.alloc(u32, bytes / 4) catch return null;
        @memset(px, 0);
        h.live_surfaces.* += 1;
        h.next_handle += 1;
        return .{ .handle = h.next_handle, .pixels = px, .width = w, .height = hh };
    }
    pub fn freeSurface(h: *FakeHost, s: Surface) void {
        h.gpa.free(s.pixels);
        h.live_surfaces.* -= 1;
    }
};

const TestWindow = WindowOver(FakeHost);

fn ok() Msg {
    return .{ .tag = @intFromEnum(proto.Tag.ok) };
}
fn refuse(reason: proto.Reason) Msg {
    return .{ .tag = @intFromEnum(proto.Tag.err), .words = (proto.Err{ .reason = reason }).encode() };
}
fn push(tag: proto.Tag, words: [4]u64) Msg {
    return .{ .tag = @intFromEnum(tag), .words = words };
}
fn tagOf(m: Msg) proto.Tag {
    return proto.tagFromRaw(m.tag).?;
}

const Recorder = struct {
    keys: [8]u32 = undefined,
    n: usize = 0,
    draws: usize = 0,
    quit_on: ?u32 = null,
    win: ?*TestWindow = null,

    fn onDraw(canvas: *paint.Canvas, _: window.Rect, user: ?*anyopaque) void {
        const r: *Recorder = @ptrCast(@alignCast(user.?));
        r.draws += 1;
        canvas.pixels[0] = 0xFF00FF00;
    }
    fn onKey(_: *window.Window, key: u32, state: u32, user: ?*anyopaque) void {
        const r: *Recorder = @ptrCast(@alignCast(user.?));
        if (state == 1) {
            r.keys[r.n] = key;
            r.n += 1;
        }
        if (r.quit_on) |q| if (q == key) {
            r.win.?.closed = true;
        };
    }
};

const Harness = struct {
    sent: std.ArrayList(Msg) = .empty,
    live: usize = 0,
    rec: Recorder = .{},

    fn host(h: *Harness, script: []const Msg) FakeHost {
        return .{ .inbound = script, .sent = &h.sent, .gpa = testing.allocator, .live_surfaces = &h.live };
    }
    fn opts(h: *Harness) window.Options {
        return .{ .width = 8, .height = 4, .on_draw = Recorder.onDraw, .on_key = Recorder.onKey, .user = &h.rec };
    }
    fn deinit(h: *Harness) void {
        h.sent.deinit(testing.allocator);
    }
};

test "init runs the canonical handshake: register_pool (+VMO), attach_surface, commit" {
    var h: Harness = .{};
    defer h.deinit();
    const script = [_]Msg{ ok(), ok(), ok() };
    const w = try TestWindow.initHost(testing.allocator, undefined, h.opts(), h.host(&script), 0);
    try testing.expectEqual(@as(usize, 3), h.sent.items.len);
    try testing.expectEqual(proto.Tag.register_pool, tagOf(h.sent.items[0]));
    try testing.expect(h.sent.items[0].cap != null); // the pool carries the VMO...
    try testing.expectEqual(proto.Tag.attach_surface, tagOf(h.sent.items[1]));
    try testing.expectEqual(@as(?usize, null), h.sent.items[1].cap); // ...the attach does not
    const as = proto.AttachSurface.decode(h.sent.items[1].words);
    try testing.expectEqual(@as(u32, 8), as.width);
    try testing.expectEqual(@as(u32, 32), as.pitch);
    try testing.expectEqual(proto.Tag.commit, tagOf(h.sent.items[2]));
    try testing.expectEqual(@as(usize, 1), h.rec.draws); // drawn before the attach
    try testing.expectEqual(@as(u32, 0xFF00FF00), w.surface.pixels[0]);
    w.deinit();
    try testing.expectEqual(proto.Tag.disconnect, tagOf(h.sent.items[3]));
    try testing.expectEqual(@as(usize, 0), h.live);
}

test "init fails, and frees everything, when the server refuses the surface" {
    inline for (.{
        .{ [_]Msg{refuse(.no_pool)}, error.AttachRefused, proto.Reason.no_pool },
        .{ [_]Msg{ ok(), refuse(.bad_geometry) }, error.AttachRefused, proto.Reason.bad_geometry },
        .{ [_]Msg{ ok(), ok(), refuse(.not_owner) }, error.CommitRefused, proto.Reason.not_owner },
    }) |case| {
        var h: Harness = .{};
        defer h.deinit();
        try testing.expectError(case[1], TestWindow.initHost(testing.allocator, undefined, h.opts(), h.host(&case[0]), 0));
        try testing.expectEqual(@as(usize, 0), h.live); // no surface leaked (and no window: testing.allocator)
    }
}

test "init fails on a dead endpoint and on a wrong reply kind" {
    var h: Harness = .{};
    defer h.deinit();
    try testing.expectError(error.RecvFailed, TestWindow.initHost(testing.allocator, undefined, h.opts(), h.host(&.{}), 0));
    const wrong = [_]Msg{.{ .tag = @intFromEnum(proto.Tag.node_created) }};
    try testing.expectError(error.UnexpectedReply, TestWindow.initHost(testing.allocator, undefined, h.opts(), h.host(&wrong), 0));
    try testing.expectEqual(@as(usize, 0), h.live);
}

test "the root comes from the spawn argument" {
    var h: Harness = .{};
    defer h.deinit();
    const script = [_]Msg{ ok(), ok(), ok() };
    const arg: usize = 5 | (@as(usize, 3) << 56);
    const w = try TestWindow.initHost(testing.allocator, undefined, h.opts(), h.host(&script), arg);
    defer w.deinit();
    const node = proto.NodeOnly.decode(h.sent.items[0].words).node;
    try testing.expectEqual(@as(@TypeOf(node.index), 5), node.index);
    try testing.expectEqual(@as(@TypeOf(node.gen), 3), node.gen);
    try testing.expect(graph.NodeId.eql(rootFromSpawnArg(0), .{ .index = 0, .gen = 0 })); // zicro_host's root
}

test "run: keys round-trip, a close_request ends the loop, deinit disconnects" {
    var h: Harness = .{};
    defer h.deinit();
    const script = [_]Msg{
        ok(), ok(), ok(), // handshake
        push(.key_event, (proto.KeyEvent{ .code = 30, .pressed = true }).encode()),
        // The close lands while the key's commit is in flight: kept, not taken as the reply.
        push(.close_request, .{ 0, 0, 0, 0 }),
        ok(),
        // Never reached: run() must return on the close, not block for more.
    };
    const w = try TestWindow.initHost(testing.allocator, undefined, h.opts(), h.host(&script), 0);
    try w.run();
    try testing.expectEqual(@as(usize, 1), h.rec.n);
    try testing.expectEqual(@as(u32, 30), h.rec.keys[0]);
    try testing.expectEqual(proto.Tag.commit, tagOf(h.sent.items[h.sent.items.len - 1]));
    w.deinit();
    try testing.expectEqual(proto.Tag.disconnect, tagOf(h.sent.items[h.sent.items.len - 1]));
    try testing.expectEqual(@as(usize, 0), h.live);
}

test "run: configure re-renders into a new pool and releases the old surface" {
    var h: Harness = .{};
    defer h.deinit();
    const script = [_]Msg{
        ok(), ok(), ok(),
        push(.configure, (proto.Configure{ .w = 16, .h = 8 }).encode()),
        ok(), ok(), ok(), // register_pool, attach_surface, commit of the new size
        push(.close_request, .{ 0, 0, 0, 0 }),
    };
    const w = try TestWindow.initHost(testing.allocator, undefined, h.opts(), h.host(&script), 0);
    try w.run();
    try testing.expectEqual(@as(u32, 16), w.width);
    try testing.expectEqual(@as(usize, 16 * 8), w.surface.pixels.len);
    try testing.expectEqual(@as(usize, 1), h.live); // the old surface was released
    try testing.expectEqual(proto.Tag.register_pool, tagOf(h.sent.items[3]));
    const as = proto.AttachSurface.decode(h.sent.items[4].words);
    try testing.expectEqual(@as(u32, 64), as.pitch);
    try testing.expectEqual(@as(usize, 2), h.rec.draws);
    w.deinit();
    try testing.expectEqual(@as(usize, 0), h.live);
}

test "run: a resize the server refuses is an error, and nothing leaks" {
    var h: Harness = .{};
    defer h.deinit();
    const script = [_]Msg{
        ok(), ok(), ok(),
        push(.configure, (proto.Configure{ .w = 1 << 16, .h = 8 }).encode()),
        ok(), refuse(.bad_geometry),
    };
    const w = try TestWindow.initHost(testing.allocator, undefined, h.opts(), h.host(&script), 0);
    try testing.expectError(error.AttachRefused, w.run());
    try testing.expectEqual(@as(?proto.Reason, .bad_geometry), w.last_refusal);
    try testing.expectEqual(@as(u32, 8), w.width); // back on the old surface
    w.deinit();
    try testing.expectEqual(@as(usize, 0), h.live);
}

test "run: out of memory on resize keeps the old frame and the loop alive" {
    var h: Harness = .{};
    defer h.deinit();
    const script = [_]Msg{
        ok(), ok(), ok(),
        push(.configure, (proto.Configure{ .w = 32, .h = 32 }).encode()),
        push(.close_request, .{ 0, 0, 0, 0 }),
    };
    var host = h.host(&script);
    host.fail_alloc_at = 1; // the first (init) surface succeeds, the resize's fails
    const w = try TestWindow.initHost(testing.allocator, undefined, h.opts(), host, 0);
    try w.run();
    try testing.expectEqual(@as(u32, 8), w.width);
    try testing.expectEqual(@as(usize, 3), h.sent.items.len); // no request sent for the failed resize
    w.deinit();
    try testing.expectEqual(@as(usize, 0), h.live);
}

test "run: the app leaving from on_key ends the loop without another frame" {
    var h: Harness = .{};
    defer h.deinit();
    const script = [_]Msg{
        ok(), ok(), ok(),
        push(.key_event, (proto.KeyEvent{ .code = 1, .pressed = true }).encode()),
    };
    h.rec.quit_on = 1;
    const w = try TestWindow.initHost(testing.allocator, undefined, h.opts(), h.host(&script), 0);
    h.rec.win = w;
    try w.run();
    try testing.expectEqual(@as(usize, 3), h.sent.items.len); // no commit after the exit key
    w.deinit();
}

test "run: a dead endpoint ends the loop with an error instead of spinning" {
    var h: Harness = .{};
    defer h.deinit();
    const script = [_]Msg{ ok(), ok(), ok() };
    const w = try TestWindow.initHost(testing.allocator, undefined, h.opts(), h.host(&script), 0);
    defer w.deinit();
    try testing.expectError(error.RecvFailed, w.run());
}

test "a close_request during the handshake fails init cleanly" {
    var h: Harness = .{};
    defer h.deinit();
    const script = [_]Msg{ ok(), push(.close_request, .{ 0, 0, 0, 0 }), ok(), ok() };
    try testing.expectError(error.ClosedDuringInit, TestWindow.initHost(testing.allocator, undefined, h.opts(), h.host(&script), 0));
    try testing.expectEqual(@as(usize, 0), h.live);
}

