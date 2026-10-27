#include "TestSupport.h"
#include "libomt.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>
static omt_send_t *(*create_sender)(const char *, OMTQuality);
static void (*destroy_sender)(omt_send_t *);
static int (*send_frame)(omt_send_t *, OMTMediaFrame *);
static int (*sender_connections)(omt_send_t *);
static int (*sender_address)(omt_send_t *, char *, int);
void *test_sender_create(const char *libraryPath, int port) {
    void *library = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL);
    if (!library) return NULL;
    create_sender = dlsym(library, "omt_send_create");
    destroy_sender = dlsym(library, "omt_send_destroy");
    send_frame = dlsym(library, "omt_send");
    sender_connections = dlsym(library, "omt_send_connections");
    sender_address = dlsym(library, "omt_send_getaddress");
    void (*setting)(const char *, int) = dlsym(library, "omt_settings_set_integer");
    if (!create_sender || !destroy_sender || !send_frame || !sender_connections || !setting) return NULL;
    setting("NetworkPortStart", port); setting("NetworkPortEnd", port);
    return create_sender("OMTReceiver Isolated Loopback", OMTQuality_High);
}
void test_sender_destroy(void *sender) { if (sender) destroy_sender(sender); }
int test_sender_connections(void *sender) { return sender && sender_connections ? sender_connections(sender) : 0; }
int test_sender_address(void *sender, char *address, int capacity) {
    return sender && sender_address ? sender_address(sender, address, capacity) : 0;
}
int test_sender_video(void *sender, int width, int height, int interlaced, int alpha, int highDepth, long long timestamp) {
    size_t pixels = (size_t)width * height;
    size_t count = pixels * (highDepth ? (alpha ? 6 : 4) : 4);
    unsigned char *data = calloc(1, count);
    if (!data) return 0;
    if (highDepth) {
        unsigned short *p = (unsigned short *)data;
        for (size_t i=0;i<pixels;i++) { p[i]=32768; p[pixels+i]=32768; if(alpha) p[pixels*2+i]=32768; }
    } else {
        for (size_t i=0;i<pixels;i++) { data[i*4]=32; data[i*4+1]=160; data[i*4+2]=240; data[i*4+3]=alpha ? 128 : 255; }
    }
    OMTMediaFrame frame = {0}; frame.Type = OMTFrameType_Video;
    frame.Timestamp=timestamp; frame.Codec=highDepth ? (alpha ? OMTCodec_PA16 : OMTCodec_P216) : OMTCodec_BGRA;
    frame.Width=width; frame.Height=height; frame.Stride=width*(highDepth?2:4);
    frame.Flags=(interlaced?OMTVideoFlags_Interlaced:0) | (alpha?OMTVideoFlags_Alpha:0) | (highDepth?OMTVideoFlags_HighBitDepth:0);
    frame.FrameRateN=interlaced?30000:60000; frame.FrameRateD=1001;
    frame.AspectRatio=(float)width/height; frame.ColorSpace=height<720 ? OMTColorSpace_BT601 : OMTColorSpace_BT709;
    frame.Data=data; frame.DataLength=(int)count;
    int result=send_frame(sender,&frame); free(data); return result;
}
int test_sender_audio(void *sender, int sampleRate, long long timestamp) {
    int samples=sampleRate/50;
    float *data=calloc((size_t)samples*2,sizeof(float)); if(!data) return 0;
    for(int i=0;i<samples;i++) { float sample=0.05f*sinf((float)i*440*6.28318530718f/sampleRate); data[i]=sample; data[samples+i]=-sample; }
    OMTMediaFrame frame={0}; frame.Type=OMTFrameType_Audio; frame.Codec=OMTCodec_FPA1;
    frame.Timestamp=timestamp; frame.SampleRate=sampleRate; frame.Channels=2; frame.SamplesPerChannel=samples;
    frame.Data=data; frame.DataLength=samples*2*4;
    int result=send_frame(sender,&frame); free(data); return result;
}

