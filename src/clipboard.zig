//! # zicro.clipboard — appunti generici del substrato (blob opaco + tag)
//!
//! Un appunti in-process, agnostico rispetto al dominio: conserva UN blob di byte opachi
//! con un breve `tag` (una specie di MIME, es. `"zenflow2/items/v1"`). L'app serializza i
//! propri oggetti nel blob e li deserializza all'incolla; zicro non sa (né deve sapere)
//! cosa contiene. È il gemello di [`gesture`]/[`proportion`]: un servizio di substrato
//! riusabile, non logica d'app.
//!
//! ## Perché nel substrato
//! Il TRANSPORTO degli appunti è una faccenda di piattaforma — copia/incolla tra app passa
//! per la clipboard di sistema (Wayland `wl_data_device`, `navigator.clipboard` sul web,
//! `ClipboardManager` su Android). Quel ponte OS è specifico per backend, esattamente come
//! i gesti e le metriche: quindi l'astrazione vive qui. Per ora è solo IN-PROCESS (copia/
//! incolla dentro la stessa app, anche tra tab/progetti); il ponte alla clipboard di
//! sistema è un innesto futuro che ogni backend potrà implementare riempiendo/leggendo
//! questo stesso store. L'API dell'app non cambierà quando arriverà.
//!
//! Single-thread (come tutta la UI): niente lock.

const std = @import("std");

var g_bytes: []u8 = &.{};
var g_alloc: ?std.mem.Allocator = null;
var g_tag_buf: [64]u8 = undefined;
var g_tag_len: usize = 0;

/// Sostituisce il contenuto degli appunti con una COPIA di `bytes` (posseduta da zicro) e
/// il suo `tag`. `bytes` vuoto equivale a `clear()`. Se l'allocazione fallisce, gli appunti
/// restano vuoti (nessun panic).
pub fn set(alloc: std.mem.Allocator, tag_str: []const u8, bytes: []const u8) void {
    clear();
    if (bytes.len == 0) return;
    const buf = alloc.dupe(u8, bytes) catch return;
    g_bytes = buf;
    g_alloc = alloc;
    const n = @min(tag_str.len, g_tag_buf.len);
    @memcpy(g_tag_buf[0..n], tag_str[0..n]);
    g_tag_len = n;
}

/// Il blob corrente (o `null` se vuoto). Il puntatore vale finché non arriva un nuovo `set`/`clear`.
pub fn get() ?[]const u8 {
    if (g_bytes.len == 0) return null;
    return g_bytes;
}

/// Il tag del blob corrente (stringa vuota se vuoto).
pub fn tag() []const u8 {
    return g_tag_buf[0..g_tag_len];
}

/// Vero se c'è un blob e il suo tag è esattamente `tag_str` (così l'app ignora blob di altri formati).
pub fn has(tag_str: []const u8) bool {
    return g_bytes.len > 0 and std.mem.eql(u8, tag(), tag_str);
}

/// Svuota gli appunti liberando l'eventuale blob posseduto.
pub fn clear() void {
    if (g_alloc) |a| {
        if (g_bytes.len > 0) a.free(g_bytes);
    }
    g_bytes = &.{};
    g_alloc = null;
    g_tag_len = 0;
}

test "set/get/has/clear round-trip" {
    const a = std.testing.allocator;
    defer clear();
    try std.testing.expect(get() == null);
    set(a, "test/blob", "hello");
    try std.testing.expect(has("test/blob"));
    try std.testing.expect(!has("other"));
    try std.testing.expectEqualStrings("hello", get().?);
    set(a, "test/blob", "world!!"); // sostituisce (libera il precedente)
    try std.testing.expectEqualStrings("world!!", get().?);
    clear();
    try std.testing.expect(get() == null);
    try std.testing.expectEqualStrings("", tag());
}
