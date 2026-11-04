//! # zrame.tray — a system-tray icon over DBus (StatusNotifierItem)
//!
//! The freedesktop/KDE tray protocol: an app exposes an `org.kde.StatusNotifierItem`
//! object on the session bus and registers it with the `org.kde.StatusNotifierWatcher`.
//! The panel (KDE, waybar, etc.) then draws the icon and calls back on interaction.
//!
//! It talks to the bus through **sd-bus** (see `sdbus.zig`) and hangs its socket fd off
//! the window's `poll` loop (see `Window.run`), so it costs nothing when idle.
//!
//! First slice: the icon (themed `IconName`), title, tooltip and `Active` status, plus
//! left-click `Activate` wired to a caller callback. The `com.canonical.dbusmenu` context
//! menu is provided separately by `dbusmenu.zig` (the KDE global menu path).

const std = @import("std");
const linux = std.os.linux;
const Allocator = std.mem.Allocator;
const bus = @import("sdbus.zig");
const dbusmenu = @import("dbusmenu.zig");

pub const Config = struct {
    /// Stable application id (SNI `Id`).
    id: [:0]const u8 = "dev.zrame.window",
    /// Human title (SNI `Title`), shown in tooltips/menus.
    title: [:0]const u8 = "zrame",
    /// Themed icon name (SNI `IconName`), e.g. "application-x-executable".
    icon_name: [:0]const u8 = "application-x-executable",
    /// Optional tooltip text (empty = none).
    tooltip: [:0]const u8 = "",
    /// Invoked on left-click (SNI `Activate`), on the window thread.
    on_activate: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,
    /// Optional right-click context menu. When set, a `com.canonical.dbusmenu` object is
    /// hosted on the tray's own connection and advertised via the SNI `Menu` property, so a
    /// panel draws the menu on right-click. The item tree is borrowed — keep it alive.
    menu: ?[]const dbusmenu.Item = null,
    /// Opaque context handed to every menu `on_click` / `checked` (often the same as `ctx`).
    menu_ctx: ?*anyopaque = null,
};

