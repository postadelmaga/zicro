//! Z-Scenic window backend (Z#76 phase 2): implements Zicro's window.Window interface
//! against Z's native capability-scoped compositor protocol. The protocol logic — the
//! canonical handshake, the event dispatcher, resize, teardown — lives in
//! [`scenic_window`](scenic_window.zig) and is tested on the host against a scripted fake
//! server; this file is only the host binding: Z's endpoints and VMOs via `zrt`.
//!
//! Handles (granted by Z's zicro_host.zig at spawn): 0=console,
//! 1=request endpoint (send), 2=reply endpoint (recv).
//!
//! `io: std.Io` is accepted (window.Options's `init` contract requires it) but genuinely
//! never called — nothing in this file's execution path touches it. The caller passes
//! `undefined`; see examples/shell_z.zig's comment for exactly why that's sound here (not
//! merely convenient) and what would need to change if this backend ever needs real async
//! I/O.

const std = @import("std");
const rt = @import("zrt");
const scenic_window = @import("scenic_window.zig");
const scenic_client = @import("scenic_client.zig");

const REQ = 1;
const REP = 2;

/// Z's endpoints and VMOs, as `scenic_window.WindowOver` needs them.
const ZHost = struct {
    pub fn send(_: *ZHost, tag: u64, words: [4]u64, carry: ?usize) void {
        rt.sendWordsCarry(REQ, tag, words, carry);
    }

    /// A refused receive is an error (rt.recvWordsChecked), never a message read out of
    /// an untouched buffer — the old `recvWords` here could hand the dispatcher garbage.
    pub fn recv(_: *ZHost) scenic_client.Error!scenic_client.Msg {
        const r = rt.recvWordsChecked(REP) catch return error.RecvFailed;
        return .{ .tag = r.tag, .words = r.words, .cap = r.cap };
    }

    pub fn closeHandle(_: *ZHost, handle: usize) void {
        rt.handleClose(handle);
    }

    /// A 64 KiB-aligned anonymous VMO (the Y-tiling unit the compositor may want), mapped
    /// write-back. Null — with nothing left behind — when either step fails.
    pub fn allocSurface(_: *ZHost, bytes: usize, w: u32, h: u32) ?scenic_window.Surface {
        const vmo = rt.vmoCreate(bytes, 16) orelse return null;
        const va = rt.mapAttr(vmo, .normal);
        if (va == ~@as(usize, 0)) {
            rt.handleClose(vmo);
            return null;
        }
        const pixels = @as([*]u32, @ptrFromInt(va))[0 .. bytes / 4];
        return .{ .handle = vmo, .pixels = pixels, .width = w, .height = h };
    }

    /// `register_pool` COPIES the handle to the server, which keeps its own mapping: this
    /// side still owns its mapping and its handle, and releases both.
    pub fn freeSurface(_: *ZHost, s: scenic_window.Surface) void {
        _ = rt.unmap(@intFromPtr(s.pixels.ptr));
        rt.handleClose(s.handle);
    }
};

pub const Window = scenic_window.WindowOver(ZHost);
