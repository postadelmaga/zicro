//! # zrame.dbusmenu — a `com.canonical.dbusmenu` menu, over DBus
//!
//! The `com.canonical.dbusmenu` model has two consumers, both served by the same object:
//!  * **KDE Global Menu** — the app exports its menu bar; `window.zig` publishes the object
//!    address to KWin over `org_kde_kwin_appmenu` (see `appmenu.zig`). This is [`Server`],
//!    which owns its own bus connection.
//!  * **A tray icon's context menu** — the `StatusNotifierItem`'s `Menu` property points a
//!    panel at a `dbusmenu` object *on the tray's own connection*. This is [`Menu`], which
//!    **attaches to a caller-provided bus** so `tray.zig` can host it beside the SNI object.
//!
//! [`Server`] is a thin wrapper that opens a bus and attaches one [`Menu`] to it. The app
//! describes a static tree of [`Item`]s; we flatten it into integer-id nodes (id 0 is the
//! synthetic root container) and serve the interface. The fiddly part is `GetLayout`, whose
//! reply is the recursive `(ia{sv}av)` — an id, a property dict, and an array of variant
//! children, each a nested `(ia{sv}av)`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bus = @import("sdbus.zig");

/// One entry in the menu tree. A plain container (submenu) has `children`; a leaf has an
/// `on_click`; a rule is `separator = true`. A **checkbox** item sets `toggle = true` and
/// (optionally) a `checked` provider queried live so the panel draws the current state. The
/// tree is borrowed for the object's lifetime — keep it alive (a `const` array literal is fine).
///
/// A checkbox is a *pull*: the app owns the state, `checked` reports it, and `on_click` flips
/// it. Writing those two callbacks by hand for every toggle is boilerplate — point the item's
/// `ctx` at a [`Toggle`] and use `Toggle.checkedFn` / `Toggle.clickFn` instead, and clicking
/// the item flips the checkmark with no app code. Several toggles that share one menu each get
/// their own `ctx`, so "Denoise ✓ / EQ ✓" is two `Toggle`s and zero callbacks.
pub const Item = struct {
    label: [:0]const u8 = "",
    enabled: bool = true,
    visible: bool = true,
    separator: bool = false,
    /// Render as a checkmark item (`toggle-type = checkmark`).
    toggle: bool = false,
    /// Live checkmark state, queried each time the panel reads properties. `null` ⇒ off.
    checked: ?*const fn (ctx: ?*anyopaque) bool = null,
    children: []const Item = &.{},
    /// Invoked when the host reports this item "clicked" (on the window thread).
    on_click: ?*const fn (ctx: ?*anyopaque) void = null,
    /// Per-item context for this item's `checked` / `on_click`, overriding the menu-wide
    /// `ctx` when set. Lets each toggle carry its own state (e.g. its own [`Toggle`]) while
    /// still sharing one menu. `null` ⇒ fall back to the menu `ctx`.
    ctx: ?*anyopaque = null,
};

/// A boolean menu-checkbox state with ready-made [`Item`] callbacks. Embed one per toggle,
/// set the item's `toggle = true`, `ctx = &my_toggle`, `checked = Toggle.checkedFn`, and
/// `on_click = Toggle.clickFn` — clicking then flips `on` and the panel redraws the mark.
pub const Toggle = struct {
    on: bool = false,

    /// Flip the state from app code (e.g. to reflect an external change).
    pub fn flip(self: *Toggle) void {
        self.on = !self.on;
    }

    /// Plug into `Item.checked`: reads `on` from an item/menu `ctx` that is a `*Toggle`.
    pub fn checkedFn(ctx: ?*anyopaque) bool {
        const self: *const Toggle = @ptrCast(@alignCast(ctx.?));
        return self.on;
    }

    /// Plug into `Item.on_click`: flips the `*Toggle` behind the item/menu `ctx`.
    pub fn clickFn(ctx: ?*anyopaque) void {
        const self: *Toggle = @ptrCast(@alignCast(ctx.?));
        self.on = !self.on;
    }
};

pub const Config = struct {
    /// Top-level menus (File, Edit, …). Their children are the drop-down entries.
    items: []const Item,
    /// Object path to export the menu at; must match what we hand KWin.
    object_path: [:0]const u8 = "/MenuBar",
    /// Opaque context handed to every `on_click` / `checked`.
    ctx: ?*anyopaque = null,
};

const Node = struct {
    item: ?*const Item, // null for the synthetic root (id 0)
    children: []i32,
};