// A lost network path can leave an established SDK socket connected but unable
// to receive any more media. Keep that exact condition: drain/discard upstream
// bytes rather than closing the socket or letting TCP backpressure disconnect
// it. Only a new connection after the outage can carry a healthy picture.
enum { TestProxyConnectionLimit = 32 };
typedef struct {
    int client;
    int upstream;
    atomic_bool frozen;
} TestProxyConnection;

typedef struct {
    int listener;
    int port;
    int upstreamPort;
    pthread_t worker;
    pthread_mutex_t lock;
    bool offline;
    atomic_bool stopping;
    atomic_int accepted;
    TestProxyConnection connections[TestProxyConnectionLimit];
} TestProxy;

static int loopback_listener(int *port) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) return -1;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    socklen_t size = sizeof(address);
    if (bind(listener, (struct sockaddr *)&address, size) != 0 ||
        getsockname(listener, (struct sockaddr *)&address, &size) != 0 ||
        listen(listener, TestProxyConnectionLimit) != 0) {
        close(listener);
        return -1;
    }
    *port = ntohs(address.sin_port);
    return listener;
}

int test_available_loopback_port(void) {
    int port = 0;
    int listener = loopback_listener(&port);
    if (listener >= 0) close(listener);
    return port;
}

static void proxy_configure_socket(int descriptor) {
    int enabled = 1;
    setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled));
    // No worker operation may block teardown indefinitely.
    struct timeval timeout = { .tv_sec = 0, .tv_usec = 100000 };
    setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

static void proxy_close_connection(TestProxyConnection *connection) {
    if (connection->client >= 0) close(connection->client);
    if (connection->upstream >= 0) close(connection->upstream);
    connection->client = -1;
    connection->upstream = -1;
}

static bool proxy_send(TestProxy *proxy, int destination, const unsigned char *data, size_t length) {
    while (length && !atomic_load(&proxy->stopping)) {
        ssize_t sent = send(destination, data, length, 0);
        if (sent < 0 && errno == EINTR) continue;
        if (sent <= 0) return false;
        data += sent;
        length -= (size_t)sent;
    }
    return length == 0;
}

static bool proxy_connect(int upstream, const struct sockaddr_in *address) {
    if (fcntl(upstream, F_SETFL, O_NONBLOCK) != 0) return false;
    int result = connect(upstream, (const struct sockaddr *)address, sizeof(*address));
    if (result != 0) {
        if (errno != EINPROGRESS) return false;
        struct pollfd descriptor = { .fd = upstream, .events = POLLOUT };
        if (poll(&descriptor, 1, 100) <= 0) return false;
        int error = 0;
        socklen_t size = sizeof(error);
        if (getsockopt(upstream, SOL_SOCKET, SO_ERROR, &error, &size) != 0 || error) return false;
    }
    return fcntl(upstream, F_SETFL, 0) == 0;
}

static void proxy_accept(TestProxy *proxy) {
    int client;
    while ((client = accept(proxy->listener, NULL, NULL)) >= 0) {
        int slot = -1;
        for (int i = 0; i < TestProxyConnectionLimit; ++i) {
            if (proxy->connections[i].client < 0) { slot = i; break; }
        }
        if (slot < 0) { close(client); continue; }
        int upstream = socket(AF_INET, SOCK_STREAM, 0);
        struct sockaddr_in address = {0};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        address.sin_port = htons(proxy->upstreamPort);
        if (upstream < 0 || !proxy_connect(upstream, &address)) {
            close(client);
            if (upstream >= 0) close(upstream);
            continue;
        }
        proxy_configure_socket(client);
        proxy_configure_socket(upstream);
        TestProxyConnection *connection = &proxy->connections[slot];
        pthread_mutex_lock(&proxy->lock);
        connection->client = client;
        connection->upstream = upstream;
        atomic_store(&connection->frozen, proxy->offline);
        pthread_mutex_unlock(&proxy->lock);
        atomic_fetch_add(&proxy->accepted, 1);
    }
}

