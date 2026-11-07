/* WASAPI shared-mode output for zicro.audio_device on Windows.
 *
 * The device contract is the blocking one of audio_device.zig: write() queues interleaved
 * f32 frames and waits for room (backpressure), latency() says how many frames are between
 * the newest submitted sample and the speaker. WASAPI is pull-friendly but also offers
 * exactly that: GetCurrentPadding() = frames queued and not yet played, plus the engine's
 * stream latency. The engine converts rate and channel layout (AUTOCONVERTPCM), so the
 * producer keeps rendering at the rate it asked for, like on PipeWire.
 *
 * Device changes: the stream follows the DEFAULT output endpoint. An IMMNotificationClient
 * flags default-device changes, and an invalidated device (unplugged headset, disabled
 * endpoint, audio service restart) shows up as AUDCLNT_E_DEVICE_INVALIDATED from any call;
 * either way the next write() reopens on the current default and carries on. While no
 * device exists at all, writes drop their block after a bounded wait, so the producer
 * thread never hangs (same policy as the waveOut backend).
 *
 * Written in C because the COM vtables come straight from the MinGW headers (COBJMACROS):
 * hand-declaring IAudioClient & co. in Zig would be several hundred lines of offsets. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <functiondiscoverykeys_devpkey.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* GUIDs defined here so nothing depends on libuuid/ksuser symbols. */