/// A `com.canonical.dbusmenu` object attached to a **borrowed** bus connection. Register it
/// with [`attach`] and drop it with [`detach`]; it never opens or closes the bus itself, so
/// several objects (an SNI item + its menu) can share one connection and one poll fd.
pub const Menu = struct {
    gpa: Allocator,
    bus: ?*bus.Bus, // borrowed — owned by the caller
    slot: ?*bus.Slot = null,
    vtable: [10]bus.Vtable = undefined,
    nodes: []Node = &.{},
    ctx: ?*anyopaque = null,
    revision: u32 = 1,
    path_buf: [128:0]u8 = undefined,

    const iface = "com.canonical.dbusmenu";

    /// Build the tree and register the `dbusmenu` interface on `b` at `object_path`.
    pub fn attach(gpa: Allocator, b: *bus.Bus, items: []const Item, object_path: [:0]const u8, ctx: ?*anyopaque) !*Menu {
        const self = try gpa.create(Menu);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa, .bus = b, .ctx = ctx };
        copyz(&self.path_buf, object_path);

        try self.buildTree(items);
        errdefer self.freeTree();

        self.buildVtable();
        if (bus.sd_bus_add_object_vtable(self.bus, &self.slot, &self.path_buf, iface, &self.vtable, self) < 0)
            return error.MenuVtable;
        return self;
    }

    /// Unregister and free. Does NOT touch the borrowed bus.
    pub fn detach(self: *Menu) void {
        _ = bus.sd_bus_slot_unref(self.slot);
        self.freeTree();
        self.gpa.destroy(self);
    }

    /// The object path this menu is exported at (for the SNI `Menu` property).
    pub fn objectPath(self: *Menu) [*:0]const u8 {
        return &self.path_buf;
    }

    // ── tree flattening ───────────────────────────────────────────────────────

    fn buildTree(self: *Menu, items: []const Item) !void {
        var list: std.ArrayList(Node) = .empty;
        errdefer list.deinit(self.gpa);
        _ = try self.addNode(&list, null, items);
        self.nodes = try list.toOwnedSlice(self.gpa);
    }

    /// Append a node for `item` (its drop-down being `kids`), recurse, return its id.
    fn addNode(self: *Menu, list: *std.ArrayList(Node), item: ?*const Item, kids: []const Item) !i32 {
        const id: i32 = @intCast(list.items.len);
        try list.append(self.gpa, .{ .item = item, .children = &.{} });
        const ids = try self.gpa.alloc(i32, kids.len);
        for (kids, 0..) |*k, i| ids[i] = try self.addNode(list, k, k.children);
        // `list` may have reallocated while recursing, but `id` still indexes this node.
        list.items[@intCast(id)].children = ids;
        return id;
    }

    fn freeTree(self: *Menu) void {
        for (self.nodes) |n| if (n.children.len > 0) self.gpa.free(n.children);
        if (self.nodes.len > 0) self.gpa.free(self.nodes);
        self.nodes = &.{};
    }

    // ── vtable ────────────────────────────────────────────────────────────────

    fn buildVtable(self: *Menu) void {
        self.vtable = std.mem.zeroes([10]bus.Vtable);
        self.vtable[0] = bus.startEntry();
        self.vtable[1] = bus.propEntry("Version", "u", getProp);
        self.vtable[2] = bus.propEntry("Status", "s", getProp);
        self.vtable[3] = bus.propEntry("TextDirection", "s", getProp);
        self.vtable[4] = bus.methodEntry("GetLayout", "iias", "u(ia{sv}av)", onGetLayout);
        self.vtable[5] = bus.methodEntry("GetGroupProperties", "aias", "a(ia{sv})", onGetGroupProperties);
        self.vtable[6] = bus.methodEntry("GetProperty", "is", "v", onGetProperty);
        self.vtable[7] = bus.methodEntry("Event", "isvu", "", onEvent);
        self.vtable[8] = bus.methodEntry("AboutToShow", "i", "b", onAboutToShow);
        self.vtable[9] = bus.endEntry();
    }

    fn getProp(_: ?*bus.Bus, _: [*:0]const u8, _: [*:0]const u8, property: [*:0]const u8, reply: ?*bus.Message, _: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        const p = std.mem.span(property);
        if (std.mem.eql(u8, p, "Version")) return bus.sd_bus_message_append(reply, "u", @as(c_uint, 4));
        if (std.mem.eql(u8, p, "TextDirection")) return bus.sd_bus_message_append(reply, "s", @as([*:0]const u8, "ltr"));
        return bus.sd_bus_message_append(reply, "s", @as([*:0]const u8, "normal")); // Status
    }

    // ── layout serialization ──────────────────────────────────────────────────

    fn valid(self: *Menu, id: i32) bool {
        return id >= 0 and id < self.nodes.len;
    }

    /// Emit one item's `a{sv}` property dict.
    fn appendProps(self: *Menu, reply: ?*bus.Message, id: i32) void {
        _ = bus.sd_bus_message_open_container(reply, bus.TYPE_ARRAY, "{sv}");
        const node = self.nodes[@intCast(id)];
        if (node.item) |it| {
            _ = bus.sd_bus_message_append(reply, "{sv}", @as([*:0]const u8, "label"), @as([*:0]const u8, "s"), @as([*:0]const u8, it.label));
            _ = bus.sd_bus_message_append(reply, "{sv}", @as([*:0]const u8, "enabled"), @as([*:0]const u8, "b"), @as(c_int, @intFromBool(it.enabled)));
            _ = bus.sd_bus_message_append(reply, "{sv}", @as([*:0]const u8, "visible"), @as([*:0]const u8, "b"), @as(c_int, @intFromBool(it.visible)));
            if (it.separator)
                _ = bus.sd_bus_message_append(reply, "{sv}", @as([*:0]const u8, "type"), @as([*:0]const u8, "s"), @as([*:0]const u8, "separator"));
            if (it.toggle) {
                _ = bus.sd_bus_message_append(reply, "{sv}", @as([*:0]const u8, "toggle-type"), @as([*:0]const u8, "s"), @as([*:0]const u8, "checkmark"));
                const on = if (it.checked) |c| c(self.effectiveCtx(it)) else false;
                _ = bus.sd_bus_message_append(reply, "{sv}", @as([*:0]const u8, "toggle-state"), @as([*:0]const u8, "i"), @as(c_int, @intFromBool(on)));
            }
        }
        if (node.children.len > 0)
            _ = bus.sd_bus_message_append(reply, "{sv}", @as([*:0]const u8, "children-display"), @as([*:0]const u8, "s"), @as([*:0]const u8, "submenu"));
        _ = bus.sd_bus_message_close_container(reply);
    }

    fn effectiveCtx(self: *const Menu, it: *const Item) ?*anyopaque {
        return it.ctx orelse self.ctx;
    }

    /// Emit the recursive `(ia{sv}av)` layout for `id`, descending `depth` levels
    /// (-1 = unlimited).
    fn appendLayout(self: *Menu, reply: ?*bus.Message, id: i32, depth: i32) void {
        _ = bus.sd_bus_message_open_container(reply, bus.TYPE_STRUCT, "ia{sv}av");
        _ = bus.sd_bus_message_append(reply, "i", @as(c_int, id));
        self.appendProps(reply, id);
        _ = bus.sd_bus_message_open_container(reply, bus.TYPE_ARRAY, "v");
        if (depth != 0) {
            for (self.nodes[@intCast(id)].children) |child| {
                _ = bus.sd_bus_message_open_container(reply, bus.TYPE_VARIANT, "(ia{sv}av)");
                self.appendLayout(reply, child, depth - 1);
                _ = bus.sd_bus_message_close_container(reply);
            }
        }
        _ = bus.sd_bus_message_close_container(reply);
        _ = bus.sd_bus_message_close_container(reply);
    }

    // ── method handlers ───────────────────────────────────────────────────────

    fn onGetLayout(m: ?*bus.Message, userdata: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        const self: *Menu = @ptrCast(@alignCast(userdata.?));
        var parent: i32 = 0;
        var depth: i32 = -1;
        _ = bus.sd_bus_message_read(m, "ii", &parent, &depth);
        if (!self.valid(parent)) parent = 0;

        var reply: ?*bus.Message = null;
        if (bus.sd_bus_message_new_method_return(m, &reply) < 0) return -1;
        defer _ = bus.sd_bus_message_unref(reply);
        _ = bus.sd_bus_message_append(reply, "u", @as(c_uint, self.revision));
        self.appendLayout(reply, parent, depth);
        return bus.sd_bus_send(self.bus, reply, null);
    }

    fn onGetGroupProperties(m: ?*bus.Message, userdata: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        const self: *Menu = @ptrCast(@alignCast(userdata.?));
        var ids: [512]i32 = undefined;
        var n: usize = 0;
        _ = bus.sd_bus_message_enter_container(m, bus.TYPE_ARRAY, "i");
        while (n < ids.len) {
            var id: i32 = 0;
            if (bus.sd_bus_message_read_basic(m, 'i', &id) <= 0) break;
            ids[n] = id;
            n += 1;
        }
        _ = bus.sd_bus_message_exit_container(m);

        var reply: ?*bus.Message = null;
        if (bus.sd_bus_message_new_method_return(m, &reply) < 0) return -1;
        defer _ = bus.sd_bus_message_unref(reply);
        _ = bus.sd_bus_message_open_container(reply, bus.TYPE_ARRAY, "(ia{sv})");
        // An empty request means "every item" per the spec.
        if (n == 0) {
            var id: i32 = 0;
            while (id < self.nodes.len) : (id += 1) self.appendGroupEntry(reply, id);
        } else {
            for (ids[0..n]) |id| if (self.valid(id)) self.appendGroupEntry(reply, id);
        }
        _ = bus.sd_bus_message_close_container(reply);
        return bus.sd_bus_send(self.bus, reply, null);
    }

    fn appendGroupEntry(self: *Menu, reply: ?*bus.Message, id: i32) void {
        _ = bus.sd_bus_message_open_container(reply, bus.TYPE_STRUCT, "ia{sv}");
        _ = bus.sd_bus_message_append(reply, "i", @as(c_int, id));
        self.appendProps(reply, id);
        _ = bus.sd_bus_message_close_container(reply);
    }

    fn onGetProperty(m: ?*bus.Message, userdata: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        const self: *Menu = @ptrCast(@alignCast(userdata.?));
        var id: i32 = 0;
        var name: ?[*:0]const u8 = null;
        _ = bus.sd_bus_message_read(m, "is", &id, &name);
        const key = if (name) |nm| std.mem.span(nm) else "";

        var reply: ?*bus.Message = null;
        if (bus.sd_bus_message_new_method_return(m, &reply) < 0) return -1;
        defer _ = bus.sd_bus_message_unref(reply);
        const it: ?*const Item = if (self.valid(id)) self.nodes[@intCast(id)].item else null;
        if (it != null and std.mem.eql(u8, key, "label")) {
            _ = bus.sd_bus_message_append(reply, "v", @as([*:0]const u8, "s"), @as([*:0]const u8, it.?.label));
        } else if (it != null and std.mem.eql(u8, key, "enabled")) {
            _ = bus.sd_bus_message_append(reply, "v", @as([*:0]const u8, "b"), @as(c_int, @intFromBool(it.?.enabled)));
        } else if (it != null and it.?.toggle and std.mem.eql(u8, key, "toggle-state")) {
            const on = if (it.?.checked) |c| c(self.effectiveCtx(it.?)) else false;
            _ = bus.sd_bus_message_append(reply, "v", @as([*:0]const u8, "i"), @as(c_int, @intFromBool(on)));
        } else {
            _ = bus.sd_bus_message_append(reply, "v", @as([*:0]const u8, "s"), @as([*:0]const u8, ""));
        }
        return bus.sd_bus_send(self.bus, reply, null);
    }

    fn onEvent(m: ?*bus.Message, userdata: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        const self: *Menu = @ptrCast(@alignCast(userdata.?));
        var id: i32 = 0;
        var event: ?[*:0]const u8 = null;
        _ = bus.sd_bus_message_read(m, "is", &id, &event);
        const name = if (event) |e| std.mem.span(e) else "";
        if (std.mem.eql(u8, name, "clicked") and self.valid(id)) {
            if (self.nodes[@intCast(id)].item) |it| {
                if (it.on_click) |cb| cb(self.effectiveCtx(it));
                // A toggle's checkmark just flipped; the dbusmenu contract is push-based
                // (`com.canonical.dbusmenu`), so a host that keeps the menu open (rather
                // than re-querying on next AboutToShow) needs this signal to redraw it.
                if (it.toggle) self.emitItemPropertiesUpdated(id);
            }
        }
        return bus.sd_bus_reply_method_return(m, "");
    }

    /// Emit `ItemsPropertiesUpdated` for one item, e.g. after a `Toggle` flips.
    fn emitItemPropertiesUpdated(self: *Menu, id: i32) void {
        var msg: ?*bus.Message = null;
        if (bus.sd_bus_message_new_signal(self.bus, &msg, &self.path_buf, iface, "ItemsPropertiesUpdated") < 0) return;
        defer _ = bus.sd_bus_message_unref(msg);
        _ = bus.sd_bus_message_open_container(msg, bus.TYPE_ARRAY, "(ia{sv})");
        self.appendGroupEntry(msg, id);
        _ = bus.sd_bus_message_close_container(msg);
        _ = bus.sd_bus_message_open_container(msg, bus.TYPE_ARRAY, "(ias)"); // removedProps: none
        _ = bus.sd_bus_message_close_container(msg);
        _ = bus.sd_bus_send(self.bus, msg, null);
    }

    fn onAboutToShow(m: ?*bus.Message, _: ?*anyopaque, _: ?*bus.BusError) callconv(.c) c_int {
        // Static tree: layout never changes. Toggle-states are re-read via GetGroupProperties
        // when the panel opens, so we report "no layout update needed".
        return bus.sd_bus_reply_method_return(m, "b", @as(c_int, 0));
    }
};