static void *proxy_run(void *context) {
    TestProxy *proxy = context;
    unsigned char bytes[65536];
    while (!atomic_load(&proxy->stopping)) {
        struct pollfd descriptors[1 + TestProxyConnectionLimit * 2];
        descriptors[0] = (struct pollfd){ .fd = proxy->listener, .events = POLLIN };
        for (int i = 0; i < TestProxyConnectionLimit; ++i) {
            descriptors[1 + i * 2] = (struct pollfd){ .fd = proxy->connections[i].client, .events = POLLIN };
            descriptors[2 + i * 2] = (struct pollfd){ .fd = proxy->connections[i].upstream, .events = POLLIN };
        }
        int ready = poll(descriptors, 1 + TestProxyConnectionLimit * 2, 50);
        if (ready < 0 && errno == EINTR) continue;
        if (ready < 0) break;
        if (descriptors[0].revents & POLLIN) proxy_accept(proxy);
        for (int i = 0; i < TestProxyConnectionLimit; ++i) {
            TestProxyConnection *connection = &proxy->connections[i];
            for (int direction = 0; direction < 2; ++direction) {
                struct pollfd descriptor = descriptors[1 + i * 2 + direction];
                int source = direction ? connection->upstream : connection->client;
                int destination = direction ? connection->client : connection->upstream;
                if (source < 0 || source != descriptor.fd || !descriptor.revents) continue;
                if (descriptor.revents & (POLLERR | POLLNVAL)) { proxy_close_connection(connection); break; }
                if (!(descriptor.revents & (POLLIN | POLLHUP))) continue;
                ssize_t received = recv(source, bytes, sizeof(bytes), 0);
                if (received < 0 && errno == EINTR) continue;
                if (received <= 0) { proxy_close_connection(connection); break; }
                if (direction && atomic_load(&connection->frozen)) continue;
                if (!proxy_send(proxy, destination, bytes, (size_t)received)) {
                    proxy_close_connection(connection);
                    break;
                }
            }
        }
    }
    for (int i = 0; i < TestProxyConnectionLimit; ++i) proxy_close_connection(&proxy->connections[i]);
    close(proxy->listener);
    return NULL;
}

void *test_proxy_create(int upstreamPort) {
    if (upstreamPort < 1 || upstreamPort > 65535) return NULL;
    TestProxy *proxy = calloc(1, sizeof(*proxy));
    if (!proxy) return NULL;
    for (int i = 0; i < TestProxyConnectionLimit; ++i) {
        proxy->connections[i].client = -1;
        proxy->connections[i].upstream = -1;
        atomic_init(&proxy->connections[i].frozen, false);
    }
    atomic_init(&proxy->stopping, false);
    atomic_init(&proxy->accepted, 0);
    if (pthread_mutex_init(&proxy->lock, NULL) != 0) { free(proxy); return NULL; }
    proxy->upstreamPort = upstreamPort;
    proxy->listener = loopback_listener(&proxy->port);
    if (proxy->listener < 0) { pthread_mutex_destroy(&proxy->lock); free(proxy); return NULL; }
    if (fcntl(proxy->listener, F_SETFL, O_NONBLOCK) != 0 ||
        pthread_create(&proxy->worker, NULL, proxy_run, proxy) != 0) {
        close(proxy->listener);
        pthread_mutex_destroy(&proxy->lock);
        free(proxy);
        return NULL;
    }
    return proxy;
}

int test_proxy_port(void *context) { return context ? ((TestProxy *)context)->port : 0; }
int test_proxy_connections(void *context) { return context ? atomic_load(&((TestProxy *)context)->accepted) : 0; }

void test_proxy_set_offline(void *context, int offline) {
    if (!context) return;
    TestProxy *proxy = context;
    pthread_mutex_lock(&proxy->lock);
    proxy->offline = offline != 0;
    if (offline) {
        for (int i = 0; i < TestProxyConnectionLimit; ++i) atomic_store(&proxy->connections[i].frozen, true);
    }
    pthread_mutex_unlock(&proxy->lock);
}

void test_proxy_destroy(void *context) {
    if (!context) return;
    TestProxy *proxy = context;
    atomic_store(&proxy->stopping, true);
    pthread_join(proxy->worker, NULL);
    pthread_mutex_destroy(&proxy->lock);
    free(proxy);
}