static const GUID zCLSID_MMDeviceEnumerator = {0xbcde0395, 0xe52f, 0x467c, {0x8e, 0x3d, 0xc4, 0x57, 0x92, 0x91, 0x69, 0x2e}};
static const GUID zIID_IMMDeviceEnumerator = {0xa95664d2, 0x9614, 0x4f35, {0xa7, 0x46, 0xde, 0x8d, 0xb6, 0x36, 0x17, 0xe6}};
static const GUID zIID_IMMNotificationClient = {0x7991eec9, 0x7e89, 0x4d85, {0x83, 0x90, 0x6c, 0x70, 0x3c, 0xec, 0x60, 0xc0}};
static const GUID zIID_IAudioClient = {0x1cb9ad4c, 0xdbfa, 0x4c32, {0xb1, 0x78, 0xc2, 0xf5, 0x68, 0xa7, 0x03, 0xb2}};
static const GUID zIID_IAudioRenderClient = {0xf294acfc, 0x3146, 0x4483, {0xa7, 0xbf, 0xad, 0xdc, 0xa7, 0xc2, 0x60, 0xe2}};
static const GUID zIID_IUnknown = {0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};
static const GUID zKSDATAFORMAT_SUBTYPE_IEEE_FLOAT = {0x00000003, 0x0000, 0x0010, {0x80, 0x00, 0x00, 0xaa, 0x00, 0x38, 0x9b, 0x71}};
static const PROPERTYKEY zPKEY_Device_FriendlyName = {{0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 14};

#ifndef AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM
#define AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM 0x80000000
#endif
#ifndef AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY
#define AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY 0x08000000
#endif

/* ── Default-device change notifications ─────────────────────────────────────────────── */

typedef struct {
    IMMNotificationClient iface; /* first: the COM pointer IS the struct pointer */
    volatile LONG refs;
    volatile LONG default_changed;
} Notifier;

static HRESULT STDMETHODCALLTYPE n_qi(IMMNotificationClient *t, REFIID riid, void **out) {
    if (IsEqualIID(riid, &zIID_IUnknown) || IsEqualIID(riid, &zIID_IMMNotificationClient)) {
        *out = t;
        InterlockedIncrement(&((Notifier *)t)->refs);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE n_addref(IMMNotificationClient *t) { return (ULONG)InterlockedIncrement(&((Notifier *)t)->refs); }
static ULONG STDMETHODCALLTYPE n_release(IMMNotificationClient *t) {
    LONG r = InterlockedDecrement(&((Notifier *)t)->refs);
    if (r == 0) free(t);
    return (ULONG)r;
}
static HRESULT STDMETHODCALLTYPE n_state(IMMNotificationClient *t, LPCWSTR id, DWORD st) { (void)t; (void)id; (void)st; return S_OK; }
static HRESULT STDMETHODCALLTYPE n_added(IMMNotificationClient *t, LPCWSTR id) { (void)t; (void)id; return S_OK; }
static HRESULT STDMETHODCALLTYPE n_removed(IMMNotificationClient *t, LPCWSTR id) { (void)t; (void)id; return S_OK; }
static HRESULT STDMETHODCALLTYPE n_default(IMMNotificationClient *t, EDataFlow flow, ERole role, LPCWSTR id) {
    (void)id;
    if (flow == eRender && role == eConsole) InterlockedExchange(&((Notifier *)t)->default_changed, 1);
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE n_prop(IMMNotificationClient *t, LPCWSTR id, const PROPERTYKEY key) { (void)t; (void)id; (void)key; return S_OK; }
static IMMNotificationClientVtbl notifier_vtbl = {n_qi, n_addref, n_release, n_state, n_added, n_removed, n_default, n_prop};

/* ── Output stream ───────────────────────────────────────────────────────────────────── */

typedef struct {
    unsigned rate, channels;
    IMMDeviceEnumerator *en;
    Notifier *notifier;
    IAudioClient *client;     /* NULL while no device could be opened */
    IAudioRenderClient *render;
    HANDLE event;
    UINT32 buffer_frames;
    UINT32 stream_latency;    /* frames */
    int started;
    unsigned reopens;
} ZwOut;

static void release_stream(ZwOut *o) {
    if (o->client && o->started) IAudioClient_Stop(o->client);
    if (o->render) IAudioRenderClient_Release(o->render);
    if (o->client) IAudioClient_Release(o->client);
    o->render = NULL;
    o->client = NULL;
    o->started = 0;
}

/* (Re)open the stream on the current default render endpoint. 0 = ok. */
static int open_stream(ZwOut *o) {
    IMMDevice *dev = NULL;
    if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(o->en, eRender, eConsole, &dev))) return -1;
    HRESULT hr = IMMDevice_Activate(dev, &zIID_IAudioClient, CLSCTX_ALL, NULL, (void **)&o->client);
    IMMDevice_Release(dev);
    if (FAILED(hr)) { o->client = NULL; return -1; }

    WAVEFORMATEXTENSIBLE wf;
    memset(&wf, 0, sizeof wf);
    wf.Format.wFormatTag = WAVE_FORMAT_EXTENSIBLE;
    wf.Format.nChannels = (WORD)o->channels;
    wf.Format.nSamplesPerSec = o->rate;
    wf.Format.wBitsPerSample = 32;
    wf.Format.nBlockAlign = (WORD)(o->channels * 4);
    wf.Format.nAvgBytesPerSec = o->rate * wf.Format.nBlockAlign;
    wf.Format.cbSize = sizeof(WAVEFORMATEXTENSIBLE) - sizeof(WAVEFORMATEX);
    wf.Samples.wValidBitsPerSample = 32;
    wf.dwChannelMask = o->channels == 1 ? SPEAKER_FRONT_CENTER : o->channels == 2 ? (SPEAKER_FRONT_LEFT | SPEAKER_FRONT_RIGHT) : 0;
    wf.SubFormat = zKSDATAFORMAT_SUBTYPE_IEEE_FLOAT;

    /* 100 ms of engine buffer: deep enough not to underrun when a decode stalls a frame,
     * and latency() reports it exactly, so A/V sync does not depend on it being small. */
    const REFERENCE_TIME dur = 1000000;
    DWORD flags = AUDCLNT_STREAMFLAGS_EVENTCALLBACK | AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM | AUDCLNT_STREAMFLAGS_SRC_DEFAULT_QUALITY;
    hr = IAudioClient_Initialize(o->client, AUDCLNT_SHAREMODE_SHARED, flags, dur, 0, (WAVEFORMATEX *)&wf, NULL);
    if (FAILED(hr)) goto fail;
    if (FAILED(IAudioClient_SetEventHandle(o->client, o->event))) goto fail;
    if (FAILED(IAudioClient_GetBufferSize(o->client, &o->buffer_frames))) goto fail;
    REFERENCE_TIME lat = 0;
    if (SUCCEEDED(IAudioClient_GetStreamLatency(o->client, &lat)))
        o->stream_latency = (UINT32)((uint64_t)lat * o->rate / 10000000ull);
    if (FAILED(IAudioClient_GetService(o->client, &zIID_IAudioRenderClient, (void **)&o->render))) goto fail;
    return 0;
fail:
    release_stream(o);
    return -1;
}

void *zicro_wasapi_open(unsigned rate, unsigned channels) {
    if (rate == 0 || channels == 0 || channels > 8) return NULL;
    CoInitializeEx(NULL, COINIT_MULTITHREADED); /* S_FALSE / RPC_E_CHANGED_MODE are fine */
    ZwOut *o = (ZwOut *)calloc(1, sizeof *o);
    if (!o) return NULL;
    o->rate = rate;
    o->channels = channels;
    o->event = CreateEventW(NULL, FALSE, FALSE, NULL);
    if (!o->event) goto fail;
    if (FAILED(CoCreateInstance(&zCLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &zIID_IMMDeviceEnumerator, (void **)&o->en))) goto fail;
    Notifier *n = (Notifier *)calloc(1, sizeof *n);
    if (n) {
        n->iface.lpVtbl = &notifier_vtbl;
        n->refs = 1;
        if (SUCCEEDED(IMMDeviceEnumerator_RegisterEndpointNotificationCallback(o->en, &n->iface))) o->notifier = n;
        else free(n);
    }
    /* No device at open time = OpenFailed (the caller may fall back or stay silent). */
    if (open_stream(o) != 0) goto fail;
    return o;
fail:
    if (o->notifier) {
        IMMDeviceEnumerator_UnregisterEndpointNotificationCallback(o->en, &o->notifier->iface);
        IMMNotificationClient_Release(&o->notifier->iface);
    }
    if (o->en) IMMDeviceEnumerator_Release(o->en);
    if (o->event) CloseHandle(o->event);
    free(o);
    return NULL;
}

static int is_lost(HRESULT hr) {
    return hr == AUDCLNT_E_DEVICE_INVALIDATED || hr == AUDCLNT_E_SERVICE_NOT_RUNNING || hr == AUDCLNT_E_RESOURCES_INVALIDATED;
}

/* Reopen on the current default endpoint after a loss or a default change. */
static int reopen(ZwOut *o) {
    release_stream(o);
    o->reopens++;
    return open_stream(o);
}

/* Blocking write of `frames` interleaved f32 frames. Returns 0 when queued, 1 when the
 * block was dropped (no usable device within the wait budget). */
int zicro_wasapi_write(void *h, const float *samples, unsigned frames) {
    ZwOut *o = (ZwOut *)h;
    CoInitializeEx(NULL, COINIT_MULTITHREADED); /* the producer may be another thread */
    unsigned done = 0;
    DWORD waited = 0;
    while (done < frames) {
        if (o->notifier && InterlockedExchange(&o->notifier->default_changed, 0)) reopen(o);
        if (!o->client && reopen(o) != 0) {
            /* No device right now: wait a little, give up on this block after ~2 s. */
            if (waited >= 2000) return 1;
            Sleep(50);
            waited += 50;
            continue;
        }
        UINT32 padding = 0;
        HRESULT hr = IAudioClient_GetCurrentPadding(o->client, &padding);
        if (is_lost(hr)) { release_stream(o); continue; }
        if (FAILED(hr)) return 1;
        UINT32 room = o->buffer_frames > padding ? o->buffer_frames - padding : 0;
        if (room == 0) {
            if (!o->started) { /* buffer full before start: start now */
                if (FAILED(IAudioClient_Start(o->client))) return 1;
                o->started = 1;
            }
            if (WaitForSingleObject(o->event, 200) == WAIT_TIMEOUT) {
                waited += 200;
                if (waited >= 2000) return 1; /* engine not draining: drop, stay responsive */
            }
            continue;
        }
        UINT32 n = frames - done < room ? frames - done : room;
        BYTE *buf = NULL;
        hr = IAudioRenderClient_GetBuffer(o->render, n, &buf);
        if (is_lost(hr)) { release_stream(o); continue; }
        if (FAILED(hr)) return 1;
        memcpy(buf, samples + (size_t)done * o->channels, (size_t)n * o->channels * 4);
        hr = IAudioRenderClient_ReleaseBuffer(o->render, n, 0);
        if (is_lost(hr)) { release_stream(o); continue; }
        done += n;
        if (!o->started) {
            if (FAILED(IAudioClient_Start(o->client))) return 1;
            o->started = 1;
        }
    }
    return 0;
}

/* Frames between the newest submitted sample and the speaker, or -1 without a device. */
int zicro_wasapi_latency(void *h) {
    ZwOut *o = (ZwOut *)h;
    if (!o->client) return -1;
    UINT32 padding = 0;
    if (FAILED(IAudioClient_GetCurrentPadding(o->client, &padding))) return -1;
    return (int)(padding + o->stream_latency);
}

unsigned zicro_wasapi_reopens(void *h) { return ((ZwOut *)h)->reopens; }

void zicro_wasapi_close(void *h) {
    ZwOut *o = (ZwOut *)h;
    if (!o) return;
    release_stream(o);
    if (o->notifier) {
        IMMDeviceEnumerator_UnregisterEndpointNotificationCallback(o->en, &o->notifier->iface);
        IMMNotificationClient_Release(&o->notifier->iface);
    }
    if (o->en) IMMDeviceEnumerator_Release(o->en);
    if (o->event) CloseHandle(o->event);
    free(o);
}

/* Active render endpoints, for diagnostics: "name\n" lines into `out` (UTF-8), the default
 * one prefixed with "* ". Returns the number of endpoints, -1 if WASAPI is unavailable. */
int zicro_wasapi_list(char *out, int cap) {
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IMMDeviceEnumerator *en = NULL;
    if (FAILED(CoCreateInstance(&zCLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &zIID_IMMDeviceEnumerator, (void **)&en))) return -1;
    WCHAR *def_id = NULL;
    IMMDevice *def = NULL;
    if (SUCCEEDED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eRender, eConsole, &def))) {
        IMMDevice_GetId(def, &def_id);
        IMMDevice_Release(def);
    }
    IMMDeviceCollection *col = NULL;
    int count = 0, len = 0;
    if (cap > 0) out[0] = 0;
    if (SUCCEEDED(IMMDeviceEnumerator_EnumAudioEndpoints(en, eRender, DEVICE_STATE_ACTIVE, &col))) {
        UINT n = 0;
        IMMDeviceCollection_GetCount(col, &n);
        for (UINT i = 0; i < n; i++) {
            IMMDevice *d = NULL;
            if (FAILED(IMMDeviceCollection_Item(col, i, &d))) continue;
            WCHAR *id = NULL;
            IMMDevice_GetId(d, &id);
            IPropertyStore *ps = NULL;
            char name[256] = "?";
            if (SUCCEEDED(IMMDevice_OpenPropertyStore(d, STGM_READ, &ps))) {
                PROPVARIANT v;
                PropVariantInit(&v);
                if (SUCCEEDED(IPropertyStore_GetValue(ps, &zPKEY_Device_FriendlyName, &v)) && v.vt == VT_LPWSTR)
                    WideCharToMultiByte(CP_UTF8, 0, v.pwszVal, -1, name, sizeof name, NULL, NULL);
                PropVariantClear(&v);
                IPropertyStore_Release(ps);
            }
            int is_def = def_id && id && wcscmp(def_id, id) == 0;
            if (cap > 0 && len < cap - 1) {
                int w = snprintf(out + len, (size_t)(cap - len), "%s%s\n", is_def ? "* " : "  ", name);
                if (w > 0) len = len + w < cap ? len + w : cap - 1;
            }
            if (id) CoTaskMemFree(id);
            IMMDevice_Release(d);
            count++;
        }
        IMMDeviceCollection_Release(col);
    }
    if (def_id) CoTaskMemFree(def_id);
    IMMDeviceEnumerator_Release(en);
    return count;
}

