<div align="center">

# ◇ zicro

**[Micro](https://github.com/postadelmaga/Micro), ported to Zig — the minimal, generic core of the Frame architecture.**

A tiny modules + bus micro-kernel: a string-named pub/sub bus, a generic undoable
document, and an in-process module runtime. On top of it — in separate, optional
namespaces that never touch the kernel — the opinionated **`sources → world → sinks`**
framework: time, input, video, audio, a zero-copy media plane, and a bus-over-byte-stream
bridge.

**Cross-platform by design.** zicro (with [zrame](../Zrame) on top) owns the OS so the
apps built on the Frame architecture don't have to. Everything that touches the platform
— the `Window` (Wayland on Linux, Win32 on Windows, Cocoa on macOS), shared memory, GPU
buffers — sits behind a per-OS backend selected at compile time; the framework surface a
Frame app sees is identical on every OS.

</div>

---

## What is zicro?

A faithful port of the Rust **Micro** workspace to Zig 0.16. The three ideas are the same:

1. **`Envelope` + channels (`protocol`)** — the only types modules share. Routing is by
   channel name; a module never inspects another's internals. `Topic(T)` binds a channel
   name to a payload type at compile time.
2. **`LocalBus` (`bus`)** — an in-process pub/sub broker with bounded inboxes, per-channel
   overflow policy (`.drop` counted / `.block` backpressure), retained channels that
   replay their last value to late subscribers, and per-channel metrics.
3. **`Doc(S, A)` + reducer (`document`)** — the single source of truth. Every edit is a
   serializable action applied by one reducer, transactionally (on a clone first) and
   undoably. Mutations are *data*: loggable, replayable, bus-sendable.

`core` ties them together: a **`Module`** declares its channel subscriptions and a `run`
loop; the **`Runtime`** subscribes it to the bus and spawns it on its own thread, with a
shared worker pool (`ctx.offload`) and fail-fast supervision.

## Layout

One Zig file per Rust crate, one importable module:

```
src/
  # micro-kernel — generic, zero domain
  protocol.zig   Envelope, Topic(T), ChannelKind          (zero logic)
  message.zig    Shared (pooled, ref-counted envelope) + Msg   (bus internal)
  inbox.zig      SpaceSignal + Inbox ring + Receiver       (bounded MPSC, backpressure)
  bus.zig        LocalBus broker (routing)                (+ retained, metrics)
  pool.zig       size-classed slab recycler               (zero-alloc publish, internal)
  sync.zig       Signal (eventcount) + RefCount + Io helpers   (shared primitives)
  rc.zig         Rc(T) — the Arc<[T]> port                 (shared by media + payloads)
  document.zig   History(S), Doc(S, A) + reducer          (undo/redo, transactional)
  worker_pool.zig  the shared offload thread pool          (owned by Runtime)
  core.zig       Module, ModuleCtx, Runtime               (the in-process kernel)

  # framework — opinionated sources → world → sinks, built only on the kernel
  app.zig        App builder + WorldModule(S, A)          (declarative wiring)
  media.zig      zero-copy data plane: latest() + bounded()  (triple buffer + SPSC ring)
  media_types.zig  Frame + AudioBlock                     (the two canonical payloads)
  time.zig       Clock source (Tick) + Pacer frame-limiter
  input.zig      device-neutral InputEvent + InputMapper(A) → bus actions
  video.zig      FrameSink contract + VideoSink module (+ headless BufferSink)
  audio.zig      AudioOut contract + AudioSink module (+ headless Recorder)
  bridge.zig     the bus over a byte stream               (length-prefixed frames,
                                                           wire-compatible with micro-bridge)

  # out-of-process transports — the Rust `ipc` feature of micro-bus
  ipc.zig        channel pair + stdio codec (JSON lines / postcard, wire-compatible)
  shmem.zig      seqlock'd latest-value shared-memory slot   (per-OS backend, below)
  shmem_linux.zig   /dev/shm files (+ orphan sweep)          (Rust-Micro interop)
  shmem_darwin.zig  POSIX shm_open                           (macOS)
  shmem_windows.zig Local\ section object                    (Windows)

  # graphics & windowing — a software-rendered shell (Wayland / Win32)
  window.zig         cross-platform Window facade         (selects the backend by OS)
  window_wayland.zig Wayland backend (xdg-shell, SHM double-buffer)   (Linux)
  window_win32.zig   Win32 backend (layered popup)                    (Windows)
  wl.zig             hand-written Wayland client bindings  (xdg-shell via wayland-scanner)
  paint.zig          Canvas: software rasterizer          (rects, strokes, text blit)
  text.zig           stb_truetype font wrapper (Hack embedded)

  # GPU export plane — autonomous, format-agnostic buffers (bridge-connected, WIP)
  gpu_memory.zig          memfd-backed exportable buffers  (zero-copy GPU import)
  gpu_vulkan.zig          Vulkan external-memory/semaphore wrappers   (partly stubbed)
  gpu_wgpu_bridge_ffi.zig FFI to the external zicro-wgpu-bridge (Rust wgpu-core)
```

> **Note.** The graphics and GPU layers are newer than the kernel/framework and are the
> WIP frontier: they compile on Linux (Wayland) and Windows, but the GPU export plane is
> not yet wired into a render path and the `gpu_wgpu_bridge_ffi` seam needs the external
> [`zicro-wgpu-bridge`](https://github.com/postadelmaga/zicro-wgpu-bridge) linked to do
> anything at runtime.

## Try it

```sh
zig build test                  # the whole suite (kernel + framework)
zig build run-counter           # the bare kernel
zig build run-world_counter     # the App + world spine
zig build run-shell             # the software-rendered windowing shell (Wayland/Win32)
zig build bench                 # the performance contract (ReleaseFast; add `-- --quick` for a fast pass)
```

## Port notes (Rust → Zig)

The boundaries and semantics are the same; the idioms are translated:

| Rust | Zig |
|---|---|
| `serde_json::Value` payloads | JSON **text** (`[]const u8`), typed via `std.json` encode/decode |
| `Arc<T>` sharing (envelopes, pixels) | explicit reference counts (`bus.Msg`, `media.Rc`) with `deinit`/`release` |
| RAII drops (receivers, senders, docs) | explicit `deinit` calls |
| trait objects (`Module`, `FrameSink`, `AudioOut`) | vtable structs with a duck-typed `of(T, instance)` adapter |
| closures (reducer, input map, offload jobs) | function pointers (+ optional context pointer); `offload` captures args like `Thread.spawn` |
| module **panic** supervision (`catch_unwind`) | module `run` returns `anyerror!void`; an error is recorded by `join` and trips shutdown (a Zig panic aborts and cannot be caught) |
| `std::sync::mpsc` bounded channels | hand-rolled rings on `Io.Mutex` + a futex epoch `Signal` (Zig 0.16's `Io.Condition` has no timed wait) |
| implicit global OS clock/sleep | everything takes `std.Io` (`Io.Threaded`), the 0.16 way |
| `std::env::var` config (`MICRO_IPC_FORMAT`, …) | explicit parameters + `*FromEnv` parsing helpers (0.16 has no ambient `getenv`; the env flows through `std.process.Environ`) |
| `fence(Release/Acquire)` in the shmem seqlock | per-word release stores / acquire loads on the payload (`@fence` was removed from Zig) |

## Real-time by construction

The port deliberately hardens the hot paths beyond the Rust original (same observable
semantics, better behaviour under load) — and `zig build bench` keeps the numbers honest:

* **Zero-allocation publish in steady state.** An envelope is one contiguous slab
  (header + strings) drawn from a size-classed recycler (`pool.zig`, lock-free Vyukov MPMC
  free rings, ~3 MiB fixed ceiling). `LocalBus.prewarmEnvelopes` covers even the first
  burst. The bench *counts allocator calls* to prove the zero.
* **Lock-free data plane.** `media.latest` is a wait-free triple buffer (send = one store
  + one swap); `media.bounded` is a Lamport SPSC ring with cached indices à la Rigtorp.
  No mutex anywhere media flows.
* **No head-of-line blocking.** The `.block` fan-out sweeps all subscribers with
  non-blocking pushes and waits on a bus-wide "space freed" eventcount — a slow consumer
  never delays the fast ones (Rust pushes sequentially).
* **Syscall-free when busy.** Every wait/notify signal is waiter-gated (notify with
  nobody parked = one atomic add) and waiters spin-then-park (~1 µs spin window before the
  futex), so a streaming pipeline crosses the kernel only when genuinely idle. Blocked
  publishers are woken at a half-drained low-water mark and refill in bursts.

Indicative numbers (4-core Linux box, ReleaseFast): publish→recv RTT p50 ≈ 0.5 µs,
`latest` freshness p99 ≈ 0.3 µs, bounded SPSC ≈ 20 M items/s, **0 allocator calls per
million publishes** after prewarm. Run `zig build bench` on your hardware for real ones.

**Interop:** the wire formats are byte-compatible with Micro across every seam — the
bridge framing, the ipc JSON-lines and postcard codecs (postcard's LEB128 string encoding
is reimplemented and locked by a test), and the shmem slot layout/naming (`/dev/shm`, the
same object a Rust `shm_open` peer maps). A zicro process can talk to a Micro process
today.

The shmem slot now has a backend per OS — `/dev/shm` on Linux (the interop-compatible
path, with the orphan sweeper), POSIX `shm_open` on macOS, and a `Local\` section object on
Windows — behind one portable seqlock. Linux is runtime-tested here; the macOS/Windows
backends are compile-checked via cross-compilation (a native run needs the respective host).

Out of scope for the port (deliberately): the optional `cpal` audio device backend (the
`AudioOut` contract is the extension point) and the `micro-stems` showcase app (it
orchestrates external Demucs/basic-pitch subprocesses).

---

<sub>Ported from Rust 🦀 to Zig ⚡ — same skeleton, explicit memory.</sub>

---

## License

`zicro` is **dual-licensed** — pick the one that fits you:

- **Open source** · GNU **AGPL v3.0** (see [`LICENSE`](LICENSE)). Free to use, study and
  modify, but derivative works — **including services offered over a network** — must also be
  released under the AGPLv3 with complete source available.
- **Commercial** · for use in a **proprietary / closed-source** product, without the AGPL
  copyleft, buy a commercial license from the author. See [`LICENSING.md`](LICENSING.md) —
  contact **Francesco Magazzù** <magazzu.francesco@gmail.com>.

© 2026 Francesco Magazzù.
