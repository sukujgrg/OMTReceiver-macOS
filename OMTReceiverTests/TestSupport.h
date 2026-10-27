#ifndef OMTReceiver_TestSupport_h
#define OMTReceiver_TestSupport_h
#include "OMTReceiver-Bridging-Header.h"
void *test_sender_create(const char *libraryPath, int port);
void test_sender_destroy(void *sender);
int test_sender_connections(void *sender);
int test_sender_video(void *sender, int width, int height, int interlaced, int alpha, int highDepth, long long timestamp);
int test_sender_audio(void *sender, int sampleRate, long long timestamp);

#endif