/* ── Loopback capture (tests) ────────────────────────────────────────────────────────────
 * Records what the default render endpoint is PLAYING (the shared-mode mix), so a test can
 * prove that samples written through zicro_wasapi_write actually reached the device mix:
 * not just "the clock advanced" but "this tone came out". Polling, no thread: the caller
 * drains it with zicro_wasapi_loop_read while its player runs on another thread. */
static const GUID zIID_IAudioCaptureClient = {0xc8adbd64, 0xe71e, 0x48a0, {0xa4, 0xde, 0x18, 0x5c, 0x39, 0x5c, 0xd3, 0x17}};

typedef struct {
    IAudioClient *client;
    IAudioCaptureClient *cap;
    unsigned rate, channels;
} ZwLoop;

void *zicro_wasapi_loop_open(unsigned *rate, unsigned *channels) {
    CoInitializeEx(NULL, COINIT_MULTITHREADED);
    IMMDeviceEnumerator *en = NULL;
    IMMDevice *dev = NULL;
    WAVEFORMATEX *mix = NULL;
    ZwLoop *l = (ZwLoop *)calloc(1, sizeof *l);
    if (!l) return NULL;
    if (FAILED(CoCreateInstance(&zCLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, &zIID_IMMDeviceEnumerator, (void **)&en))) goto fail;
    if (FAILED(IMMDeviceEnumerator_GetDefaultAudioEndpoint(en, eRender, eConsole, &dev))) goto fail;
    if (FAILED(IMMDevice_Activate(dev, &zIID_IAudioClient, CLSCTX_ALL, NULL, (void **)&l->client))) goto fail;
    if (FAILED(IAudioClient_GetMixFormat(l->client, &mix))) goto fail;
    /* The shared-mode mix is float32 on every Windows since Vista; anything else: no test. */
    int is_float = mix->wFormatTag == WAVE_FORMAT_IEEE_FLOAT ||
                   (mix->wFormatTag == WAVE_FORMAT_EXTENSIBLE &&
                    IsEqualGUID(&((WAVEFORMATEXTENSIBLE *)mix)->SubFormat, &zKSDATAFORMAT_SUBTYPE_IEEE_FLOAT));
    if (!is_float || mix->wBitsPerSample != 32) goto fail;
    if (FAILED(IAudioClient_Initialize(l->client, AUDCLNT_SHAREMODE_SHARED, AUDCLNT_STREAMFLAGS_LOOPBACK, 2000000, 0, mix, NULL))) goto fail;
    if (FAILED(IAudioClient_GetService(l->client, &zIID_IAudioCaptureClient, (void **)&l->cap))) goto fail;
    if (FAILED(IAudioClient_Start(l->client))) goto fail;
    l->rate = mix->nSamplesPerSec;
    l->channels = mix->nChannels;
    *rate = l->rate;
    *channels = l->channels;
    CoTaskMemFree(mix);
    IMMDevice_Release(dev);
    IMMDeviceEnumerator_Release(en);
    return l;
fail:
    if (mix) CoTaskMemFree(mix);
    if (l->cap) IAudioCaptureClient_Release(l->cap);
    if (l->client) IAudioClient_Release(l->client);
    if (dev) IMMDevice_Release(dev);
    if (en) IMMDeviceEnumerator_Release(en);
    free(l);
    return NULL;
}

