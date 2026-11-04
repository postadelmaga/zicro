//! # zrame.runtime — one event loop for many pollable sources
//!
//! A windowed app gets its multiplexing for free: [`Window.run`](window.Window) already polls
//! the Wayland fd alongside the tray and global-menu fds. A **windowless** app — a tray icon,
//! a tray + its context menu, a headless DBus service — does not, and today each one hand-rolls
//! the same `poll(fd) → process()` loop (see `examples/tray.zig`), with no way to fold in a
//! second fd (the menu, a custom bus, an app timer).
//!
//! [`EventLoop`] is that loop, factored out: register any number of [`Source`]s — anything with
//! an fd to poll and `flush`/`process` to drive — and call [`run`](EventLoop.run). It owns the
//! `poll` set, flushes every source before parking, and dispatches the ready ones. [`stop`] is
//! thread-safe (an eventfd breaks the poll), so another thread — or a source's own callback —
//! can end the loop cleanly. [`Tray`](tray.Tray) and the menu [`Server`](dbusmenu.Server) both
//! already expose `fd`/`flush`/`process`, so [`addTray`]/[`addServer`] wire them in one call.
//!
//! Linux-only (built on `linux.eventfd`/`posix.poll`), like the `Tray`/`Server` sources it
//! is meant to multiplex — there is no stub on other platforms, so don't reach for this
//! from cross-platform application code.

const std = @import("std");
const linux = std.os.linux;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const tray_mod = @import("tray.zig");
const dbusmenu = @import("dbusmenu.zig");

fn pokeEventFd(fd: posix.fd_t) void {
    const one: u64 = 1;
    _ = linux.write(fd, std.mem.asBytes(&one).ptr, 8);
}

/// A pollable event source: an fd to wait on, a `flush` to push pending writes before parking,
/// and a `process` to drain the fd when it signals. The three-method shape [`Tray`] and the
/// dbusmenu [`Server`] already have — wrap any of them with [`of`].
pub const Source = struct {
    ptr: *anyopaque,
    fdFn: *const fn (*anyopaque) i32,
    flushFn: *const fn (*anyopaque) void,
    processFn: *const fn (*anyopaque) void,

    /// Wrap any type with `pub fn fd(*T) i32`, `pub fn flush(*T) void`, `pub fn process(*T) void`.
    pub fn of(comptime T: type, instance: *T) Source {
        const Impl = struct {
            fn fd(ptr: *anyopaque) i32 {
                return @as(*T, @ptrCast(@alignCast(ptr))).fd();
            }
            fn flush(ptr: *anyopaque) void {
                @as(*T, @ptrCast(@alignCast(ptr))).flush();
            }
            fn process(ptr: *anyopaque) void {
                @as(*T, @ptrCast(@alignCast(ptr))).process();
            }
        };
        return .{ .ptr = instance, .fdFn = Impl.fd, .flushFn = Impl.flush, .processFn = Impl.process };
    }

    fn fd(self: Source) i32 {
        return self.fdFn(self.ptr);
    }
    fn flush(self: Source) void {
        self.flushFn(self.ptr);
    }
    fn process(self: Source) void {
        self.processFn(self.ptr);
    }
};

/// A single-threaded poll loop over a set of [`Source`]s. Not thread-safe except for
/// [`stop`], which any thread may call to wake the loop and end it.
pub const EventLoop = struct {
    gpa: Allocator,
    sources: std.ArrayListUnmanaged(Source) = .empty,
    /// Reused across iterations so a steady loop does not allocate per poll.
    pollfds: std.ArrayListUnmanaged(posix.pollfd) = .empty,
    /// eventfd that [`stop`] pokes to break a blocked `poll`.
    wake_fd: posix.fd_t,
    should_stop: std.atomic.Value(bool) = .init(false),

    pub fn init(gpa: Allocator) !EventLoop {
        const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(efd) != .SUCCESS) return error.EventFdFailed;
        return .{ .gpa = gpa, .wake_fd = @intCast(efd) };
    }

    pub fn deinit(self: *EventLoop) void {
        self.sources.deinit(self.gpa);
        self.pollfds.deinit(self.gpa);
        _ = linux.close(self.wake_fd);
    }

    /// Register a source. Sources are borrowed — keep them alive for the loop's lifetime.
    pub fn add(self: *EventLoop, source: Source) !void {
        try self.sources.append(self.gpa, source);
    }

    /// Convenience: register a [`Tray`](tray.Tray).
    pub fn addTray(self: *EventLoop, t: *tray_mod.Tray) !void {
        try self.add(Source.of(tray_mod.Tray, t));
    }

    /// Convenience: register a standalone dbusmenu [`Server`](dbusmenu.Server).
    pub fn addServer(self: *EventLoop, s: *dbusmenu.Server) !void {
        try self.add(Source.of(dbusmenu.Server, s));
    }

    /// Ask the loop to exit. Thread-safe: sets the flag and wakes the `poll`. A `stop` that
    /// races ahead of [`run`] is not lost — `run` observes the flag before its first park.
    pub fn stop(self: *EventLoop) void {
        self.should_stop.store(true, .release);
        pokeEventFd(self.wake_fd);
    }

    /// Poll every source until [`stop`] is called (or a source's fd errors). Flushes all
    /// sources before each park, then dispatches whichever became ready.
    pub fn run(self: *EventLoop) !void {
        while (!self.should_stop.load(.acquire)) {
            for (self.sources.items) |s| s.flush();

            // Slot 0 is the wake fd; the rest mirror `sources` by index.
            self.pollfds.clearRetainingCapacity();
            try self.pollfds.append(self.gpa, .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 });
            for (self.sources.items) |s| {
                try self.pollfds.append(self.gpa, .{ .fd = s.fd(), .events = posix.POLL.IN, .revents = 0 });
            }

            _ = try posix.poll(self.pollfds.items, -1);

            if (self.pollfds.items[0].revents & posix.POLL.IN != 0) {
                var drained: u64 = 0;
                _ = posix.read(self.wake_fd, std.mem.asBytes(&drained)) catch {};
                // Loop condition re-checks should_stop; a stop() wake exits at the top.
            }

            // Walk back-to-front so a removal doesn't shift the index of an
            // item not yet visited.
            const ready = posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP;
            const dead = posix.POLL.ERR | posix.POLL.HUP;
            var i = self.sources.items.len;
            while (i > 0) {
                i -= 1;
                const revents = self.pollfds.items[i + 1].revents;
                if (revents & ready != 0) self.sources.items[i].process();
                // A HUP/ERR fd stays "ready" forever with nothing left to read —
                // drop it, or poll() would return immediately every iteration and
                // spin the loop at 100% CPU on a dead source.
                if (revents & dead != 0) _ = self.sources.orderedRemove(i);
            }
        }
    }
};

