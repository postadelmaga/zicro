//! Internal slab pool — the zero-allocation regime behind [`bus`]'s publish hot path.
//!
//! The bus packs each envelope (header + strings) into one contiguous block. This pool
//! recycles those blocks through **size classes**: an acquire rounds the request up to a
//! class and pops a free slab of that class if one is cached; a recycle pushes the slab
//! back. In steady state — after the first few messages of each size have warmed the
//! rings — a publish touches the general-purpose allocator **zero** times.
//!
//! Each class caches its free slabs in a bounded **Vyukov MPMC ring** (the per-cell
//! sequence-number queue): push and pop are both lock-free single-CAS operations, safe
//! from any thread (publishers acquire; whichever thread drops the last `Msg` reference
//! recycles), immune to ABA by construction, and bounded — a full ring simply lets the
//! slab go back to the allocator, so the pool's memory ceiling is fixed no matter the
//! traffic shape. Every class gets the same byte budget ([`class_byte_budget`]), so small
//! (frequent) classes cache many slabs and large (rare) ones few; the ceiling is
//! `class_sizes.len × class_byte_budget` = 3 MiB.
//!
//! Oversize requests (beyond the largest class) bypass the rings: exact allocation on
//! acquire, direct free on recycle.
//!
//! The pool is reference-counted because receivers may outlive the bus: every in-flight
//! envelope holds one reference, so the last dropped message tears the pool down.

const std = @import("std");
const Allocator = std.mem.Allocator;
const sync = @import("sync.zig");

/// Alignment of every slab the pool hands out — generous enough for any envelope header.
pub const slab_align = 16;

/// A recyclable block: length is either a class size or the exact oversize request.
pub const Slab = []align(slab_align) u8;

/// The size classes. Requests round up to the first class that fits.
pub const class_sizes = [_]usize{ 128, 256, 512, 1024, 2048, 4096 };

/// Bytes of free slabs cached per class: every class rings hold this much, so the
/// frequent small classes get deep rings (4096 × 128 B) and the rare large ones shallow
/// (128 × 4 KiB). Deep enough to cover a full default inbox (1024) of small envelopes.
pub const class_byte_budget: usize = 512 * 1024;

/// Free slabs cached per class (power of two — the Vyukov ring requires it).
pub fn ringCapacity(class: usize) usize {
    return class_byte_budget / class;
}

/// One size class's free list: a bounded Vyukov MPMC ring. Every cell carries a sequence
/// number; a producer claims a cell by CAS on `enqueue_pos` and publishes with a release
/// store of `seq = pos + 1`; a consumer claims with CAS on `dequeue_pos` and recycles the
/// cell with `seq = pos + capacity`. No ABA (sequence numbers are free-running), no locks.
const FreeRing = struct {
    const Cell = struct {
        seq: std.atomic.Value(usize),
        ptr: [*]align(slab_align) u8 = undefined,
    };

    enqueue_pos: std.atomic.Value(usize) align(std.atomic.cache_line),
    dequeue_pos: std.atomic.Value(usize) align(std.atomic.cache_line),
    cells: []Cell,
    mask: usize,

    /// `cells.len` must be a power of two.
    fn init(ring: *FreeRing, cells: []Cell) void {
        ring.enqueue_pos = .init(0);
        ring.dequeue_pos = .init(0);
        ring.cells = cells;
        ring.mask = cells.len - 1;
        for (cells, 0..) |*cell, i| cell.* = .{ .seq = .init(i) };
    }

    /// Lock-free push; `false` when the ring is full (caller frees the slab instead).
    fn push(ring: *FreeRing, ptr: [*]align(slab_align) u8) bool {
        var pos = ring.enqueue_pos.load(.monotonic);
        while (true) {
            const cell = &ring.cells[pos & ring.mask];
            const dif: isize = @bitCast(cell.seq.load(.acquire) -% pos);
            if (dif == 0) {
                if (ring.enqueue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                    pos = actual;
                } else {
                    cell.ptr = ptr;
                    cell.seq.store(pos +% 1, .release);
                    return true;
                }
            } else if (dif < 0) {
                return false; // full
            } else {
                pos = ring.enqueue_pos.load(.monotonic);
            }
        }
    }

    /// Lock-free pop; `null` when the ring is empty (caller allocates instead).
    fn pop(ring: *FreeRing) ?[*]align(slab_align) u8 {
        var pos = ring.dequeue_pos.load(.monotonic);
        while (true) {
            const cell = &ring.cells[pos & ring.mask];
            const dif: isize = @bitCast(cell.seq.load(.acquire) -% (pos +% 1));
            if (dif == 0) {
                if (ring.dequeue_pos.cmpxchgWeak(pos, pos +% 1, .monotonic, .monotonic)) |actual| {
                    pos = actual;
                } else {
                    const ptr = cell.ptr;
                    cell.seq.store(pos +% ring.cells.len, .release);
                    return ptr;
                }
            } else if (dif < 0) {
                return null; // empty
            } else {
                pos = ring.dequeue_pos.load(.monotonic);
            }
        }
    }
};

