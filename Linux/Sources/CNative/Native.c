#define GST_USE_UNSTABLE_API
#include "Native.h"
#include <gtk/gtk.h>
#include <libsoup/soup.h>
#include <gst/webrtc/webrtc.h>
#include <gst/sdp/sdp.h>
#include <gst/app/gstappsink.h>
#include <gst/video/video.h>

struct OLNative {
    gint refs, active, frame_pending;
    OLNativeEvent callback;
    void *context;
    GtkWidget *picture;
    GstElement *pipeline, *rtc, *sender, *sender_rtc;
    SoupSession *http;
    SoupWebsocketConnection *socket;
    GCancellable *cancel;
    guint bus, sender_bus;
    gboolean got_frame;
};
static OLNative *retain(OLNative *n) { g_atomic_int_inc(&n->refs); return n; }
static gboolean free_native(gpointer data) {
    OLNative *n=data;
    g_clear_object(&n->picture);
    gst_clear_object(&n->rtc); gst_clear_object(&n->pipeline);
    gst_clear_object(&n->sender_rtc); gst_clear_object(&n->sender);
    g_clear_object(&n->socket); g_clear_object(&n->http); g_clear_object(&n->cancel);
    g_free(n); return G_SOURCE_REMOVE;
}
static void release(gpointer data) {
    OLNative *n=data;
    if (g_atomic_int_dec_and_test(&n->refs)) g_idle_add(free_native, n);
}
typedef struct { OLNative *n; char *event, *text; int number; } Event;
static gboolean deliver(gpointer data) {
    Event *e=data;
    if (g_atomic_int_get(&e->n->active)) e->n->callback(e->event,e->text,e->number,e->n->context);
    release(e->n); g_free(e->event); g_free(e->text); g_free(e);
    return G_SOURCE_REMOVE;
}
static void emit(OLNative *n, const char *event, const char *text, int number) {
    Event *e=g_new0(Event,1); e->n=retain(n); e->event=g_strdup(event);
    e->text=g_strdup(text ? text : ""); e->number=number; g_idle_add(deliver,e);
}
static gboolean bus_message(GstBus *bus, GstMessage *message, gpointer data) {
    OLNative *n=data;
    if (GST_MESSAGE_TYPE(message)==GST_MESSAGE_ERROR) {
        GError *error=NULL; gchar *debug=NULL;
        gst_message_parse_error(message,&error,&debug);
        emit(n,"error",error->message,0); g_clear_error(&error); g_free(debug);
    }
    return G_SOURCE_CONTINUE;
}
typedef struct { OLNative *n; GBytes *bytes; int width,height,stride; } Frame;
static gboolean display_frame(gpointer data) {
    Frame *f=data; OLNative *n=f->n;
    if (g_atomic_int_get(&n->active)) {
        GdkTexture *texture=gdk_memory_texture_new(f->width,f->height,GDK_MEMORY_R8G8B8A8,f->bytes,f->stride);
        gtk_picture_set_paintable(GTK_PICTURE(n->picture),GDK_PAINTABLE(texture));
        g_object_unref(texture);
        if (!n->got_frame) { n->got_frame=TRUE; emit(n,"frame","Native WebRTC video connected",0); }
    }
    g_atomic_int_set(&n->frame_pending,0);
    g_bytes_unref(f->bytes); release(n); g_free(f); return G_SOURCE_REMOVE;
}
static GstFlowReturn sample_ready(GstAppSink *sink, gpointer data) {
    OLNative *n=data; GstSample *sample=gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_EOS;
    // Bound UI work to one frame. Never queue video indefinitely behind GTK.
    if (g_atomic_int_get(&n->active) && g_atomic_int_compare_and_exchange(&n->frame_pending,0,1)) {
        GstVideoInfo info; GstVideoFrame frame;
        if (gst_video_info_from_caps(&info,gst_sample_get_caps(sample)) &&
            gst_video_frame_map(&frame,&info,gst_sample_get_buffer(sample),GST_MAP_READ)) {
            Frame *f=g_new0(Frame,1); f->n=retain(n);
            f->width=GST_VIDEO_INFO_WIDTH(&info); f->height=GST_VIDEO_INFO_HEIGHT(&info); f->stride=f->width*4;
            guint8 *pixels=g_malloc((gsize)f->stride*f->height);
            for (int y=0;y<f->height;y++) memcpy(pixels+y*f->stride,
                (guint8 *)GST_VIDEO_FRAME_PLANE_DATA(&frame,0)+y*GST_VIDEO_FRAME_PLANE_STRIDE(&frame,0),f->stride);
            f->bytes=g_bytes_new_take(pixels,(gsize)f->stride*f->height);
            gst_video_frame_unmap(&frame); g_idle_add(display_frame,f);
        } else g_atomic_int_set(&n->frame_pending,0);
    }
    gst_sample_unref(sample); return GST_FLOW_OK;
}
static void decoded_pad(GstElement *decode, GstPad *pad, gpointer data) {
    OLNative *n=data;
    GstCaps *caps=gst_pad_get_current_caps(pad);
    if (!caps) return;
    gboolean video=g_str_has_prefix(gst_structure_get_name(gst_caps_get_structure(caps,0)),"video/x-raw");
    gst_caps_unref(caps);
    if (!video || !g_atomic_int_get(&n->active)) return;
    GError *error=NULL;
    GstElement *output=gst_parse_bin_from_description("videoconvert ! video/x-raw,format=RGBA ! appsink name=frames sync=false max-buffers=1 drop=true emit-signals=true",TRUE,&error);
    if (!output) { emit(n,"error",error->message,0); g_clear_error(&error); return; }
    GstElement *sink=gst_bin_get_by_name(GST_BIN(output),"frames");
    g_signal_connect(sink,"new-sample",G_CALLBACK(sample_ready),n); gst_object_unref(sink);
    gst_bin_add(GST_BIN(n->pipeline),output);
    GstPad *target=gst_element_get_static_pad(output,"sink");
    if (gst_pad_link(pad,target)!=GST_PAD_LINK_OK) emit(n,"error","Cannot link decoded video to GTK output",0);
    gst_object_unref(target); gst_element_sync_state_with_parent(output);
}
static void incoming_pad(GstElement *rtc, GstPad *pad, gpointer data) {
    OLNative *n=data;
    if (GST_PAD_DIRECTION(pad)!=GST_PAD_SRC || !g_atomic_int_get(&n->active)) return;
    GstElement *decode=gst_element_factory_make("decodebin",NULL);
    if (!decode) { emit(n,"error","Missing GStreamer decodebin",0); return; }
    g_signal_connect(decode,"pad-added",G_CALLBACK(decoded_pad),n);
    gst_bin_add(GST_BIN(n->pipeline),decode);
    GstPad *target=gst_element_get_static_pad(decode,"sink");
    if (gst_pad_link(pad,target)!=GST_PAD_LINK_OK) emit(n,"error","Cannot link incoming RTP decoder",0);
    gst_object_unref(target); gst_element_sync_state_with_parent(decode);
}
static void local_ice(GstElement *rtc, guint line, gchar *candidate, gpointer data) {
    OLNative *n=data;
    if (n->sender_rtc) g_signal_emit_by_name(n->sender_rtc,"add-ice-candidate",line,candidate);
    else emit(n,"ice",candidate,line);
}
static void ice_state(GObject *rtc, GParamSpec *pspec, gpointer data) {
    GstWebRTCICEConnectionState state; g_object_get(rtc,"ice-connection-state",&state,NULL);
    if (state==GST_WEBRTC_ICE_CONNECTION_STATE_FAILED) emit(data,"error","ICE failed. Check network routing/firewall; TURN is not configured in this preview.",0);
}
static gboolean promise_ok(GstPromise *p, OLNative *n) {
    if (gst_promise_wait(p)!=GST_PROMISE_RESULT_REPLIED) return FALSE;
    const GstStructure *reply=gst_promise_get_reply(p);
    GError *error=NULL;
    if (reply && gst_structure_get(reply,"error",G_TYPE_ERROR,&error,NULL)) {
        emit(n,"error",error->message,0); g_error_free(error); return FALSE;
    }
    return g_atomic_int_get(&n->active);
}
typedef struct { OLNative *n; GstWebRTCSessionDescription *answer; } LocalAnswer;
static void free_local_answer(gpointer data) {
    LocalAnswer *local=data;
    gst_webrtc_session_description_free(local->answer); release(local->n); g_free(local);
}
static void local_set(GstPromise *promise, gpointer data) {
    LocalAnswer *local=data; OLNative *n=local->n;
    if (promise_ok(promise,n)) {
        if (n->sender_rtc) g_signal_emit_by_name(n->sender_rtc,"set-remote-description",local->answer,NULL);
        else {
            gchar *sdp=gst_sdp_message_as_text(local->answer->sdp);
            emit(n,"answer",sdp,0); g_free(sdp);
        }
    }
    gst_promise_unref(promise);
}
static void answer_created(GstPromise *promise, gpointer data) {
    OLNative *n=data;
    if (promise_ok(promise,n)) {
        GstWebRTCSessionDescription *answer=NULL;
        const GstStructure *reply=gst_promise_get_reply(promise);
        if (reply) gst_structure_get(reply,"answer",GST_TYPE_WEBRTC_SESSION_DESCRIPTION,&answer,NULL);
        if (answer) {
            LocalAnswer *local=g_new0(LocalAnswer,1); local->n=retain(n); local->answer=answer;
            GstPromise *next=gst_promise_new_with_change_func(local_set,local,free_local_answer);
            g_signal_emit_by_name(n->rtc,"set-local-description",answer,next);
        } else emit(n,"error","GStreamer did not generate an SDP answer",0);
    }
    gst_promise_unref(promise);
}
static void remote_set(GstPromise *promise, gpointer data) {
    OLNative *n=data;
    if (promise_ok(promise,n)) {
        GstPromise *next=gst_promise_new_with_change_func(answer_created,retain(n),release);
        g_signal_emit_by_name(n->rtc,"create-answer",NULL,next);
    }
    gst_promise_unref(promise);
}
OLNative *ol_native_new(OLNativeEvent callback, void *context) {
    gst_init(NULL,NULL);
    OLNative *n=g_new0(OLNative,1); n->refs=1; n->active=1; n->callback=callback; n->context=context;
    n->picture=gtk_picture_new(); g_object_ref_sink(n->picture);
    gtk_picture_set_can_shrink(GTK_PICTURE(n->picture),TRUE);
    gtk_picture_set_content_fit(GTK_PICTURE(n->picture),GTK_CONTENT_FIT_CONTAIN);
    n->http=soup_session_new(); g_object_set(n->http,"timeout",15,NULL);
    SoupCookieJar *jar=soup_cookie_jar_new(); soup_session_add_feature(n->http,SOUP_SESSION_FEATURE(jar)); g_object_unref(jar);
    n->cancel=g_cancellable_new();
    n->pipeline=gst_pipeline_new(NULL); n->rtc=gst_element_factory_make("webrtcbin",NULL);
    if (!n->rtc) { emit(n,"error","Install GStreamer webrtcbin and libnice plugins",0); return n; }
    gst_bin_add(GST_BIN(n->pipeline),n->rtc); gst_object_ref(n->rtc);
    g_object_set(n->rtc,"bundle-policy",GST_WEBRTC_BUNDLE_POLICY_MAX_BUNDLE,"latency",0,NULL);
    g_signal_connect(n->rtc,"pad-added",G_CALLBACK(incoming_pad),n);
    g_signal_connect(n->rtc,"on-ice-candidate",G_CALLBACK(local_ice),n);
    g_signal_connect(n->rtc,"notify::ice-connection-state",G_CALLBACK(ice_state),n);
    GstBus *bus=gst_element_get_bus(n->pipeline); n->bus=gst_bus_add_watch(bus,bus_message,n); gst_object_unref(bus);
    if (gst_element_set_state(n->pipeline,GST_STATE_PLAYING)==GST_STATE_CHANGE_FAILURE) emit(n,"error","Cannot start native WebRTC pipeline. Check GStreamer plugins.",0);
    return n;
}
void *ol_native_picture(OLNative *n) { return n->picture; }
void ol_native_offer(OLNative *n, const char *text) {
    if (!n->rtc || !g_atomic_int_get(&n->active)) return;
    GstSDPMessage *sdp=NULL; gst_sdp_message_new(&sdp);
    if (gst_sdp_message_parse_buffer((const guint8 *)text,strlen(text),sdp)!=GST_SDP_OK) {
        gst_sdp_message_free(sdp); emit(n,"error","Invalid remote SDP",0); return;
    }
    GstWebRTCSessionDescription *offer=gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_OFFER,sdp);
    GstPromise *promise=gst_promise_new_with_change_func(remote_set,retain(n),release);
    g_signal_emit_by_name(n->rtc,"set-remote-description",offer,promise);
    gst_webrtc_session_description_free(offer);
}
void ol_native_ice(OLNative *n, unsigned int line, const char *candidate) {
    if (n->rtc) g_signal_emit_by_name(n->rtc,"add-ice-candidate",line,candidate);
}
// libsoup runs on the GTK loop, supports Linux WebSockets and a per-session cookie jar.
typedef struct { OLNative *n; SoupMessage *message; } Request;
static void http_done(GObject *source, GAsyncResult *result, gpointer data) {
    Request *r=data; GError *error=NULL;
    GBytes *bytes=soup_session_send_and_read_finish(SOUP_SESSION(source),result,&error);
    if (error) { emit(r->n,"error",error->message,0); g_clear_error(&error); }
    else {
        gsize size=0; const char *raw=g_bytes_get_data(bytes,&size); gchar *body=g_strndup(raw,size);
        emit(r->n,"http",body,soup_message_get_status(r->message)); g_free(body); g_bytes_unref(bytes);
    }
    g_object_unref(r->message); release(r->n); g_free(r);
}
void ol_native_http(OLNative *n, const char *method, const char *url, const char *body) {
    SoupMessage *message=soup_message_new(method,url);
    if (!message) { emit(n,"error","Invalid API URL",0); return; }
    // Never follow a redirect with a credential-bearing form body.
    soup_message_set_flags(message,SOUP_MESSAGE_NO_REDIRECT);
    GBytes *bytes=g_bytes_new(body,strlen(body));
    soup_message_set_request_body_from_bytes(message,"application/x-www-form-urlencoded",bytes); g_bytes_unref(bytes);
    Request *r=g_new0(Request,1); r->n=retain(n); r->message=message;
    soup_session_send_and_read_async(n->http,message,G_PRIORITY_DEFAULT,n->cancel,http_done,r);
}
void ol_native_cookie(OLNative *n, const char *url, const char *token) {
    GUri *uri=g_uri_parse(url,G_URI_FLAGS_NONE,NULL); if (!uri) return;
    SoupCookie *cookie=soup_cookie_new("auth_token",token,g_uri_get_host(uri),"/",-1);
    soup_cookie_set_secure(cookie,g_strcmp0(g_uri_get_scheme(uri),"https")==0);
    SoupCookieJar *jar=SOUP_COOKIE_JAR(soup_session_get_feature(n->http,SOUP_TYPE_COOKIE_JAR));
    soup_cookie_jar_add_cookie(jar,cookie); g_uri_unref(uri);
}
static void socket_message(SoupWebsocketConnection *socket, gint type, GBytes *bytes, gpointer data) {
    if (type!=SOUP_WEBSOCKET_DATA_TEXT) return;
    gsize size; const char *raw=g_bytes_get_data(bytes,&size); char *text=g_strndup(raw,size);
    emit(data,"ws",text,0); g_free(text);
}
static void socket_closed(SoupWebsocketConnection *socket, gpointer data) { emit(data,"error","Janus signaling connection closed",0); }
static void socket_error(SoupWebsocketConnection *socket, GError *error, gpointer data) { emit(data,"error",error->message,0); }
static void socket_ready(GObject *source, GAsyncResult *result, gpointer data) {
    OLNative *n=data; GError *error=NULL;
    SoupWebsocketConnection *socket=soup_session_websocket_connect_finish(SOUP_SESSION(source),result,&error);
    if (error) { emit(n,"error",error->message,0); g_clear_error(&error); }
    else if (!g_atomic_int_get(&n->active)) { soup_websocket_connection_close(socket,1000,NULL); g_object_unref(socket); }
    else {
        n->socket=socket;
        g_signal_connect(socket,"message",G_CALLBACK(socket_message),n);
        g_signal_connect(socket,"closed",G_CALLBACK(socket_closed),n);
        g_signal_connect(socket,"error",G_CALLBACK(socket_error),n);
        emit(n,"open","",0);
    }
    release(n);
}
void ol_native_socket(OLNative *n, const char *url, const char *origin) {
    SoupMessage *message=soup_message_new("GET",url);
    if (!message) { emit(n,"error","Invalid Janus URL",0); return; }
    char *protocols[]={"janus-protocol",NULL};
    soup_session_websocket_connect_async(n->http,message,origin,protocols,G_PRIORITY_DEFAULT,n->cancel,socket_ready,retain(n));
    g_object_unref(message);
}
void ol_native_send(OLNative *n, const char *json) {
    if (n->socket && soup_websocket_connection_get_state(n->socket)==SOUP_WEBSOCKET_STATE_OPEN) soup_websocket_connection_send_text(n->socket,json);
    else emit(n,"error","Janus socket is not connected",0);
}
void ol_native_close(OLNative *n) {
    if (!g_atomic_int_compare_and_exchange(&n->active,1,0)) return;
    g_cancellable_cancel(n->cancel);
    if (n->socket) { g_signal_handlers_disconnect_by_data(n->socket,n); soup_websocket_connection_close(n->socket,1000,NULL); }
    soup_session_abort(n->http);
    if (n->bus) g_source_remove(n->bus);
    if (n->sender_bus) g_source_remove(n->sender_bus);
    if (n->pipeline) gst_element_set_state(n->pipeline,GST_STATE_NULL);
    if (n->sender) gst_element_set_state(n->sender,GST_STATE_NULL);
    release(n);
}
// Test-only local sender: the receiver still traverses ICE/DTLS/SRTP, depayload,
// decodebin, appsink and a GTK texture. It is not a direct test-pattern preview.
static void sender_ice(GstElement *rtc, guint line, gchar *candidate, gpointer data) { ol_native_ice(data,line,candidate); }
static void test_offer_created(GstPromise *promise, gpointer data) {
    OLNative *n=data;
    if (promise_ok(promise,n)) {
        GstWebRTCSessionDescription *offer=NULL;
        gst_structure_get(gst_promise_get_reply(promise),"offer",GST_TYPE_WEBRTC_SESSION_DESCRIPTION,&offer,NULL);
        if (offer) {
            g_signal_emit_by_name(n->sender_rtc,"set-local-description",offer,NULL);
            char *sdp=gst_sdp_message_as_text(offer->sdp); ol_native_offer(n,sdp);
            g_free(sdp); gst_webrtc_session_description_free(offer);
        }
    }
    gst_promise_unref(promise);
}
static void test_negotiate(GstElement *rtc, gpointer data) {
    OLNative *n=data;
    GstPromise *p=gst_promise_new_with_change_func(test_offer_created,retain(n),release);
    g_signal_emit_by_name(rtc,"create-offer",NULL,p);
}
void ol_native_test(OLNative *n, int h264) {
    GError *error=NULL;
    const char *vp8="videotestsrc is-live=true ! video/x-raw,width=320,height=240,framerate=15/1 ! videoconvert ! vp8enc deadline=1 ! rtpvp8pay ! application/x-rtp,media=video,encoding-name=VP8,payload=96 ! webrtcbin name=sender bundle-policy=max-bundle";
    const char *avc="videotestsrc is-live=true ! video/x-raw,width=320,height=240,framerate=15/1 ! videoconvert ! openh264enc ! h264parse ! rtph264pay config-interval=-1 ! application/x-rtp,media=video,encoding-name=H264,payload=96 ! webrtcbin name=sender bundle-policy=max-bundle";
    n->sender=gst_parse_launch(h264 ? avc : vp8,&error);
    if (error) { emit(n,"error",error->message,0); g_clear_error(&error); return; }
    n->sender_rtc=gst_bin_get_by_name(GST_BIN(n->sender),"sender");
    g_signal_connect(n->sender_rtc,"on-negotiation-needed",G_CALLBACK(test_negotiate),n);
    g_signal_connect(n->sender_rtc,"on-ice-candidate",G_CALLBACK(sender_ice),n);
    GstBus *bus=gst_element_get_bus(n->sender); n->sender_bus=gst_bus_add_watch(bus,bus_message,n); gst_object_unref(bus);
    gst_element_set_state(n->sender,GST_STATE_PLAYING);
}
