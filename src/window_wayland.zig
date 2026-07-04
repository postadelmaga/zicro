const std = @import("std");
const builtin = @import("builtin");

pub const Window = if (builtin.os.tag != .linux) struct {} else struct {
    const wl = @import("wl.zig");
    const paint = @import("paint.zig");
    const window = @import("window.zig");
    const posix = std.posix;
    const linux = std.os.linux;
    const Allocator = std.mem.Allocator;

    gpa: Allocator,
    opts: window.Options,

    display: *wl.Display,
    registry: *wl.Registry,
    compositor: ?*wl.Compositor = null,
    shm: ?*wl.Shm = null,
    wm_base: ?*wl.XdgWmBase = null,
    seat: ?*wl.Seat = null,

    surface: ?*wl.Surface = null,
    xdg_surface: ?*wl.XdgSurface = null,
    toplevel: ?*wl.XdgToplevel = null,
    keyboard: ?*wl.Keyboard = null,
    pointer: ?*wl.Pointer = null,

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

    mutex: std.Thread.Mutex = .{},
    staged: Staged = .{},
    front: Staged = .{},
    wake_fd: posix.fd_t,

    pointer_x: f32 = 0,
    pointer_y: f32 = 0,
    pointer_serial: u32 = 0,

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

    pub fn init(gpa: Allocator, opts: window.Options) !*Window {
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

        surface.commit();
        if (wl.wl_display_roundtrip(self.display) < 0) return error.WaylandIo;
        return self;
    }

    pub fn deinit(self: *Window) void {
        self.dropBuffers();
        self.staged.pixels.deinit(self.gpa);
        self.front.pixels.deinit(self.gpa);
        if (self.keyboard) |k| wl.wl_proxy_destroy(@ptrCast(k));
        if (self.pointer) |p| wl.wl_proxy_destroy(@ptrCast(p));
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
            self.mutex.lock();
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
            _ = posix.poll(&fds, -1) catch |err| {
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
                self.mutex.lock();
                const has_frame = self.staged.fresh;
                self.mutex.unlock();
                if (has_frame) {
                    self.needs_redraw = true;
                }
            }

            if (self.configured and self.needs_redraw) try self.redraw();
        }
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

        self.mutex.lock();
        if (self.staged.fresh) {
            std.mem.swap(Staged, &self.staged, &self.front);
            self.staged.fresh = false;
        }
        self.mutex.unlock();

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

        self.xdg_surface.?.setWindowGeometry(0, 0, @intCast(bw), @intCast(bh));
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
        } else if (std.mem.eql(u8, iface, "wl_shm")) {
            self.shm = @ptrCast(registry.bind(name, &wl.wl_shm_interface, 1).?);
        } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
            self.wm_base = @ptrCast(registry.bind(name, &wl.xdg_wm_base_interface, @min(ver, 6)).?);
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

    fn onToplevelConfigure(data: ?*anyopaque, _: *wl.XdgToplevel, w: i32, h: i32, states: *wl.Array) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        
        var is_fs = false;
        const p: [*]const u32 = @ptrCast(@alignCast(states.data));
        const n = states.size / 4;
        for (p[0..n]) |state| {
            if (state == wl.XDG_TOPLEVEL_STATE_FULLSCREEN) is_fs = true;
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
    fn onToplevelWmCapabilities(_: ?*anyopaque, _: *wl.XdgToplevel, _: *wl.Array) callconv(.c) void {}

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

    fn onKeymap(_: ?*anyopaque, _: *wl.Keyboard, _: u32, fd: i32, _: u32) callconv(.c) void {
        _ = linux.close(fd);
    }
    fn onKeyEnter(_: ?*anyopaque, _: *wl.Keyboard, _: u32, _: ?*wl.Surface, _: ?*anyopaque) callconv(.c) void {}
    fn onKeyLeave(_: ?*anyopaque, _: *wl.Keyboard, _: u32, _: ?*wl.Surface) callconv(.c) void {}

    fn onKey(data: ?*anyopaque, _: *wl.Keyboard, _: u32, _: u32, key: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        if (self.opts.on_key) |cb| cb(self, key, state, self.opts.user);
    }

    fn onKeyModifiers(_: ?*anyopaque, _: *wl.Keyboard, _: u32, _: u32, _: u32, _: u32, _: u32) callconv(.c) void {}
    fn onKeyRepeatInfo(_: ?*anyopaque, _: *wl.Keyboard, _: i32, _: i32) callconv(.c) void {}

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
    };

    fn onPointerEnter(data: ?*anyopaque, _: *wl.Pointer, serial: u32, _: ?*wl.Surface, sx: f32, sy: f32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        self.pointer_x = sx;
        self.pointer_y = sy;
    }
    fn onPointerLeave(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: ?*wl.Surface) callconv(.c) void {}
    fn onPointerMotion(data: ?*anyopaque, _: *wl.Pointer, _: u32, sx: f32, sy: f32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_x = sx;
        self.pointer_y = sy;
    }
    fn onPointerButton(data: ?*anyopaque, _: *wl.Pointer, serial: u32, _: u32, button: u32, state: u32) callconv(.c) void {
        const self: *Window = @ptrCast(@alignCast(data.?));
        self.pointer_serial = serial;
        // BTN_LEFT is 272. Drag window anywhere to move if borderless
        if (button == 272 and state == wl.KEYBOARD_KEY_STATE_PRESSED and !self.fullscreen) {
            if (self.seat) |seat| self.toplevel.?.move(seat, serial);
        }
    }
    fn onPointerAxis(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: u32, _: f32) callconv(.c) void {}
    fn onPointerFrame(_: ?*anyopaque, _: *wl.Pointer) callconv(.c) void {}
    fn onPointerAxisSource(_: ?*anyopaque, _: *wl.Pointer, _: u32) callconv(.c) void {}
    fn onPointerAxisStop(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: u32) callconv(.c) void {}
    fn onPointerAxisDiscrete(_: ?*anyopaque, _: *wl.Pointer, _: u32, _: i32) callconv(.c) void {}
};
