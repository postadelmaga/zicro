// zicro_pw — a tiny blocking bridge over PipeWire's pull-model pw_stream.
//
// The rest of zicro's audio backends (ALSA, winmm) expose a *blocking* push/pull contract:
// DeviceOut.play(samples) blocks until the hardware accepts the block, DeviceIn.capture(buf)
// blocks until samples arrive. PipeWire is the opposite shape — a realtime callback pulls
// (or pushes) buffers on its own thread. This shim reconciles the two with one ring buffer
// per stream, guarded by a mutex + condvars, so the Zig side keeps the same simple contract
// while getting PipeWire's low-latency graph. SPA format PODs are built here, in C, where the
// vendor macros live — that's the whole reason this is a C file and not more Zig externs.
//
// Realtime note: the process callback briefly takes the ring mutex. At audio block sizes the
// critical section is a memcpy of a few hundred floats — fine for monitoring latency and far
// simpler than a lock-free ring. A future pass can swap in an SPSC ring if profiling asks.

#include <pipewire/pipewire.h>
#include <spa/param/audio/format-utils.h>
#include <spa/pod/builder.h>

#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// One quantum hint (frames) — asks the graph for a small buffer so latency stays low. The
// ring holds a few of these so jitter doesn't underrun before the writer refills.
#define ZICRO_PW_QUANTUM 256
#define ZICRO_PW_RING_QUANTA 8

struct zicro_pw {
    struct pw_thread_loop *loop;
    struct pw_stream *stream;
    uint16_t channels;
    int capture; // 0 = playback, 1 = capture

    // Ring of interleaved f32 samples (not frames), size = cap.
    float *ring;
    size_t cap;   // total slots
    size_t head;  // read index (consumer)
    size_t tail;  // write index (producer)
    size_t count; // occupied slots
    int stop;

    pthread_mutex_t mtx;
    pthread_cond_t not_full;  // signalled when space frees up
    pthread_cond_t not_empty; // signalled when data arrives
};

// pw_init is process-global and must run exactly once before any other pw call.
static pthread_once_t g_pw_once = PTHREAD_ONCE_INIT;
static void pw_init_once(void) { pw_init(NULL, NULL); }

// ── playback: RT thread pulls, drains the ring, silence-fills on underrun ────
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
    // Honour the graph's requested frame count when it asks for fewer (keeps latency tight).
    if (pb->requested && pb->requested < n_frames) n_frames = (uint32_t)pb->requested;
    uint32_t n = n_frames * pw->channels;

    pthread_mutex_lock(&pw->mtx);
    uint32_t i = 0;
    for (; i < n && pw->count > 0; i++) {
        dst[i] = pw->ring[pw->head];
        pw->head = (pw->head + 1) % pw->cap;
        pw->count--;
    }
    pthread_cond_signal(&pw->not_full);
    pthread_mutex_unlock(&pw->mtx);
    for (; i < n; i++) dst[i] = 0.0f; // underrun → silence, never a stale buffer

    buf->datas[0].chunk->offset = 0;
    buf->datas[0].chunk->stride = stride;
    buf->datas[0].chunk->size = n_frames * stride;
    pw_stream_queue_buffer(pw->stream, pb);
}

// ── capture: RT thread pushes incoming samples into the ring, drops on overrun ─
static void on_process_capture(void *userdata) {
    struct zicro_pw *pw = userdata;
    struct pw_buffer *pb = pw_stream_dequeue_buffer(pw->stream);
    if (!pb) return;
    struct spa_buffer *buf = pb->buffer;
    const float *src = buf->datas[0].data;
    if (src) {
        uint32_t stride = sizeof(float) * pw->channels;
        uint32_t offset = SPA_MIN(buf->datas[0].chunk->offset, buf->datas[0].maxsize);
        uint32_t size = SPA_MIN(buf->datas[0].chunk->size, buf->datas[0].maxsize - offset);
        uint32_t n = size / sizeof(float);
        src = (const float *)((const uint8_t *)src + offset);
        (void)stride;
        pthread_mutex_lock(&pw->mtx);
        for (uint32_t i = 0; i < n; i++) {
            if (pw->count == pw->cap) break; // overrun → drop oldest-tail-first (just stop)
            pw->ring[pw->tail] = src[i];
            pw->tail = (pw->tail + 1) % pw->cap;
            pw->count++;
        }
        pthread_cond_signal(&pw->not_empty);
        pthread_mutex_unlock(&pw->mtx);
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
    pthread_mutex_init(&pw->mtx, NULL);
    pthread_cond_init(&pw->not_full, NULL);
    pthread_cond_init(&pw->not_empty, NULL);

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
    pthread_mutex_destroy(&pw->mtx);
    pthread_cond_destroy(&pw->not_full);
    pthread_cond_destroy(&pw->not_empty);
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

// Blocking write: enqueue every sample, waiting for ring space (backpressure). Returns 0 on
// success, -1 if the stream is closing.
int zicro_pw_write(struct zicro_pw *pw, const float *src, size_t frames) {
    size_t n = frames * pw->channels;
    size_t off = 0;
    pthread_mutex_lock(&pw->mtx);
    while (off < n) {
        while (pw->count == pw->cap && !pw->stop)
            pthread_cond_wait(&pw->not_full, &pw->mtx);
        if (pw->stop) {
            pthread_mutex_unlock(&pw->mtx);
            return -1;
        }
        while (off < n && pw->count < pw->cap) {
            pw->ring[pw->tail] = src[off++];
            pw->tail = (pw->tail + 1) % pw->cap;
            pw->count++;
        }
        pthread_cond_signal(&pw->not_empty);
    }
    pthread_mutex_unlock(&pw->mtx);
    return 0;
}

// Blocking read: wait for at least one sample, then drain up to `frames` frames. Returns the
// number of *frames* read (0 only if the stream is closing).
size_t zicro_pw_read(struct zicro_pw *pw, float *dst, size_t frames) {
    size_t want = frames * pw->channels;
    pthread_mutex_lock(&pw->mtx);
    while (pw->count == 0 && !pw->stop)
        pthread_cond_wait(&pw->not_empty, &pw->mtx);
    if (pw->stop && pw->count == 0) {
        pthread_mutex_unlock(&pw->mtx);
        return 0;
    }
    size_t got = 0;
    while (got < want && pw->count > 0) {
        dst[got++] = pw->ring[pw->head];
        pw->head = (pw->head + 1) % pw->cap;
        pw->count--;
    }
    pthread_cond_signal(&pw->not_full);
    pthread_mutex_unlock(&pw->mtx);
    return got / (pw->channels ? pw->channels : 1);
}

void zicro_pw_close(struct zicro_pw *pw) {
    if (!pw) return;
    pthread_mutex_lock(&pw->mtx);
    pw->stop = 1;
    pthread_cond_broadcast(&pw->not_full);
    pthread_cond_broadcast(&pw->not_empty);
    pthread_mutex_unlock(&pw->mtx);

    if (pw->loop) pw_thread_loop_stop(pw->loop);
    if (pw->stream) pw_stream_destroy(pw->stream);
    if (pw->loop) pw_thread_loop_destroy(pw->loop);
    pthread_mutex_destroy(&pw->mtx);
    pthread_cond_destroy(&pw->not_full);
    pthread_cond_destroy(&pw->not_empty);
    free(pw->ring);
    free(pw);
}
