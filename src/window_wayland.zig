const std = @import("std");
const builtin = @import("builtin");

pub const Window = if (builtin.os.tag != .linux) struct {} else struct {
    const wl = @import("wl.zig");
    const paint = @import("paint.zig");
    const window = @import("window.zig");
    const sync = @import("sync.zig");
    const posix = std.posix;
    const linux = std.os.linux;
    const Allocator = std.mem.Allocator;

    gpa: Allocator,
    io: std.Io,
    opts: window.Options,

    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    subcompositor: ?*wl.Subcompositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*wl.XdgWmBase = null,
    seat: ?*wl.Seat = null,

    surface: ?*wl.Surface = null,
    xdg_surface: ?*wl.XdgSurface = null,
    toplevel: ?*wl.XdgToplevel = null,
    subsurface: ?*wl.Subsurface = null, // anchored children (initSub) only
    keyboard: ?*wl.Keyboard = null,
    pointer: ?*wl.Pointer = null,
    decoration_manager: ?*wl.ZxdgDecorationManager = null,
    decoration: ?*wl.ZxdgToplevelDecoration = null,
    cursor_shape_manager: ?*wl.CursorShapeManager = null,

    width: u32,
    height: u32,
    configured: bool = false,
    needs_redraw: bool = false,
    closed: bool = false,
    fullscreen: bool = false,

    shm_fd: posix.fd_t = -1,
    shm_map: []align(std.heap.page_size_min) u8 = &.{},
    pool: ?*wl.ShmPool = null,
    slots: [2]BufferSlot = .{ .{}, .{} },
    buf_w: u32 = 0,
    buf_h: u32 = 0,

    mutex: std.Io.Mutex = .init,
    staged: Staged = .{},
    front: Staged = .{},
    wake_fd: posix.fd_t,

    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    pointer_serial: u32 = 0,

    // Multi-window on ONE connection (window-server shape): children share
    // the root's display/registry/globals and are driven by the root's run()
    // loop. Focus targets live on the root — the seat is connection-global,
    // wl enter events carry the surface, and we route per window.
    parent: ?*Window = null,
    children: std.ArrayList(*Window) = .empty,
    pointer_target: ?*Window = null,
    keyboard_target: ?*Window = null,

    // Key repeat (root only): Wayland compositors do NOT repeat keys for
    // clients — wl_keyboard just announces rate/delay and the client
    // synthesizes. The run() loop re-delivers the held key to its target.
    repeat_rate: i32 = 25, // presses/sec; 0 = repeat disabled by compositor
    repeat_delay: i32 = 400, // ms before the first synthetic repeat
    repeat_key: u32 = 0,
    repeat_down: bool = false,
    repeat_target: ?*Window = null,
    repeat_at: i64 = 0, // ms timestamp of the next synthetic press

    const BufferSlot = struct {
        buffer: ?*wl.Buffer = null,
        pixels: []u32 = &.{},
        busy: bool = false,
    };

    const Staged = struct {
        pixels: std.ArrayList(u8) = .empty,
        width: u32 = 0,
        height: u32 = 0,
        fresh: bool = false,
    };

    pub fn init(gpa: Allocator, io: std.Io, opts: window.Options) !*Window {
        const display = wl.wl_display_connect(null) orelse return error.NoWaylandDisplay;
        errdefer wl.wl_display_disconnect(display);

        const efd = linux.eventfd(0, linux.EFD.CLOEXEC | linux.EFD.NONBLOCK);
        if (linux.errno(efd) != .SUCCESS) return error.EventFdFailed;
        const wake_fd: posix.fd_t = @intCast(efd);
        errdefer _ = linux.close(wake_fd);

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .opts = opts,
            .display = display,
            .registry = wl.displayGetRegistry(display),
            .width = opts.width,
            .height = opts.height,
            .wake_fd = wake_fd,
        };

        self.registry.setListener(&registry_listener, self);
        if (wl.wl_display_roundtrip(self.display) < 0) return error.WaylandIo;
        if (self.compositor == null or self.shm == null or self.wm_base == null)
            return error.MissingWaylandGlobals;

        self.wm_base.?.setListener(&wm_base_listener, self);

        const surface = self.compositor.?.createSurface();
        self.surface = surface;
        const xdg_surface = self.wm_base.?.getXdgSurface(surface);
        xdg_surface.setListener(&xdg_surface_listener, self);
        self.xdg_surface = xdg_surface;
        const toplevel = xdg_surface.getToplevel();
        toplevel.setListener(&toplevel_listener, self);
        toplevel.setTitle(opts.title.ptr);
        self.toplevel = toplevel;

        // Server-side frame (title bar, close/min/max): negotiate BEFORE the
        // first commit — creating the decoration after a buffer is attached
        // is a protocol error. Missing manager = compositor without the
        // protocol: stay borderless, nothing else changes.
        if (opts.decorations) {
            if (self.decoration_manager) |manager| {
                const decoration = manager.getToplevelDecoration(toplevel);
                decoration.setListener(&decoration_listener, self);
                decoration.setMode(wl.DECORATION_MODE_SERVER_SIDE);
                self.decoration = decoration;
            }
        }

        surface.commit();
        if (wl.wl_display_roundtrip(self.display) < 0) return error.WaylandIo;
        return self;
    }

    /// Create a window on the PARENT's connection, driven by the parent's
    /// run() loop, with `xdg_toplevel.set_parent` so the compositor anchors
    /// it (dialogs/panels stay above and near their parent). MUST be called
    /// on the parent's loop thread (e.g. from its on_tick callback): proxy
    /// creation is interleaved with the loop's dispatch.
    pub fn initChild(parent: *Window, opts: window.Options) !*Window {
        const self = try parent.gpa.create(Window);
        errdefer parent.gpa.destroy(self);
        self.* = .{
            .gpa = parent.gpa,
            .io = parent.io,
            .opts = opts,
            .display = parent.display,
            .registry = parent.registry,
            .compositor = parent.compositor,
            .shm = parent.shm,
            .wm_base = parent.wm_base,
            .seat = parent.seat,
            .decoration_manager = parent.decoration_manager,
            .width = opts.width,
            .height = opts.height,
            .wake_fd = parent.wake_fd, // shared: one loop, one wake
            .parent = parent,
        };

        const surface = self.compositor.?.createSurface();
        self.surface = surface;
        const xdg_surface = self.wm_base.?.getXdgSurface(surface);
        xdg_surface.setListener(&xdg_surface_listener, self);
        self.xdg_surface = xdg_surface;
        const toplevel = xdg_surface.getToplevel();
        toplevel.setListener(&toplevel_listener, self);
        toplevel.setTitle(opts.title.ptr);
        toplevel.setParent(parent.toplevel);
        self.toplevel = toplevel;

        if (opts.decorations) {
            if (self.decoration_manager) |manager| {
                const decoration = manager.getToplevelDecoration(toplevel);
                decoration.setListener(&decoration_listener, self);
                decoration.setMode(wl.DECORATION_MODE_SERVER_SIDE);
                self.decoration = decoration;
            }
        }

        surface.commit();
        try parent.children.append(parent.gpa, self);
        // No roundtrip: the running loop dispatches the configure; redraw
        // waits on `configured` as usual.
        _ = wl.wl_display_flush(self.display);
        return self;
    }

    /// Create an ANCHORED child: a wl_subsurface of the parent, composited
    /// with it at an exact offset (parent surface coordinates, y-down from
    /// its top-left) — the panel moves with its window, macOS-style. The
    /// child may extend beyond the parent's bounds. No xdg role: the
    /// compositor never resizes or closes it; input routes per-surface as
    /// for any child. Same loop-thread contract as initChild. Falls back to
    /// initChild (a parented toplevel) when wl_subcompositor is missing.
    pub fn initSub(parent: *Window, opts: window.Options, x: i32, y: i32) !*Window {
        const subcompositor = parent.subcompositor orelse return initChild(parent, opts);
        const self = try parent.gpa.create(Window);
        errdefer parent.gpa.destroy(self);
        self.* = .{
            .gpa = parent.gpa,
            .io = parent.io,
            .opts = opts,
            .display = parent.display,
            .registry = parent.registry,
            .compositor = parent.compositor,
            .subcompositor = subcompositor,
            .shm = parent.shm,
            .wm_base = parent.wm_base,
            .seat = parent.seat,
            .decoration_manager = parent.decoration_manager,
            .width = opts.width,
            .height = opts.height,
            .wake_fd = parent.wake_fd,
            .parent = parent,
            // No configure event will ever arrive for a subsurface: it is
            // drawable as soon as it exists.
            .configured = true,
            .needs_redraw = true,
        };

        const surface = self.compositor.?.createSurface();
        self.surface = surface;
        const sub = subcompositor.getSubsurface(surface, parent.surface.?);
        sub.setPosition(x, y);
        sub.setDesync(); // panels repaint on their own cadence
        self.subsurface = sub;

        try parent.children.append(parent.gpa, self);
        // set_position latches on the PARENT's next commit.
        parent.needs_redraw = true;
        _ = wl.wl_display_flush(self.display);
        return self;
    }

    /// Move an anchored child (parent-relative, y-down). Loop thread only.
    pub fn setSubPosition(self: *Window, x: i32, y: i32) void {
        const sub = self.subsurface orelse return;
        sub.setPosition(x, y);
        if (self.parent) |parent| parent.requestRedraw();
        _ = wl.wl_display_flush(self.display);
    }

    /// Signal the event loop to repaint this window on its next iteration.
    /// Thread-safe: may be called from any thread.
    pub fn requestRedraw(self: *Window) void {
        @atomicStore(bool, &self.needs_redraw, true, .release);
        // Wake the poll() in run() so the redraw is not delayed until the
        // next Wayland event or tick timeout.
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one).ptr, 8);
    }

    /// Request the event loop to exit. Thread-safe.
    pub fn requestClose(self: *Window) void {
        @atomicStore(bool, &self.closed, true, .release);
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one).ptr, 8);
    }

    pub fn setCursorShape(self: *Window, shape: u32) void {
        if (self.cursor_shape_manager) |mgr| {
            if (self.pointer) |pointer| {
                const device = mgr.getPointer(pointer);
                defer wl.wl_proxy_destroy(@ptrCast(device));
                device.setShape(self.pointer_serial, shape);
            }
        }
    }

    /// Tear down a child window: destroy its proxies and remove it from the
    /// parent. Runs on the loop thread (run() reaps closed children with it).
    fn deinitChild(self: *Window) void {
        const parent = self.parent.?;
        if (parent.pointer_target == self) parent.pointer_target = null;
        if (parent.keyboard_target == self) parent.keyboard_target = null;
        if (parent.repeat_target == self) {
            parent.repeat_target = null;
            parent.repeat_down = false;
        }
        for (parent.children.items, 0..) |child, i| {
            if (child == self) {
                _ = parent.children.orderedRemove(i);
                break;
            }
        }
        self.dropBuffers();
        self.staged.pixels.deinit(self.gpa);
        self.front.pixels.deinit(self.gpa);
        if (self.decoration) |d| wl.wl_proxy_destroy(@ptrCast(d));
        if (self.subsurface) |ss| wl.wl_proxy_destroy(@ptrCast(ss));
        if (self.toplevel) |t| wl.wl_proxy_destroy(@ptrCast(t));
        if (self.xdg_surface) |x| wl.wl_proxy_destroy(@ptrCast(x));
        if (self.surface) |s| s.destroy();
        // An unmapped subsurface leaves a hole until the parent recomposites.
        parent.needs_redraw = true;
        _ = wl.wl_display_flush(self.display);
        self.children.deinit(self.gpa);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    /// Update the toplevel title at runtime (apps rename windows per
    /// document, macOS-style).
    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        if (self.toplevel) |toplevel| {
            toplevel.setTitle(title);
            if (self.surface) |surface| surface.commit();
        }
    }

    pub fn deinit(self: *Window) void {
        // Children die with their root (their proxies live on this
        // connection). Notify each — the embedder unregisters its handle —
        // then destroy.
        while (self.children.items.len > 0) {
            const child = self.children.items[self.children.items.len - 1];
            if (child.opts.on_close) |cb| cb(child, child.opts.user);
            child.deinitChild();
        }
        self.children.deinit(self.gpa);
        self.dropBuffers();
        self.staged.pixels.deinit(self.gpa);
        self.front.pixels.deinit(self.gpa);
        if (self.keyboard) |k| wl.wl_proxy_destroy(@ptrCast(k));
        if (self.pointer) |p| wl.wl_proxy_destroy(@ptrCast(p));
        if (self.decoration) |d| wl.wl_proxy_destroy(@ptrCast(d));
        if (self.decoration_manager) |m| wl.wl_proxy_destroy(@ptrCast(m));
        if (self.cursor_shape_manager) |m| wl.wl_proxy_destroy(@ptrCast(m));
        if (self.toplevel) |t| wl.wl_proxy_destroy(@ptrCast(t));
        if (self.xdg_surface) |x| wl.wl_proxy_destroy(@ptrCast(x));
        if (self.surface) |s| s.destroy();
        wl.wl_display_disconnect(self.display);
        _ = linux.close(self.wake_fd);
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn toggleFullscreen(self: *Window) void {
        const tl = self.toplevel orelse return;
        if (self.fullscreen) tl.unsetFullscreen() else tl.setFullscreen();
    }

    pub fn setMinimized(self: *Window) void {
        const tl = self.toplevel orelse return;
        tl.setMinimized();
    }

    pub fn presentRgba(self: *Window, width: u32, height: u32, rgba: []const u8) void {
        const need = @as(usize, width) * @as(usize, height) * 4;
        if (rgba.len < need) return;
        {
            sync.lock(&self.mutex, self.io);
            defer self.mutex.unlock();
            self.staged.pixels.clearRetainingCapacity();
            self.staged.pixels.appendSlice(self.gpa, rgba[0..need]) catch {
                self.staged.width = 0;
                self.staged.height = 0;
                self.staged.fresh = false;
                return;
            };
            self.staged.width = width;
            self.staged.height = height;
            self.staged.fresh = true;
        }
        const one: u64 = 1;
        _ = linux.write(self.wake_fd, std.mem.asBytes(&one).ptr, 8);
    }

    pub fn run(self: *Window) !void {
        while (!self.closed) {
            while (wl.wl_display_prepare_read(self.display) != 0) {
                if (wl.wl_display_dispatch_pending(self.display) < 0) return error.WaylandIo;
            }
            _ = wl.wl_display_flush(self.display);

            var fds = [_]posix.pollfd{
                .{ .fd = wl.wl_display_get_fd(self.display), .events = posix.POLL.IN, .revents = 0 },
                .{ .fd = self.wake_fd, .events = posix.POLL.IN, .revents = 0 },
            };
            var timeout: i32 = if (self.opts.tick_ms > 0) @intCast(self.opts.tick_ms) else -1;
            if (self.repeat_down) {
                const wait = self.repeat_at - nowMs();
                const rep_ms: i32 = @intCast(@max(1, @min(wait, 1000)));
                timeout = if (timeout < 0) rep_ms else @min(timeout, rep_ms);
            }
            _ = posix.poll(&fds, timeout) catch |err| {
                wl.wl_display_cancel_read(self.display);
                return err;
            };

            if (fds[0].revents & (posix.POLL.IN | posix.POLL.ERR | posix.POLL.HUP) != 0) {
                if (wl.wl_display_read_events(self.display) < 0) return error.WaylandIo;
            } else {
                wl.wl_display_cancel_read(self.display);
            }
            if (wl.wl_display_dispatch_pending(self.display) < 0) return error.WaylandIo;
            if (fds[0].revents & (posix.POLL.ERR | posix.POLL.HUP) != 0) return error.WaylandIo;

            if (fds[1].revents & posix.POLL.IN != 0) {
                var drained: u64 = 0;
                _ = posix.read(self.wake_fd, std.mem.asBytes(&drained)) catch {};
                self.latchStaged();
                for (self.children.items) |child| child.latchStaged();
            }

            // Outside the prepare_read/read_events critical section: the tick
            // callback may mark redraws, create child windows, or (indirectly)
            // touch window state.
            if (self.opts.on_tick) |tick| tick(self, self.opts.user);

            // Synthetic key repeat: re-deliver the held key at the seat's
            // announced cadence (the release event stops it in onKey).
            if (self.repeat_down and nowMs() >= self.repeat_at) {
                const target = self.repeat_target orelse self;
                if (target.opts.on_key) |cb|
                    cb(target, self.repeat_key, wl.KEYBOARD_KEY_STATE_PRESSED, target.opts.user);
                const rate = @max(1, self.repeat_rate);
                self.repeat_at = nowMs() + @max(1, @divTrunc(1000, @as(i64, rate)));
            }

            // Reap children closed by the compositor or the embedder. The
            // on_close callback sees a still-valid window; the pointer dies
            // right after it returns.
            var i: usize = 0;
            while (i < self.children.items.len) {
                const child = self.children.items[i];
                if (child.closed) {
                    if (child.opts.on_close) |cb| cb(child, child.opts.user);
                    child.deinitChild(); // removes itself from children
                } else i += 1;
            }

            if (self.configured and self.needs_redraw) try self.redraw();
            for (self.children.items) |child| {
                if (child.configured and child.needs_redraw) child.redraw() catch {};
            }
        }
    }

    fn latchStaged(self: *Window) void {
        sync.lock(&self.mutex, self.io);
        const has_frame = self.staged.fresh;
        sync.unlock(&self.mutex, self.io);
        if (has_frame) self.needs_redraw = true;
    }

    fn redraw(self: *Window) !void {
        const bw = self.width;
        const bh = self.height;
        if (bw != self.buf_w or bh != self.buf_h) try self.resizeBuffers(bw, bh);

        const slot = self.freeSlot() orelse return;
        
        // Background clearing (transparent black by default)
        @memset(slot.pixels, 0x00000000);

        var canvas = paint.Canvas.init(slot.pixels, bw, bh);

        const content = window.Rect{ .x = 0, .y = 0, .w = @intCast(bw), .h = @intCast(bh) };
        if (self.opts.on_draw) |draw| draw(&canvas, content, self.opts.user);

        sync.lock(&self.mutex, self.io);
        if (self.staged.fresh) {
            std.mem.swap(Staged, &self.staged, &self.front);
            self.staged.fresh = false;
        }
        sync.unlock(&self.mutex, self.io);

        if (self.front.width > 0) {
            const fw = @min(self.front.width, bw);
            const fh = @min(self.front.height, bh);
            const dx = (bw - fw) / 2;
            const dy = (bh - fh) / 2;
            // Simplified blit: directly copy or blend pixels
            var y: u32 = 0;
            while (y < fh) : (y += 1) {
                const src_row = self.front.pixels.items[y * self.front.width * 4 ..][0 .. fw * 4];
                const dst_row = slot.pixels[(dy + y) * bw + dx ..][0..fw];
                for (dst_row, 0..) |*dst, x| {
                    const sa = src_row[x * 4 + 3];
                    if (sa == 255) {
                        const r = src_row[x * 4 + 0];
                        const g = src_row[x * 4 + 1];
                        const b = src_row[x * 4 + 2];
                        dst.* = (@as(u32, sa) << 24) | (@as(u32, r) << 16) | (@as(u32, g) << 8) | b;
                    } else if (sa > 0) {
                        // Simple alpha blending
                        const alpha = @as(f32, @floatFromInt(sa)) / 255.0;
                        const inv_alpha = 1.0 - alpha;
                        const r_src = @as(f32, @floatFromInt(src_row[x * 4 + 0]));
                        const g_src = @as(f32, @floatFromInt(src_row[x * 4 + 1]));
                        const b_src = @as(f32, @floatFromInt(src_row[x * 4 + 2]));

                        const dst_val = dst.*;
                        const r_dst = @as(f32, @floatFromInt((dst_val >> 16) & 0xFF));
                        const g_dst = @as(f32, @floatFromInt((dst_val >> 8) & 0xFF));
                        const b_dst = @as(f32, @floatFromInt(dst_val & 0xFF));
                        const a_dst = @as(f32, @floatFromInt((dst_val >> 24) & 0xFF));

                        const r_out = @as(u32, @intFromFloat(r_src * alpha + r_dst * inv_alpha));
                        const g_out = @as(u32, @intFromFloat(g_src * alpha + g_dst * inv_alpha));
                        const b_out = @as(u32, @intFromFloat(b_src * alpha + b_dst * inv_alpha));
                        const a_out = @as(u32, @intFromFloat(255.0 * alpha + a_dst * inv_alpha));
                        dst.* = (a_out << 24) | (r_out << 16) | (g_out << 8) | b_out;
                    }
                }
            }
        }

        const surface = self.surface.?;
        surface.attach(slot.buffer, 0, 0);
        surface.damageBuffer(0, 0, @intCast(bw), @intCast(bh));
        surface.commit();
        slot.busy = true;
        self.needs_redraw = false;
    }

    fn freeSlot(self: *Window) ?*BufferSlot {
        for (&self.slots) |*slot| {
            if (!slot.busy and slot.buffer != null) return slot;
        }
        return null;
    }

    fn dropBuffers(self: *Window) void {
        for (&self.slots) |*slot| {
            if (slot.buffer) |b| b.destroy();
            slot.* = .{};
        }
        if (self.pool) |p| p.destroy();
        self.pool = null;
        if (self.shm_map.len > 0) posix.munmap(self.shm_map);
        self.shm_map = &.{};
        if (self.shm_fd >= 0) _ = linux.close(self.shm_fd);
        self.shm_fd = -1;
        self.buf_w = 0;
        self.buf_h = 0;
    }

    fn resizeBuffers(self: *Window, bw: u32, bh: u32) !void {
        self.dropBuffers();

        const stride = @as(usize, bw) * 4;
        const slot_size = stride * @as(usize, bh);
        const total = slot_size * self.slots.len;

        const fd = try posix.memfd_create("zicro-shm", linux.MFD.CLOEXEC);
        errdefer _ = linux.close(fd);
        if (linux.errno(linux.ftruncate(fd, @intCast(total))) != .SUCCESS) return error.ShmSetupFailed;
        const map = try posix.mmap(null, total, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);

        self.shm_fd = fd;
        self.shm_map = map;
        self.pool = self.shm.?.createPool(fd, @intCast(total));
        for (&self.slots, 0..) |*slot, i| {
            const off = i * slot_size;
            slot.buffer = self.pool.?.createBuffer(@intCast(off), @intCast(bw), @intCast(bh), @intCast(stride), wl.SHM_FORMAT_ARGB8888);
            slot.buffer.?.setListener(&buffer_listener, slot);
            slot.pixels = @as([*]u32, @ptrCast(@alignCast(map.ptr + off)))[0 .. @as(usize, bw) * bh];
            slot.busy = false;
        }
        self.buf_w = bw;
        self.buf_h = bh;

        // Subsurfaces have no xdg role: geometry is implicit in the buffer.
        if (self.xdg_surface) |xs| xs.setWindowGeometry(0, 0, @intCast(bw), @intCast(bh));
        const input = self.compositor.?.createRegion();
        defer input.destroy();
        input.add(0, 0, @intCast(bw), @intCast(bh));
        self.surface.?.setInputRegion(input);
    }

    const buffer_listener = wl.Buffer.Listener{ .release = onBufferRelease };
    fn onBufferRelease(data: ?*anyopaque, _: *wl.Buffer) callconv(.c) void {
        const slot: *BufferSlot = @ptrCast(@alignCast(data.?));
        slot.busy = false;
    }

    const registry_listener = wl.Registry.Listener{
        .global = onGlobal,
        .global_remove = onGlobalRemove,
    };

    fn onGlobal(data: ?*anyopaque, registry: *wl.Registry, name: u32, interface: [*:0]const u8, ver: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const iface = std.mem.span(interface);
        if (std.mem.eql(u8, iface, "wl_compositor")) {
            self.compositor = @ptrCast(registry.bind(name, &wl.wl_compositor_interface, @min(ver, 4)).?);
        } else if (std.mem.eql(u8, iface, "wl_subcompositor")) {
            self.subcompositor = @ptrCast(registry.bind(name, &wl.wl_subcompositor_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(registry.bind(name, &wl.wl_shm_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
            self.wm_base = @ptrCast(registry.bind(name, &wl.xdg_wm_base_interface, @min(ver, 6)).?);
        } else if (std.mem.eql(u8, iface, "zxdg_decoration_manager_v1")) {
            self.decoration_manager = @ptrCast(registry.bind(name, &wl.zxdg_decoration_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wp_cursor_shape_manager_v1")) {
            self.cursor_shape_manager = @ptrCast(registry.bind(name, &wl.wp_cursor_shape_manager_v1_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "wl_seat")) {
            const seat: *wl.Seat = @ptrCast(registry.bind(name, &wl.wl_seat_interface, @min(ver, 5)).?);
            seat.setListener(&seat_listener, self);
            self.seat = seat;
        }
    }

    fn onGlobalRemove(_: ?*anyopaque, _: *wl.Registry, _: u32) callconv(.c) void {}

    const wm_base_listener = wl.XdgWmBase.Listener{ .ping = onPing };
    fn onPing(_: ?*anyopaque, wm_base: *wl.XdgWmBase, serial: u32) callconv(.c) void {
        wm_base.pong(serial);
    }

    const decoration_listener = wl.ZxdgToplevelDecoration.Listener{
        .configure = onDecorationConfigure,
    };
    /// The compositor may override the requested mode (e.g. force client-side):
    /// we accept whatever it picks — server-side draws the frame for us,
    /// client-side just leaves the window borderless as before.
    fn onDecorationConfigure(_: ?*anyopaque, _: *wl.ZxdgToplevelDecoration, _: u32) callconv(.c) void {}

    const xdg_surface_listener = wl.XdgSurface.Listener{ .configure = onSurfaceConfigure };
    fn onSurfaceConfigure(data: ?*anyopaque, xdg_surface: *wl.XdgSurface, serial: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        xdg_surface.ackConfigure(serial);
        self.configured = true;
        self.needs_redraw = true;
    }

    const toplevel_listener = wl.XdgToplevel.Listener{
        .configure = onToplevelConfigure,
        .close = onToplevelClose,
        .configure_bounds = onToplevelConfigureBounds,
        .wm_capabilities = onToplevelWmCapabilities,
    };

    fn onToplevelConfigure(data: ?*anyopaque, _: *wl.XdgToplevel, w: i32, h: i32, states_raw: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));

        var is_fs = false;
        if (states_raw) |sr| {
            const states: *const wl.Array = @ptrCast(@alignCast(sr));
            if (states.data) |raw| {
                const p: [*]const u32 = @ptrCast(@alignCast(raw));
                const n = states.size / 4;
                for (p[0..n]) |state| {
                    if (state == wl.STATE_FULLSCREEN) is_fs = true;
                }
            }
        }

        self.fullscreen = is_fs;

        if (w > 0 and h > 0) {
            self.width = @intCast(w);
            self.height = @intCast(h);
        } else {
            self.width = self.opts.width;
            self.height = self.opts.height;
        }
        self.needs_redraw = true;
    }

    fn onToplevelClose(data: ?*anyopaque, _: *wl.XdgToplevel) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.closed = true;
    }
    fn onToplevelConfigureBounds(_: ?*anyopaque, _: *wl.XdgToplevel, _: i32, _: i32) callconv(.c) void {}
    fn onToplevelWmCapabilities(_: ?*anyopaque, _: *wl.XdgToplevel, _: ?*anyopaque) callconv(.c) void {}

    const seat_listener = wl.Seat.Listener{
        .capabilities = onSeatCapabilities,
        .name = onSeatName,
    };

    fn onSeatCapabilities(data: ?*anyopaque, seat: *wl.Seat, caps: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (caps & wl.SEAT_CAPABILITY_POINTER != 0 and self.pointer == null) {
            const pointer = seat.getPointer();
            pointer.setListener(&pointer_listener, self);
            self.pointer = pointer;
        }
        if (caps & wl.SEAT_CAPABILITY_KEYBOARD != 0 and self.keyboard == null) {
            const keyboard = seat.getKeyboard();
            keyboard.setListener(&keyboard_listener, self);
            self.keyboard = keyboard;
        }
    }

    fn onSeatName(_: ?*anyopaque, _: *wl.Seat, _: [*:0]const u8) callconv(.c) void {}

    const keyboard_listener = wl.Keyboard.Listener{
        .keymap = onKeymap,
        .enter = onKeyEnter,
        .leave = onKeyLeave,
        .key = onKey,
        .modifiers = onKeyModifiers,
        .repeat_info = onKeyRepeatInfo,
    };

    /// Seat listeners live on the root (the seat is connection-global); the
    /// wl enter events carry the surface — resolve it to root or child.
    fn targetFor(self: *Window, surface: ?*wl.Surface) *Window {
        if (surface) |s| {
            if (self.surface == s) return self;
            for (self.children.items) |child| {
                if (child.surface == s) return child;
            }
        }
        return self;
    }

    fn onKeymap(_: ?*anyopaque, _: *wl.Keyboard, _: u32, fd: i32, _: u32) callconv(.c) void {
        _ = linux.close(fd);
    }
    fn onKeyEnter(data: ?*anyopaque, _: *wl.Keyboard, _: u32, surface: ?*wl.Surface, _: ?*anyopaque) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.keyboard_target = self.targetFor(surface);
    }
    fn onKeyLeave(data: ?*anyopaque, _: *wl.Keyboard, _: u32, _: ?*wl.Surface) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.repeat_down = false; // focus gone: the release will never arrive
    }

    /// Monotonic milliseconds (std.time.milliTimestamp lives behind std.Io
    /// in Zig 0.16; the repeat pacing only needs a raw monotonic clock).
    fn nowMs() i64 {
        var ts: linux.timespec = undefined;
        _ = linux.clock_gettime(linux.CLOCK.MONOTONIC, &ts);
        return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
    }

    /// Modifiers hold state rather than produce input: never auto-repeated
    /// (evdev codes: ctrl, shift, alt, meta, capslock).
    fn isModifierKey(key: u32) bool {
        return switch (key) {
            29, 42, 54, 56, 58, 97, 100, 125, 126 => true,
            else => false,
        };
    }

    fn onKey(data: ?*anyopaque, _: *wl.Keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        const target = self.keyboard_target orelse self;
        if (state == wl.KEYBOARD_KEY_STATE_PRESSED) {
            if (!isModifierKey(key) and self.repeat_rate > 0) {
                self.repeat_key = key;
                self.repeat_down = true;
                self.repeat_target = target;
                self.repeat_at = nowMs() + self.repeat_delay;
            }
        } else if (key == self.repeat_key) {
            self.repeat_down = false;
        }
        if (target.opts.on_key) |cb| cb(target, key, state, target.opts.user);
    }

    fn onKeyModifiers(_: ?*anyopaque, _: *wl.Keyboard, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn onKeyRepeatInfo(data: ?*anyopaque, _: *wl.Keyboard, rate: i32, delay: i32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.repeat_rate = rate;
        self.repeat_delay = delay;
    }

    const pointer_listener = wl.Pointer.Listener{
        .enter = onPointerEnter,
        .leave = onPointerLeave,
        .motion = onPointerMotion,
        .button = onPointerButton,
        .axis = onPointerAxis,
        .frame = onPointerFrame,
        .axis_source = onPointerAxisSource,
        .axis_stop = onPointerAxisStop,
        .axis_discrete = onPointerAxisDiscrete,
        .axis_value120 = onPointerAxisValue120,
        .axis_relative_direction = onPointerAxisRelativeDirection,
    };

    fn onPointerEnter(data: ?*anyopaque, pointer: *wl.Pointer, serial: u32, surface: ?*wl.Surface, sx: wl.Fixed, sy: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        self.pointer_x = wl.fixedToF32(sx);
        self.pointer_y = wl.fixedToF32(sy);
        self.pointer_target = self.targetFor(surface);
        if (self.cursor_shape_manager) |mgr| {
            const device = mgr.getPointer(pointer);
            defer wl.wl_proxy_destroy(@ptrCast(device));
            device.setShape(serial, 1); // wl.CursorShapeDevice.SHAPE_DEFAULT = 1
        }
    }
    fn onPointerLeave(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: ?*wl.Surface) callconv(.c) void {}
    fn onPointerMotion(data: ?*anyopaque, _: *wl.Pointer, _: u32, sx: wl.Fixed, sy: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_x = wl.fixedToF32(sx);
        self.pointer_y = wl.fixedToF32(sy);
        const target = self.pointer_target orelse self;
        if (target.opts.on_mouse) |cb| cb(target, .{ .kind = .motion, .x = self.pointer_x, .y = self.pointer_y }, target.opts.user);
    }
    fn onPointerButton(data: ?*anyopaque, _: *wl.Pointer, serial: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        const target = self.pointer_target orelse self;
        if (target.opts.on_mouse) |cb| {
            const kind: window.MouseEvent.Kind = if (state == wl.KEYBOARD_KEY_STATE_PRESSED) .press else .release;
            cb(target, .{ .kind = kind, .x = self.pointer_x, .y = self.pointer_y, .button = button }, target.opts.user);
            return;
        }
        // BTN_LEFT is 272. Drag window anywhere to move if borderless
        if (button == 272 and state == wl.KEYBOARD_KEY_STATE_PRESSED and !target.fullscreen) {
            if (self.seat) |seat| target.toplevel.?.move(seat, serial);
        }
    }
    fn onPointerAxis(data: ?*anyopaque, _: *wl.Pointer, _: u32, axis: u32, value: wl.Fixed) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (axis != 0) return; // vertical only
        const target = self.pointer_target orelse self;
        if (target.opts.on_mouse) |cb| cb(target, .{
            .kind = .scroll,
            .x = self.pointer_x,
            .y = self.pointer_y,
            .scroll_dy = wl.fixedToF32(value),
        }, target.opts.user);
    }
    fn onPointerFrame(_: ?*anyopaque, _: *wl.Pointer) callconv(.c) void {}
    fn onPointerAxisSource(_: ?*anyopaque, _: *wl.Pointer, _: u32) callconv(.c) void {}
    fn onPointerAxisStop(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: u32) callconv(.c) void {}
    fn onPointerAxisDiscrete(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: i32) callconv(.c) void {}
    fn onPointerAxisValue120(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: i32) callconv(.c) void {}
    fn onPointerAxisRelativeDirection(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: u32) callconv(.c) void {}
};