// --- tests ----------------------------------------------------------------------------------

/// A [`Source`] backed by a *semaphore* eventfd: each pre-armed signal yields exactly one
/// `process`, which drains one token and counts. At `stop_at` it ends the owning runtime — so
/// the whole loop is driven and torn down on one thread, deterministically, with no real DBus.
const CountingSource = struct {
    efd: posix.fd_t,
    rt: *EventLoop,
    stop_at: u32,
    processed: u32 = 0,
    flushes: u32 = 0,

    fn init(rt: *EventLoop, stop_at: u32) !CountingSource {
        // SEMAPHORE: a read decrements by one and the fd stays readable until it hits zero,
        // so N signals produce N distinct poll/process cycles (a plain eventfd coalesces).
        const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK | linux.EFD.SEMAPHORE);
        if (linux.errno(efd) != .SUCCESS) return error.EventFdFailed;
        return .{ .efd = @intCast(efd), .rt = rt, .stop_at = stop_at };
    }
    fn deinitFd(self: *CountingSource) void {
        _ = linux.close(self.efd);
    }
    fn signal(self: *CountingSource) void {
        pokeEventFd(self.efd);
    }
    pub fn fd(self: *CountingSource) i32 {
        return self.efd;
    }
    pub fn flush(self: *CountingSource) void {
        self.flushes += 1;
    }
    pub fn process(self: *CountingSource) void {
        var drained: u64 = 0;
        _ = posix.read(self.efd, std.mem.asBytes(&drained)) catch {};
        self.processed += 1;
        if (self.processed >= self.stop_at) self.rt.stop();
    }
};

test "runtime polls, flushes, and dispatches its sources until stopped" {
    var rt = try EventLoop.init(std.testing.allocator);
    defer rt.deinit();

    var src = try CountingSource.init(&rt, 3);
    defer src.deinitFd();
    try rt.add(Source.of(CountingSource, &src));

    // Pre-arm three readiness tokens; the loop drains one per iteration and stops at the 3rd.
    src.signal();
    src.signal();
    src.signal();

    try rt.run();

    try std.testing.expectEqual(@as(u32, 3), src.processed);
    // A flush precedes every park, so flushes ≥ processes.
    try std.testing.expect(src.flushes >= src.processed);
}

test "runtime stop() from another thread ends the loop" {
    var rt = try EventLoop.init(std.testing.allocator);
    defer rt.deinit();

    // A source that never signals — the loop parks in poll until stop() wakes it.
    var src = try CountingSource.init(&rt, 999);
    defer src.deinitFd();
    try rt.add(Source.of(CountingSource, &src));

    const Stopper = struct {
        fn kick(r: *EventLoop) void {
            r.stop(); // race-free: run() observes should_stop before/at its first park
        }
    };
    var th = try std.Thread.spawn(.{}, Stopper.kick, .{&rt});
    defer th.join();

    try rt.run(); // returns once the other thread calls stop()
    try std.testing.expectEqual(@as(u32, 0), src.processed);
}

test "convenience registrars type-check against Tray/Server" {
    // No DBus in the test env, so we don't construct them — just force the wrappers to be
    // analyzed, proving Source.of(Tray)/Source.of(Server) match their fd/flush/process shape.
    _ = &EventLoop.addTray;
    _ = &EventLoop.addServer;
}
