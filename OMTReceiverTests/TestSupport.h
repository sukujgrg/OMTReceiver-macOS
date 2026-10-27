#ifndef OMTReceiver_TestSupport_h
#define OMTReceiver_TestSupport_h
#include "OMTReceiver-Bridging-Header.h"
void *test_sender_create(const char *libraryPath, int port);
void test_sender_destroy(void *sender);
int test_sender_connections(void *sender);
int test_sender_video(void *sender, int width, int height, int interlaced, int alpha, int highDepth, long long timestamp);
int test_sender_audio(void *sender, int sampleRate, long long timestamp);

// Loopback-only network fault fixture. Returning online affects future TCP
// connections; pipes frozen by an outage remain open and discard media.
int test_available_loopback_port(void);
void *test_proxy_create(int upstreamPort);
int test_proxy_port(void *proxy);
int test_proxy_connections(void *proxy);
void test_proxy_set_offline(void *proxy, int offline);
void test_proxy_destroy(void *proxy);

#endif