/// A standalone `dbusmenu` service on its own connection — the KDE Global Menu path. Owns a
/// bus and one attached [`Menu`]; publish `uniqueName()` to KWin via `appmenu.zig`.
pub const Server = struct {
    gpa: Allocator,
    bus: ?*bus.Bus = null,
    menu: *Menu = undefined,

    pub fn init(gpa: Allocator, cfg: Config) !*Server {
        const self = try gpa.create(Server);
        errdefer gpa.destroy(self);
        self.* = .{ .gpa = gpa };

        if (bus.sd_bus_open_user(&self.bus) < 0) return error.MenuBusOpen;
        errdefer _ = bus.sd_bus_unref(self.bus);

        self.menu = try Menu.attach(gpa, self.bus.?, cfg.items, cfg.object_path, cfg.ctx);
        return self;
    }

    pub fn deinit(self: *Server) void {
        self.menu.detach();
        _ = bus.sd_bus_unref(self.bus);
        self.gpa.destroy(self);
    }

    pub fn fd(self: *Server) i32 {
        return bus.sd_bus_get_fd(self.bus);
    }
    pub fn flush(self: *Server) void {
        _ = bus.sd_bus_flush(self.bus);
    }
    pub fn process(self: *Server) void {
        while (bus.sd_bus_process(self.bus, null) > 0) {}
    }

    /// The connection's unique name (":1.NN") — the "service name" KWin needs to find us.
    pub fn uniqueName(self: *Server) ?[*:0]const u8 {
        var name: ?[*:0]const u8 = null;
        if (bus.sd_bus_get_unique_name(self.bus, &name) < 0) return null;
        return name;
    }
};

