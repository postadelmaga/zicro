// zicro_pw — a tiny blocking bridge over PipeWire's pull-model pw_stream.
//
// The rest of zicro's audio backends (ALSA, winmm) expose a *blocking* push/pull contract:
// DeviceOut.play(samples) blocks until the hardware accepts the block, DeviceIn.capture(buf)
// blocks until samples arrive. PipeWire is the opposite shape — a realtime callback pulls
// (or pushes) buffers on its own thread. This shim reconciles the two with one **lock-free
// SPSC ring** per stream, so the realtime callback never takes a lock and never blocks; the
// application thread does the waiting (a short adaptive backoff) when the ring is full/empty.
// SPSC holds because each stream has exactly one producer and one consumer:
//   * playback — producer = app (`zicro_pw_write`), consumer = the RT callback.
//   * capture  — producer = the RT callback, consumer = app (`zicro_pw_read`).
//
// Free-running counters (`head`, `tail`) index the ring modulo its size; occupancy is
// `tail - head`. Only the producer writes `tail`, only the consumer writes `head`, each with
// release/acquire ordering — the classic wait-free Lamport queue. SPA format PODs are built
// here, in C, where the vendor macros live — the whole reason this is a C file.
//
// Overrun/underrun policy:
//   * playback underrun (ring empty at callback time) → emit silence, never a stale buffer.
//   * capture  overrun  (app fell behind) → the producer keeps writing (advancing `tail`);
//     the consumer notices `tail - head > cap` and skips ahead to `tail - cap`, dropping the
//     *oldest* samples so latency stays bounded (drop-oldest, the right choice for a live
//     monitor). Only the consumer moves `head`, so this stays SPSC-clean.

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

// One quantum hint (frames) — asks the graph for a small buffer so latency stays low. The
// ring holds a few of these so jitter doesn't underrun before the app refills.
// RING_QUANTA governs the app-side output buffer (≈ QUANTUM×RING_QUANTA/rate): backpressure
// keeps it near-full, so it IS the steady-state output latency. 4 quanta ≈ 21 ms — bassa
// latenza per il player/oscilloscopio; alzarlo se un sistema lento produce crackle/underrun.
#define ZICRO_PW_QUANTUM 256
#define ZICRO_PW_RING_QUANTA 4

struct zicro_pw {
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    uint16_t channels;
    int capture; // 0 = playback, 1 = capture

    // Lock-free SPSC ring of interleaved f32 samples (not frames). `cap` is the slot count.
    float *ring;
    size_t cap;
    _Atomic size_t head; // consumer index (monotonic); occupancy = tail - head
    _Atomic size_t tail; // producer index (monotonic)
    _Atomic int stop;
};

// pw_init is process-global and must run exactly once before any other pw call.
static pthread_once_t g_pw_once = PTHREAD_ONCE_INIT;
static void pw_init_once(void) { pw_init(NULL, NULL); }

// App-side wait when the ring is full (write) or empty (read). ~200µs is well under an audio
// quantum (256/48k ≈ 5.3ms), so this costs a negligible slice of latency and little CPU.
static void backoff(void) {
    struct timespec ts = { .tv_sec = 0, .tv_nsec = 200000 };
    nanosleep(&ts, NULL);
}

// Contiguous ring copies: a transfer wraps at most once, so it's one or two memcpy()s — no
// per-sample division in the realtime path. `pos` is the logical (free-running) index; `n`
// must be ≤ cap so the copy wraps only once. Only the modulo for the start offset remains,
// once per call rather than once per sample.
static void ring_read(const struct zicro_pw *pw, size_t pos, float *dst, size_t n) {
    size_t start = pos % pw->cap;
    size_t first = pw->cap - start;
    if (first > n) first = n;
    memcpy(dst, &pw->ring[start], first * sizeof(float));
    if (n > first) memcpy(dst + first, &pw->ring[0], (n - first) * sizeof(float));
}
static void ring_write(struct zicro_pw *pw, size_t pos, const float *src, size_t n) {
    size_t start = pos % pw->cap;
    size_t first = pw->cap - start;
    if (first > n) first = n;
    memcpy(&pw->ring[start], src, first * sizeof(float));
    if (n > first) memcpy(&pw->ring[0], src + first, (n - first) * sizeof(float));
}

