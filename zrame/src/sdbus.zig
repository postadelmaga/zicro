//! # zrame.sdbus — a thin sd-bus (libsystemd) FFI layer
//!
//! Just enough of `sd-bus` to expose objects on the session bus and call methods, in the
//! same hand-declared-`extern` idiom as the Wayland glue. Shared by `tray.zig`
//! (StatusNotifierItem) and `dbusmenu.zig` (the KDE global menu).
//!
//! The one delicate bit is `Vtable`: it mirrors `struct sd_bus_vtable` byte-for-byte — a
//! `type:8 | flags:56` header packed into one u64, then an 8-pointer-wide union. The
//! widest arm (`method`) is six machine words, so each record is 8 + 48 = 56 bytes.

const std = @import("std");

pub const Bus = opaque {};
pub const Slot = opaque {};
pub const Message = opaque {};

/// Mirrors `struct sd_bus_error` (name, message, _need_free).
pub const BusError = extern struct {
    name: ?[*:0]const u8 = null,
    message: ?[*:0]const u8 = null,
    need_free: c_int = 0,
};

pub extern fn sd_bus_open_user(ret: *?*Bus) c_int;
pub extern fn sd_bus_unref(bus: ?*Bus) ?*Bus;
pub extern fn sd_bus_slot_unref(slot: ?*Slot) ?*Slot;
pub extern fn sd_bus_request_name(bus: ?*Bus, name: [*:0]const u8, flags: u64) c_int;
pub extern fn sd_bus_get_unique_name(bus: ?*Bus, unique: *?[*:0]const u8) c_int;
pub extern fn sd_bus_add_object_vtable(bus: ?*Bus, slot: *?*Slot, path: [*:0]const u8, interface: [*:0]const u8, vtable: [*]const Vtable, userdata: ?*anyopaque) c_int;
pub extern fn sd_bus_call_method(bus: ?*Bus, destination: [*:0]const u8, path: [*:0]const u8, interface: [*:0]const u8, member: [*:0]const u8, ret_error: *BusError, reply: ?*?*Message, types: ?[*:0]const u8, ...) c_int;
pub extern fn sd_bus_get_fd(bus: ?*Bus) c_int;
pub extern fn sd_bus_process(bus: ?*Bus, ret: ?*?*Message) c_int;
pub extern fn sd_bus_flush(bus: ?*Bus) c_int;
pub extern fn sd_bus_emit_signal(bus: ?*Bus, path: [*:0]const u8, interface: [*:0]const u8, member: [*:0]const u8, types: [*:0]const u8, ...) c_int;

pub extern fn sd_bus_message_append(m: ?*Message, types: [*:0]const u8, ...) c_int;
pub extern fn sd_bus_message_append_basic(m: ?*Message, @"type": u8, value: *const anyopaque) c_int;
pub extern fn sd_bus_message_open_container(m: ?*Message, @"type": u8, contents: [*:0]const u8) c_int;
pub extern fn sd_bus_message_close_container(m: ?*Message) c_int;
pub extern fn sd_bus_message_read(m: ?*Message, types: [*:0]const u8, ...) c_int;
pub extern fn sd_bus_message_read_basic(m: ?*Message, @"type": u8, ret: *anyopaque) c_int;
pub extern fn sd_bus_message_skip(m: ?*Message, types: ?[*:0]const u8) c_int;
pub extern fn sd_bus_message_enter_container(m: ?*Message, @"type": u8, contents: [*:0]const u8) c_int;
pub extern fn sd_bus_message_exit_container(m: ?*Message) c_int;
pub extern fn sd_bus_reply_method_return(call: ?*Message, types: [*:0]const u8, ...) c_int;
pub extern fn sd_bus_message_new_method_return(call: ?*Message, m: *?*Message) c_int;
pub extern fn sd_bus_message_new_signal(bus: ?*Bus, m: *?*Message, path: [*:0]const u8, interface: [*:0]const u8, member: [*:0]const u8) c_int;
pub extern fn sd_bus_send(bus: ?*Bus, m: ?*Message, cookie: ?*u64) c_int;
pub extern fn sd_bus_message_unref(m: ?*Message) ?*Message;
pub extern fn sd_bus_error_free(e: *BusError) void;

/// ABI version tag the START vtable entry must point at.
pub extern const sd_bus_object_vtable_format: c_uint;

// DBus container type codes (see the D-Bus type system).
pub const TYPE_ARRAY: u8 = 'a';
pub const TYPE_VARIANT: u8 = 'v';
pub const TYPE_STRUCT: u8 = 'r';
pub const TYPE_DICT_ENTRY: u8 = 'e';

/// Byte-for-byte layout of `struct sd_bus_vtable`: a `type:8|flags:56` header packed into
/// one u64, then an 8-pointer-wide union (largest arm `method` = six words). 56 bytes.
pub const Vtable = extern struct {
    type_and_flags: u64 = 0,
    f0: usize = 0,
    f1: usize = 0,
    f2: usize = 0,
    f3: usize = 0,
    f4: usize = 0,
    f5: usize = 0,
};

const VTABLE_START = '<';
const VTABLE_END = '>';
const VTABLE_METHOD = 'M';
const VTABLE_PROPERTY = 'P';

fn header(kind: u8, flags: u64) u64 {
    return @as(u64, kind) | (flags << 8);
}

pub const PropGet = *const fn (bus: ?*Bus, path: [*:0]const u8, interface: [*:0]const u8, property: [*:0]const u8, reply: ?*Message, userdata: ?*anyopaque, ret_error: ?*BusError) callconv(.c) c_int;
pub const MethodHandler = *const fn (m: ?*Message, userdata: ?*anyopaque, ret_error: ?*BusError) callconv(.c) c_int;

pub fn startEntry() Vtable {
    return .{
        .type_and_flags = header(VTABLE_START, 0),
        .f0 = @sizeOf(Vtable), // element_size
        .f1 = 0, // features: no param-names, so method `names` fields are ignored
        .f2 = @intFromPtr(&sd_bus_object_vtable_format),
    };
}

pub fn endEntry() Vtable {
    return .{ .type_and_flags = header(VTABLE_END, 0) };
}

pub fn propEntry(member: [*:0]const u8, signature: [*:0]const u8, get: PropGet) Vtable {
    return .{
        .type_and_flags = header(VTABLE_PROPERTY, 0),
        .f0 = @intFromPtr(member),
        .f1 = @intFromPtr(signature),
        .f2 = @intFromPtr(get),
    };
}

pub fn methodEntry(member: [*:0]const u8, signature: [*:0]const u8, result: [*:0]const u8, handler: MethodHandler) Vtable {
    return .{
        .type_and_flags = header(VTABLE_METHOD, 0),
        .f0 = @intFromPtr(member),
        .f1 = @intFromPtr(signature),
        .f2 = @intFromPtr(result),
        .f3 = @intFromPtr(handler),
    };
}

test "vtable record is 56 bytes (matches C sd_bus_vtable)" {
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Vtable));
}

test "header packs type in low byte, flags above" {
    try std.testing.expectEqual(@as(u64, '<'), header('<', 0));
    try std.testing.expectEqual(@as(u64, @as(u64, 'M') | (@as(u64, 3) << 8)), header('M', 3));
}