/// Copy `src` into a fixed sentinel-terminated buffer, truncating if it would overflow.
fn copyz(dst: anytype, src: []const u8) void {
    const cap = dst.len;
    const n = @min(src.len, cap);
    @memcpy(dst[0..n], src[0..n]);
    dst[n] = 0;
}

test "tree flattens with contiguous DFS ids" {
    const items = [_]Item{
        .{ .label = "File", .children = &.{ .{ .label = "Open" }, .{ .label = "Quit" } } },
        .{ .label = "Help", .children = &.{.{ .label = "About" }} },
    };
    const s = try Server.init(std.testing.allocator, .{ .items = &items });
    defer s.deinit();
    // root + File + Open + Quit + Help + About = 6 nodes
    try std.testing.expectEqual(@as(usize, 6), s.menu.nodes.len);
    try std.testing.expectEqual(@as(usize, 2), s.menu.nodes[0].children.len); // root: File, Help
    try std.testing.expect(s.menu.nodes[1].item != null);
    try std.testing.expectEqualStrings("File", std.mem.span(s.menu.nodes[1].item.?.label.ptr));
}

test "Toggle callbacks read and flip per-item state" {
    var denoise = Toggle{ .on = true };
    var eq = Toggle{ .on = false };

    // Two toggles share one menu but carry their own ctx — checkedFn reads each independently.
    const items = [_]Item{
        .{ .label = "Denoise", .toggle = true, .ctx = &denoise, .checked = Toggle.checkedFn, .on_click = Toggle.clickFn },
        .{ .label = "EQ", .toggle = true, .ctx = &eq, .checked = Toggle.checkedFn, .on_click = Toggle.clickFn },
    };

    try std.testing.expect(items[0].checked.?(items[0].ctx));
    try std.testing.expect(!items[1].checked.?(items[1].ctx));

    // A "click" flips only that item's state.
    items[1].on_click.?(items[1].ctx);
    try std.testing.expect(items[1].checked.?(items[1].ctx));
    try std.testing.expect(items[0].checked.?(items[0].ctx)); // unchanged

    denoise.flip();
    try std.testing.expect(!items[0].checked.?(items[0].ctx));
}