/* Drains every captured packet into `out` as MONO (channel average). Returns samples read
 * (≤ cap), or -1 on a capture error. Silent packets (AUDCLNT_BUFFERFLAGS_SILENT) are zeros. */
int zicro_wasapi_loop_read(void *h, float *out, int cap) {
    ZwLoop *l = (ZwLoop *)h;
    int got = 0;
    for (;;) {
        UINT32 next = 0;
        if (FAILED(IAudioCaptureClient_GetNextPacketSize(l->cap, &next))) return -1;
        if (next == 0) break;
        BYTE *data = NULL;
        UINT32 frames = 0;
        DWORD flags = 0;
        if (FAILED(IAudioCaptureClient_GetBuffer(l->cap, &data, &frames, &flags, NULL, NULL))) return -1;
        const float *f = (const float *)data;
        for (UINT32 i = 0; i < frames && got < cap; i++) {
            float m = 0;
            if (!(flags & AUDCLNT_BUFFERFLAGS_SILENT))
                for (unsigned c = 0; c < l->channels; c++) m += f[(size_t)i * l->channels + c];
            out[got++] = m / (float)l->channels;
        }
        IAudioCaptureClient_ReleaseBuffer(l->cap, frames);
    }
    return got;
}

void zicro_wasapi_loop_close(void *h) {
    ZwLoop *l = (ZwLoop *)h;
    if (!l) return;
    IAudioClient_Stop(l->client);
    IAudioCaptureClient_Release(l->cap);
    IAudioClient_Release(l->client);
    free(l);
}
