#include "OMTSDKBridge.h"
#include "libomt.h"
#include <dlfcn.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// NativeAOT libraries are process-lifetime mappings. Never dlclose their code.
static void *runtime, *codec;
static pthread_mutex_t loaderLock = PTHREAD_MUTEX_INITIALIZER;
static int loaded;
static char **(*discover)(int *);
static omt_receive_t *(*createReceiver)(const char *, OMTFrameType, OMTPreferredVideoFormat, OMTReceiveFlags);
static OMTMediaFrame *(*pollReceiver)(omt_receive_t *, OMTFrameType, int);
static void (*destroyReceiver)(omt_receive_t *);
static void (*setString)(const char *, const char *);
static void (*setLoggingFilename)(const char *);
static void (*shutdownRuntime)(void);

int omtr_load(const char *runtimePath, const char *codecPath, const char *storagePath,
              const char *server, char *error, size_t capacity) {
    pthread_mutex_lock(&loaderLock);
    if (loaded) { pthread_mutex_unlock(&loaderLock); return 1; }
    if (!runtimePath || !codecPath) {
        snprintf(error, capacity, "The bundled OMT runtime could not be found.");
        pthread_mutex_unlock(&loaderLock); return 0;
    }
    // Isolate this application's SDK settings/logs from eucaly and other tools.
    setenv("OMT_STORAGE_PATH", storagePath, 1);
    // A disconnected TCP peer should return EPIPE, never terminate the app.
    signal(SIGPIPE, SIG_IGN);
    if (!codec) codec = dlopen(codecPath, RTLD_NOW | RTLD_GLOBAL);
    if (codec && !runtime) runtime = dlopen(runtimePath, RTLD_NOW | RTLD_LOCAL);
    if (!runtime) {
        const char *detail = dlerror();
        snprintf(error, capacity, "The bundled OMT SDK could not load: %s", detail ? detail : "missing libvmx dependency");
        pthread_mutex_unlock(&loaderLock); return 0;
    }
#define LOAD(field, symbol) do { \
    *(void **)(&field) = dlsym(runtime, symbol); \
    if (!field) { snprintf(error, capacity, "The bundled OMT SDK is missing %s.", symbol); \
        pthread_mutex_unlock(&loaderLock); return 0; } \
} while (0)
    LOAD(discover, "omt_discovery_getaddresses");
    LOAD(createReceiver, "omt_receive_create");
    LOAD(pollReceiver, "omt_receive");
    LOAD(destroyReceiver, "omt_receive_destroy");
    LOAD(setString, "omt_settings_set_string");
    LOAD(setLoggingFilename, "omt_setloggingfilename");
    LOAD(shutdownRuntime, "omt_shutdown");
#undef LOAD
    setLoggingFilename(NULL);
    setString("DiscoveryServer", server ? server : "");
    loaded = 1;
    pthread_mutex_unlock(&loaderLock);
    return 1;
}
char **omtr_discover(int *count) { return discover ? discover(count) : NULL; }
void *omtr_receiver_create(const char *address) {
    return omtr_receiver_create_mode(address, 0);
}
void *omtr_receiver_create_mode(const char *address, int preview) {
    if (!createReceiver || !address || !address[0]) return NULL;
    OMTFrameType types = preview ? OMTFrameType_Video : (OMTFrameType_Video | OMTFrameType_Audio);
    OMTReceiveFlags flags = preview ? OMTReceiveFlags_Preview : OMTReceiveFlags_None;
    return createReceiver(address, types,
        OMTPreferredVideoFormat_UYVYorUYVAorP216orPA16, flags);
}
int omtr_receiver_poll(void *receiver, OMTRFrame *out, int timeoutMilliseconds) {
    return omtr_receiver_poll_mode(receiver, out, timeoutMilliseconds, 0);
}
int omtr_receiver_poll_mode(void *receiver, OMTRFrame *out, int timeoutMilliseconds, int preview) {
    if (!pollReceiver || !receiver || !out) return 0;
    OMTFrameType types = preview ? OMTFrameType_Video : (OMTFrameType_Video | OMTFrameType_Audio);
    OMTMediaFrame *f = pollReceiver((omt_receive_t *)receiver, types, timeoutMilliseconds);
    if (!f) return 0;
    memset(out, 0, sizeof(*out));
    out->type = f->Type; out->timestamp = f->Timestamp; out->codec = f->Codec;
    out->width = f->Width; out->height = f->Height; out->stride = f->Stride;
    out->flags = f->Flags; out->frameRateN = f->FrameRateN; out->frameRateD = f->FrameRateD;
    out->colorSpace = f->ColorSpace; out->aspectRatio = f->AspectRatio;
    out->sampleRate = f->SampleRate; out->channels = f->Channels;
    out->samplesPerChannel = f->SamplesPerChannel;
    out->data = f->Data; out->dataLength = f->DataLength;
    return 1;
}
void omtr_receiver_destroy(void *receiver) { if (receiver && destroyReceiver) destroyReceiver((omt_receive_t *)receiver); }
void omtr_shutdown(void) { if (shutdownRuntime && loaded) shutdownRuntime(); }