// ── playback: RT thread consumes the ring, silence-fills on underrun ─────────
static void on_process_playback(void *userdata) {
    struct zicro_pw *pw = userdata;
    struct pw_buffer *pb = pw_stream_dequeue_buffer(pw->stream);
    if (!pb) return;
    struct spa_buffer *buf = pb->buffer;
    float *dst = buf->datas[0].data;
    if (!dst) {
        pw_stream_queue_buffer(pw->stream, pb);
        return;
    }
    uint32_t stride = sizeof(float) * pw->channels;
    uint32_t max_frames = buf->datas[0].maxsize / stride;
    uint32_t n_frames = max_frames;
    if (pb->requested && pb->requested < n_frames) n_frames = (uint32_t)pb->requested;
    uint32_t n = n_frames * pw->channels;

    size_t h = atomic_load_explicit(&pw->head, memory_order_relaxed); // consumer owns head
    size_t t = atomic_load_explicit(&pw->tail, memory_order_acquire);
    size_t avail = t - h;
    uint32_t give = (avail < n) ? (uint32_t)avail : n;
    ring_read(pw, h, dst, give);
    atomic_store_explicit(&pw->head, h + give, memory_order_release);
    for (uint32_t i = give; i < n; i++) dst[i] = 0.0f; // underrun → silence

    buf->datas[0].chunk->offset = 0;
    buf->datas[0].chunk->stride = stride;
    buf->datas[0].chunk->size = n_frames * stride;
    pw_stream_queue_buffer(pw->stream, pb);
}

// ── capture: RT thread produces into the ring, overwriting on overrun ────────
static void on_process_capture(void *userdata) {
    struct zicro_pw *pw = userdata;
    struct pw_buffer *pb = pw_stream_dequeue_buffer(pw->stream);
    if (!pb) return;
    struct spa_buffer *buf = pb->buffer;
    const float *src = buf->datas[0].data;
    if (src) {
        uint32_t offset = SPA_MIN(buf->datas[0].chunk->offset, buf->datas[0].maxsize);
        uint32_t size = SPA_MIN(buf->datas[0].chunk->size, buf->datas[0].maxsize - offset);
        uint32_t n = size / sizeof(float);
        src = (const float *)((const uint8_t *)src + offset);

        // Producer owns tail: write every incoming sample and advance, even past the
        // consumer's head. The consumer detects the overrun and drops the oldest — so the RT
        // thread never blocks and latency stays bounded. A batch bigger than the whole ring
        // (never in practice — a quantum ≪ cap) keeps only its freshest `cap` samples so the
        // single-wrap copy stays valid.
        if (n > pw->cap) { src += (n - pw->cap); n = (uint32_t)pw->cap; }
        size_t t = atomic_load_explicit(&pw->tail, memory_order_relaxed);
        ring_write(pw, t, src, n);
        atomic_store_explicit(&pw->tail, t + n, memory_order_release);
    }
    pw_stream_queue_buffer(pw->stream, pb);
}

static const struct pw_stream_events playback_events = {
    PW_VERSION_STREAM_EVENTS,
    .process = on_process_playback,
};
static const struct pw_stream_events capture_events = {
    PW_VERSION_STREAM_EVENTS,
    .process = on_process_capture,
};

static struct zicro_pw *pw_open(uint32_t rate, uint16_t channels, int capture) {
    pthread_once(&g_pw_once, pw_init_once);

    struct zicro_pw *pw = calloc(1, sizeof(*pw));
    if (!pw) return NULL;
    pw->channels = channels ? channels : 1;
    pw->capture = capture;
    pw->cap = (size_t)pw->channels * ZICRO_PW_QUANTUM * ZICRO_PW_RING_QUANTA;
    pw->ring = calloc(pw->cap, sizeof(float));
    if (!pw->ring) { free(pw); return NULL; }
    atomic_init(&pw->head, 0);
    atomic_init(&pw->tail, 0);
    atomic_init(&pw->stop, 0);

    pw->loop = pw_thread_loop_new("zicro-pw", NULL);
    if (!pw->loop) goto fail;

