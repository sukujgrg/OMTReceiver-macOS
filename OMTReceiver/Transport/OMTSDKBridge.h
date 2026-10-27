#ifndef OMTSDKBridge_h
#define OMTSDKBridge_h
#include <stdint.h>
#include <stddef.h>

typedef struct OMTRFrame {
    int type;
    int64_t timestamp;
    uint32_t codec;
    int width, height, stride, flags, frameRateN, frameRateD, colorSpace;
    float aspectRatio;
    int sampleRate, channels, samplesPerChannel;
    const void *data;
    int dataLength;
} OMTRFrame;

int omtr_load(const char *runtimePath, const char *codecPath, const char *storagePath,
              const char *server, char *error, size_t errorCapacity);
char **omtr_discover(int *count);
void *omtr_receiver_create(const char *address);
// Preview receivers subscribe only to reduced-resolution video, never audio.
void *omtr_receiver_create_mode(const char *address, int preview);
int omtr_receiver_poll(void *receiver, OMTRFrame *frame, int timeoutMilliseconds);
int omtr_receiver_poll_mode(void *receiver, OMTRFrame *frame, int timeoutMilliseconds, int preview);
void omtr_receiver_destroy(void *receiver);
void omtr_shutdown(void);
#endif