pub const Tray = struct {
    gpa: Allocator,
    bus: ?*bus.Bus = null,
    slot: ?*bus.Slot = null,
    vtable: [13]bus.Vtable = undefined,
    menu: ?*dbusmenu.Menu = null,

    on_activate: ?*const fn (ctx: ?*anyopaque) void = null,
    ctx: ?*anyopaque = null,

    id_buf: [128:0]u8 = undefined,
    title_buf: [256:0]u8 = undefined,
    icon_buf: [128:0]u8 = undefined,
    tip_buf: [256:0]u8 = undefined,
    name_buf: [64:0]u8 = undefined,

    const category = "ApplicationStatus";
    const status = "Active";
    const item_path = "/StatusNotifierItem";
    const item_iface = "org.kde.StatusNotifierItem";
    const menu_path = "/StatusNotifierItem/menu";

    pub fn init(gpa: Allocator, cfg: Config) !*Tray {
        const self = try gpa.create(Tray);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .on_activate = cfg.on_activate, .ctx = cfg.ctx };

        copyz(&self.id_buf, cfg.id);
        copyz(&self.title_buf, cfg.title);
        copyz(&self.icon_buf, cfg.icon_name);
        copyz(&self.tip_buf, cfg.tooltip);
        // Well-known name per the SNI convention: org.kde.StatusNotifierItem-PID-ID.
        _ = std.mem.printSentinel(&self.name_buf, "org.kde.StatusNotifierItem-{d}-1", .{linux.getpid()}, 0) catch return error.TrayName;

        if (bus.sd_bus_open_user(&self.bus) < 0) return error.TrayBusOpen;
        errdefer _ = bus.sd_bus_unref(self.bus);

        self.buildVtable();
        if (bus.sd_bus_add_object_vtable(self.bus, &self.slot, item_path, item_iface, &self.vtable, self) < 0)
            return error.TrayVtable;
        errdefer _ = bus.sd_bus_slot_unref(self.slot);

        if (bus.sd_bus_request_name(self.bus, &self.name_buf, 0) < 0) return error.TrayName;

        // Optional right-click menu, hosted on this same connection so it shares the poll fd.
        if (cfg.menu) |items| {
            self.menu = dbusmenu.Menu.attach(gpa, self.bus.?, items, menu_path, cfg.menu_ctx) catch null;
        }
        errdefer if (self.menu) |m| m.detach();

        var err: bus.BusError = .{};
        defer bus.sd_bus_error_free(&err);
        const r = bus.sd_bus_call_method(
            self.bus,
            "org.kde.StatusNotifierWatcher",
            "/StatusNotifierWatcher",
            "org.kde.StatusNotifierWatcher",
            "RegisterStatusNotifierItem",
            &err,
            null,
            "s",
            @as([*:0]const u8, &self.name_buf),
        );
        if (r < 0) return error.TrayRegister;

        return self;
    }

    pub fn deinit(self: *Tray) void {
        if (self.menu) |m| m.detach();
        _ = bus.sd_bus_slot_unref(self.slot);
        _ = bus.sd_bus_unref(self.bus);
        self.gpa.destroy(self);
    }

    /// The bus socket; hang it off the window's `poll` set.
    pub fn fd(self: *Tray) i32 {
        return bus.sd_bus_get_fd(self.bus);
    }

    /// Push any queued outgoing traffic; call before blocking in `poll`.
    pub fn flush(self: *Tray) void {
        _ = bus.sd_bus_flush(self.bus);
    }

    /// Dispatch everything the socket has for us (property reads, `Activate`, …).
    pub fn process(self: *Tray) void {
        while (bus.sd_bus_process(self.bus, null) > 0) {}
    }

    /// The full vtable: START, the SNI properties (incl. `Menu`), the four SNI methods, END.
    fn buildVtable(self: *Tray) void {
        self.vtable = std.mem.zeroes([13]bus.Vtable);
        self.vtable[0] = bus.startEntry();
        self.vtable[1] = bus.propEntry("Category", "s", getProp);
        self.vtable[2] = bus.propEntry("Id", "s", getProp);
        self.vtable[3] = bus.propEntry("Title", "s", getProp);
        self.vtable[4] = bus.propEntry("Status", "s", getProp);
        self.vtable[5] = bus.propEntry("IconName", "s", getProp);
        self.vtable[6] = bus.propEntry("ItemIsMenu", "b", getProp);
        // `Menu` is the object path of our `com.canonical.dbusmenu` object (or "/" if none).
        self.vtable[7] = bus.propEntry("Menu", "o", getProp);
        self.vtable[8] = bus.methodEntry("Activate", "ii", "", onActivate);
        self.vtable[9] = bus.methodEntry("SecondaryActivate", "ii", "", onNoop);
        self.vtable[10] = bus.methodEntry("ContextMenu", "ii", "", onNoop);
        self.vtable[11] = bus.methodEntry("Scroll", "is", "", onNoop);
        self.vtable[12] = bus.endEntry();
    }

    fn getProp(_: ?*bus.Bus, _: [*:0]const u8, _: [*:0]const u8, property: [*:0]const u8, reply: ?*bus.Message, userdata: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        const self: *Tray = @ptrCast(@alignCast(userdata.?));
        const p = std.mem.span(property);
        if (std.mem.eql(u8, p, "Category")) return bus.sd_bus_message_append(reply, "s", @as([*:0]const u8, category));
        if (std.mem.eql(u8, p, "Id")) return bus.sd_bus_message_append(reply, "s", @as([*:0]const u8, &self.id_buf));
        if (std.mem.eql(u8, p, "Title")) return bus.sd_bus_message_append(reply, "s", @as([*:0]const u8, &self.title_buf));
        if (std.mem.eql(u8, p, "Status")) return bus.sd_bus_message_append(reply, "s", @as([*:0]const u8, status));
        if (std.mem.eql(u8, p, "IconName")) return bus.sd_bus_message_append(reply, "s", @as([*:0]const u8, &self.icon_buf));
        if (std.mem.eql(u8, p, "ItemIsMenu")) return bus.sd_bus_message_append(reply, "b", @as(c_int, 0));
        if (std.mem.eql(u8, p, "Menu")) return bus.sd_bus_message_append(reply, "o", @as([*:0]const u8, if (self.menu) |mnu| mnu.objectPath() else "/"));
        return bus.sd_bus_message_append(reply, "s", @as([*:0]const u8, ""));
    }

    fn onActivate(m: ?*bus.Message, userdata: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        const self: *Tray = @ptrCast(@alignCast(userdata.?));
        if (self.on_activate) |cb| cb(self.ctx);
        return bus.sd_bus_reply_method_return(m, "");
    }

    fn onNoop(m: ?*bus.Message, _: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        return bus.sd_bus_reply_method_return(m, "");
    }
};

/// Copy `src` into a fixed sentinel-terminated buffer, truncating if it would overflow.
fn copyz(dst: anytype, src: []const u8) void {
    const cap = dst.len; // sentinel array: .len excludes the terminator slot
    const n = @min(src.len, cap);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}
