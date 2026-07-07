//! Z-Scenic window backend (Z#76 phase 2): implements Zicro's window.Window
//! interface against Z's native capability-scoped compositor protocol,
//! mirroring window_wayland.zig's shape but considerably simpler — Z-Scenic
//! is already zero-copy by design (a VMO the server maps directly, not a
//! Wayland wl_shm pool needing memfd/mmap plumbing) and this backend is
//! single-threaded (no presentRgba-from-another-thread producer/consumer
//! split to guard with a mutex; `run()`'s own loop is the only thing that
//! ever touches window state).
//!
//! Handles (granted by Z's zicro_host.zig at spawn): 0=console,
//! 1=request endpoint (send), 2=reply endpoint (recv).
//!
//! `io: std.Io` is accepted (window.Options's `init` contract requires it)
//! but genuinely never called — nothing in this file's execution path
//! touches it. The caller passes `undefined`; see examples/shell_z.zig's
//! comment for exactly why that's sound here (not merely convenient) and
//! what would need to change if this backend ever needs real async I/O.

const std = @import("std");
const window = @import("window.zig");
const paint = @import("paint.zig");
const rt = @import("zrt");
const proto = @import("scenic_protocol");
const graph = proto.graph;

const REQ = 1;
const REP = 2;

pub const Window = struct {
    gpa: std.mem.Allocator,
    opts: window.Options,
    width: u32,
    height: u32,
    pixels: []u32,
    /// zicro_host.zig creates exactly one root node before servicing its
    /// first client message — deriving this instead of a handshake
    /// round-trip is the same shortcut phase 1's win_client.zig used.
    root: graph.NodeId,
    closed: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: window.Options) !*Window {
        _ = io;
        const w = opts.width;
        const h = opts.height;
        const bytes: usize = @as(usize, w) * @as(usize, h) * 4;
        const vmo = rt.vmoCreate(bytes, 16) orelse return error.OutOfMemory;
        const va = rt.mapAttr(vmo, .normal);
        if (va == ~@as(usize, 0)) return error.SystemResources;
        const pixels = @as([*]u32, @ptrFromInt(va))[0 .. @as(usize, w) * @as(usize, h)];

        const self = try gpa.create(Window);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .opts = opts, .width = w, .height = h, .pixels = pixels, .root = .{ .index = 0, .gen = 0 } };

        // Draw once before the surface is even attached — every backend's
        // first frame is real content, not a blank flash.
        self.redraw();
        rt.sendWordsCarry(REQ, @intFromEnum(proto.Tag.attach_surface), (proto.AttachSurface{ .node = self.root, .width = w, .height = h, .pitch = w * 4 }).encode(), vmo);
        _ = rt.recvWords(REP); // ok/err from attach — nothing actionable differently either way yet
        rt.sendWords(REQ, @intFromEnum(proto.Tag.commit), (proto.NodeOnly{ .node = self.root }).encode());
        _ = rt.recvWords(REP);

        return self;
    }

    pub fn deinit(self: *Window) void {
        rt.sendWords(REQ, @intFromEnum(proto.Tag.disconnect), .{ 0, 0, 0, 0 });
        self.gpa.destroy(self);
    }

    fn redraw(self: *Window) void {
        @memset(self.pixels, 0xFF000000); // opaque black, premultiplied ARGB
        var canvas = paint.Canvas.init(self.pixels, self.width, self.height);
        const content = window.Rect{ .x = 0, .y = 0, .w = @intCast(self.width), .h = @intCast(self.height) };
        if (self.opts.on_draw) |draw| draw(&canvas, content, self.opts.user);
    }

    /// Blocks on the next `key_event` push, calls `on_key`, redraws, and
    /// commits — every key press is one full round-trip to the host and
    /// back (see zicro_host.zig's module doc for why this can't deadlock:
    /// Z's endpoints are a 16-deep buffered ring, not strict rendezvous).
    pub fn run(self: *Window) !void {
        while (!self.closed) {
            const r = rt.recvWords(REP);
            const tag: proto.Tag = @enumFromInt(@as(u32, @truncate(r.tag)));
            if (tag != .key_event) continue; // a stray ok/err reply — ignore
            const ke = proto.KeyEvent.decode(r.words);
            if (self.opts.on_key) |cb| cb(self, ke.code, @intFromBool(ke.pressed), self.opts.user);
            self.redraw();
            rt.sendWords(REQ, @intFromEnum(proto.Tag.commit), (proto.NodeOnly{ .node = self.root }).encode());
            _ = rt.recvWords(REP);
        }
    }

    // Not used by shell_z.zig's on_draw-only flow — real implementations
    // (a resize protocol message, an actual fullscreen concept in the
    // graph) are follow-ups once an app needs them.
    pub fn presentRgba(self: *Window, w: u32, h: u32, rgba: []const u8) void {
        _ = self;
        _ = w;
        _ = h;
        _ = rgba;
    }
    pub fn toggleFullscreen(self: *Window) void {
        _ = self;
    }
    pub fn setMinimized(self: *Window) void {
        _ = self;
    }
};
