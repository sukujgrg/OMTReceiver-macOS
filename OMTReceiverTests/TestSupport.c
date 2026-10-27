#include "TestSupport.h"
#include "libomt.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <math.h>
#include <string.h>
static omt_send_t *(*create_sender)(const char *, OMTQuality);
static void (*destroy_sender)(omt_send_t *);
static int (*send_frame)(omt_send_t *, OMTMediaFrame *);
static int (*sender_connections)(omt_send_t *);
void *test_sender_create(const char *libraryPath, int port) {
    void *library = dlopen(libraryPath, RTLD_NOW | RTLD_LOCAL);
    if (!library) return NULL;
    create_sender = dlsym(library, "omt_send_create");
    destroy_sender = dlsym(library, "omt_send_destroy");
    send_frame = dlsym(library, "omt_send");
    sender_connections = dlsym(library, "omt_send_connections");
    void (*setting)(const char *, int) = dlsym(library, "omt_settings_set_integer");
    if (!create_sender || !destroy_sender || !send_frame || !sender_connections || !setting) return NULL;
    setting("NetworkPortStart", port); setting("NetworkPortEnd", port);
    return create_sender("OMTReceiver Isolated Loopback", OMTQuality_High);
}
void test_sender_destroy(void *sender) { if (sender) destroy_sender(sender); }
int test_sender_connections(void *sender) { return sender && sender_connections ? sender_connections(sender) : 0; }
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