/// The size-classed slab recycler. Create one per bus; share the pointer freely — all
/// methods are thread-safe and (aside from a cold-start alloc) lock-free.
pub const SlabPool = struct {
    gpa: Allocator,
    refs: sync.RefCount,
    rings: [class_sizes.len]FreeRing,
    cell_storage: []FreeRing.Cell, // one allocation backing every ring

    const total_cells = blk: {
        var n: usize = 0;
        for (class_sizes) |class| n += ringCapacity(class);
        break :blk n;
    };

    pub fn create(gpa: Allocator) Allocator.Error!*SlabPool {
        const pool = try gpa.create(SlabPool);
        errdefer gpa.destroy(pool);
        const cells = try gpa.alloc(FreeRing.Cell, total_cells);
        pool.gpa = gpa;
        pool.refs = .init(1);
        pool.cell_storage = cells;
        var off: usize = 0;
        for (&pool.rings, class_sizes) |*ring, class| {
            const cap = ringCapacity(class);
            ring.init(cells[off..][0..cap]);
            off += cap;
        }
        return pool;
    }

    pub fn retain(pool: *SlabPool) *SlabPool {
        pool.refs.retain();
        return pool;
    }

    /// Drop one reference; the last one frees every cached slab and the pool itself.
    pub fn release(pool: *SlabPool) void {
        if (pool.refs.release()) {
            const gpa = pool.gpa;
            for (&pool.rings, class_sizes) |*ring, class| {
                while (ring.pop()) |ptr| gpa.free(ptr[0..class]);
            }
            gpa.free(pool.cell_storage);
            gpa.destroy(pool);
        }
    }

    /// A slab of at least `size` bytes: recycled from the matching class ring when one is
    /// cached (no allocator call), freshly allocated otherwise. Oversize requests get an
    /// exact, unpooled allocation.
    pub fn acquire(pool: *SlabPool, size: usize) Allocator.Error!Slab {
        for (&pool.rings, class_sizes) |*ring, class| {
            if (size <= class) {
                if (ring.pop()) |ptr| return ptr[0..class];
                return pool.gpa.alignedAlloc(u8, .fromByteUnits(slab_align), class);
            }
        }
        return pool.gpa.alignedAlloc(u8, .fromByteUnits(slab_align), size);
    }

    /// Pre-fill the ring of the class that serves `size`-byte requests with up to `count`
    /// slabs. Real-time init-time hygiene: after prewarming past the expected in-flight
    /// peak, even the *first* burst of traffic never touches the allocator.
    pub fn prewarm(pool: *SlabPool, size: usize, count: usize) Allocator.Error!void {
        for (&pool.rings, class_sizes) |*ring, class| {
            if (size <= class) {
                for (0..count) |_| {
                    const slab = try pool.gpa.alignedAlloc(u8, .fromByteUnits(slab_align), class);
                    if (!ring.push(slab.ptr)) {
                        pool.gpa.free(slab);
                        return; // ring already full — fully warmed
                    }
                }
                return;
            }
        }
    }

    /// Return a slab: cached in its class ring, or freed when the ring is full / the slab
    /// is oversize.
    pub fn recycle(pool: *SlabPool, slab: Slab) void {
        for (&pool.rings, class_sizes) |*ring, class| {
            if (slab.len == class) {
                if (ring.push(slab.ptr)) return;
                break; // ring full: let it go back to the allocator
            }
        }
        pool.gpa.free(slab);
    }
};

// --- tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "acquire rounds up to a class and recycling reuses the block" {
    const pool = try SlabPool.create(testing.allocator);
    defer pool.release();

    const a = try pool.acquire(100);
    try testing.expectEqual(@as(usize, 128), a.len);
    const first_ptr = a.ptr;
    pool.recycle(a);

    // Same class → the exact block comes back, no allocation.
    const b = try pool.acquire(90);
    try testing.expectEqual(first_ptr, b.ptr);
    pool.recycle(b);

    // Oversize → exact length, unpooled (recycle frees it; testing allocator checks).
    const big = try pool.acquire(10_000);
    try testing.expectEqual(@as(usize, 10_000), big.len);
    pool.recycle(big);
}

test "pool outlives its creator via refcounts" {
    const pool = try SlabPool.create(testing.allocator);
    const slab = try pool.acquire(64);
    const holder = pool.retain(); // an in-flight envelope
    pool.release(); // the bus is gone
    holder.recycle(slab);
    holder.release(); // last reference frees the cached slab too
}

test "concurrent acquire/recycle stress" {
    const pool = try SlabPool.create(testing.allocator);
    defer pool.release();

    const Worker = struct {
        fn run(p: *SlabPool, seed: u64) void {
            var prng = std.Random.DefaultPrng.init(seed);
            const random = prng.random();
            var held: [8]?Slab = @splat(null);
            for (0..10_000) |_| {
                const slot = random.uintLessThan(usize, held.len);
                if (held[slot]) |slab| {
                    p.recycle(slab);
                    held[slot] = null;
                } else {
                    const size = random.uintLessThan(usize, 5000) + 1;
                    held[slot] = p.acquire(size) catch null;
                }
            }
            for (held) |maybe| if (maybe) |slab| p.recycle(slab);
        }
    };

    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ pool, i + 1 });
    for (threads) |t| t.join();
}
