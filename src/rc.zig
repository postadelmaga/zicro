//! [`Rc`] — an atomically reference-counted immutable slice, the port of `Arc<[T]>`.
//!
//! Lives in its own file so both the data plane ([`media`]) and the payload types
//! ([`media_types`]) can depend on it without importing each other (they used to form a
//! cycle through `media.Rc`). The reference count is the shared [`sync.RefCount`], so the
//! atomic ordering is defined in exactly one place.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sync = @import("sync.zig");

/// An atomically reference-counted immutable slice — the port of `Arc<[T]>`. Cloning a
/// handle ([`Rc.retain`]) is a counter bump; the buffer is freed on the last
/// [`Rc.release`].
pub fn Rc(comptime T: type) type {
    return struct {
        inner: *Inner,

        const Inner = struct {
            refs: sync.RefCount,
            gpa: Allocator,
            data: []T,
        };

        const Self = @This();

        /// Allocate a shared copy of `data`.
        pub fn init(gpa: Allocator, data: []const T) Allocator.Error!Self {
            const inner = try gpa.create(Inner);
            errdefer gpa.destroy(inner);
            const copy = try gpa.dupe(T, data);
            inner.* = .{ .refs = .init(1), .gpa = gpa, .data = copy };
            return .{ .inner = inner };
        }

        /// Allocate a shared zero-filled buffer of `len` elements.
        pub fn initZeroed(gpa: Allocator, len: usize) Allocator.Error!Self {
            const inner = try gpa.create(Inner);
            errdefer gpa.destroy(inner);
            const buf = try gpa.alloc(T, len);
            @memset(buf, std.mem.zeroes(T));
            inner.* = .{ .refs = .init(1), .gpa = gpa, .data = buf };
            return .{ .inner = inner };
        }

        pub fn slice(self: Self) []const T {
            return self.inner.data;
        }

        pub fn retain(self: Self) Self {
            self.inner.refs.retain();
            return self;
        }

        pub fn release(self: Self) void {
            if (self.inner.refs.release()) {
                self.inner.gpa.free(self.inner.data);
                self.inner.gpa.destroy(self.inner);
            }
        }
    };
}