    char latency[64];
    snprintf(latency, sizeof(latency), "%d/%u", ZICRO_PW_QUANTUM, rate);
    struct pw_properties *props = pw_properties_new(
        PW_KEY_MEDIA_TYPE, "Audio",
        PW_KEY_MEDIA_CATEGORY, capture ? "Capture" : "Playback",
        PW_KEY_MEDIA_ROLE, "Production",
        PW_KEY_NODE_LATENCY, latency,
        NULL);

    pw->stream = pw_stream_new_simple(
        pw_thread_loop_get_loop(pw->loop),
        capture ? "zicro-capture" : "zicro-playback",
        props,
        capture ? &capture_events : &playback_events,
        pw);
    if (!pw->stream) goto fail;

    uint8_t podbuf[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(podbuf, sizeof(podbuf));
    struct spa_audio_info_raw info = {
        .format = SPA_AUDIO_FORMAT_F32,
        .rate = rate,
        .channels = channels,
    };
    const struct spa_pod *params[1];
    params[0] = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat, &info);

    int res = pw_stream_connect(
        pw->stream,
        capture ? PW_DIRECTION_INPUT : PW_DIRECTION_OUTPUT,
        PW_ID_ANY,
        PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS | PW_STREAM_FLAG_RT_PROCESS,
        params, 1);
    if (res < 0) goto fail;

    if (pw_thread_loop_start(pw->loop) < 0) goto fail;
    return pw;

fail:
    if (pw->stream) pw_stream_destroy(pw->stream);
    if (pw->loop) pw_thread_loop_destroy(pw->loop);
    free(pw->ring);
    free(pw);
    return NULL;
}

struct zicro_pw *zicro_pw_open_playback(uint32_t rate, uint16_t channels) {
    return pw_open(rate, channels, 0);
}
struct zicro_pw *zicro_pw_open_capture(uint32_t rate, uint16_t channels) {
    return pw_open(rate, channels, 1);
}

// Blocking write (playback): enqueue every sample losslessly, backing off while the ring is
// full (backpressure). Returns 0 on success, -1 if the stream is closing.
int zicro_pw_write(struct zicro_pw *pw, const float *src, size_t frames) {
    size_t n = frames * pw->channels;
    size_t off = 0;
    while (off < n) {
        if (atomic_load_explicit(&pw->stop, memory_order_acquire)) return -1;
        size_t t = atomic_load_explicit(&pw->tail, memory_order_relaxed); // producer owns tail
        size_t h = atomic_load_explicit(&pw->head, memory_order_acquire);
        size_t space = pw->cap - (t - h);
        if (space == 0) { backoff(); continue; }
        size_t chunk = (n - off < space) ? (n - off) : space;
        ring_write(pw, t, src + off, chunk);
        atomic_store_explicit(&pw->tail, t + chunk, memory_order_release);
        off += chunk;
    }
    return 0;
}

// Blocking read (capture): wait for data, then drain up to `frames` frames. On overrun
// (occupancy > cap) skip ahead to the freshest `cap` samples — drop-oldest. Returns the
// number of *frames* read (0 only if the stream is closing with nothing buffered).
size_t zicro_pw_read(struct zicro_pw *pw, float *dst, size_t frames) {
    size_t want = frames * pw->channels;
    while (1) {
        size_t h = atomic_load_explicit(&pw->head, memory_order_relaxed); // consumer owns head
        size_t t = atomic_load_explicit(&pw->tail, memory_order_acquire);
        size_t occ = t - h;
        if (occ == 0) {
            if (atomic_load_explicit(&pw->stop, memory_order_acquire)) return 0;
            backoff();
            continue;
        }
        if (occ > pw->cap) { // overrun: producer lapped us — drop the oldest, keep the fresh
            h = t - pw->cap;
            occ = pw->cap;
        }
        size_t give = (want < occ) ? want : occ;
        ring_read(pw, h, dst, give);
        atomic_store_explicit(&pw->head, h + give, memory_order_release);
        return give / (pw->channels ? pw->channels : 1);
    }
}

void zicro_pw_close(struct zicro_pw *pw) {
    if (!pw) return;
    atomic_store_explicit(&pw->stop, 1, memory_order_release); // wake a blocked app thread

    if (pw->loop) pw_thread_loop_stop(pw->loop);
    if (pw->stream) pw_stream_destroy(pw->stream);
    if (pw->loop) pw_thread_loop_destroy(pw->loop);
    free(pw->ring);
    free(pw);
}
