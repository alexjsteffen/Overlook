#define GST_USE_UNSTABLE_API
#include "Native.h"
#include <gtk/gtk.h>
#include <libsoup/soup.h>
#include <gst/webrtc/webrtc.h>
#include <gst/sdp/sdp.h>
#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <gst/video/video.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/wait.h>
#include <math.h>

typedef struct OLRecorder OLRecorder;

struct OLNative {
    gint refs, active, frame_pending;
    OLNativeEvent callback;
    void *context;
    GtkWidget *picture;
    GstElement *pipeline, *rtc, *sender, *sender_rtc;
    SoupSession *http;
    SoupWebsocketConnection *socket, *hid;
    GCancellable *cancel;
    guint bus, sender_bus;
    gboolean got_frame, inhibited;
    GHashTable *allowed;
    char *rejected;
    OLNativeInput input;
    void *input_context;
    GBytes *last_frame_bytes;
    int last_frame_width, last_frame_height, last_frame_stride;
    int rendered_frames_window;
    guint64 last_bytes_received;
    gint64 last_stats_us;
    OLRecorder *recorder;
};
static void recorder_push_frame(OLRecorder *rec, GBytes *bytes, int width, int height, int stride);
static void recorder_abort(OLNative *n);
static OLNative *retain(OLNative *n) { g_atomic_int_inc(&n->refs); return n; }
static gboolean free_native(gpointer data) {
    OLNative *n=data;
    recorder_abort(n);
    g_clear_pointer(&n->last_frame_bytes, g_bytes_unref);
    g_clear_object(&n->picture);
    gst_clear_object(&n->rtc); gst_clear_object(&n->pipeline);
    gst_clear_object(&n->sender_rtc); gst_clear_object(&n->sender);
    g_clear_object(&n->socket); g_clear_object(&n->hid); g_clear_object(&n->http); g_clear_object(&n->cancel);
    g_hash_table_destroy(n->allowed); g_free(n->rejected);
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
        g_clear_pointer(&n->last_frame_bytes, g_bytes_unref);
        n->last_frame_bytes=g_bytes_ref(f->bytes);
        n->last_frame_width=f->width; n->last_frame_height=f->height; n->last_frame_stride=f->stride;
        n->rendered_frames_window++;
        if (n->recorder) recorder_push_frame(n->recorder,f->bytes,f->width,f->height,f->stride);
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
    n->allowed=g_hash_table_new_full(g_str_hash,g_str_equal,g_free,g_free);
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
// Certificates the system does not trust are only accepted when their SHA-256
// fingerprint was approved for that host:port. Otherwise the request fails and
// a "certificate" event lets the UI ask the user before retrying.
static char *uri_key(GUri *uri) {
    const char *scheme=g_uri_get_scheme(uri); int port=g_uri_get_port(uri);
    if (port<=0) port=(!g_strcmp0(scheme,"https") || !g_strcmp0(scheme,"wss")) ? 443 : 80;
    char *host=g_ascii_strdown(g_uri_get_host(uri),-1);
    char *key=g_strdup_printf("%s:%d",host,port); g_free(host); return key;
}
static char *fingerprint(GTlsCertificate *certificate) {
    GByteArray *der=NULL; g_object_get(certificate,"certificate",&der,NULL);
    if (!der) return NULL;
    char *hex=g_compute_checksum_for_data(G_CHECKSUM_SHA256,der->data,der->len);
    g_byte_array_unref(der); return hex;
}
static void describe(GString *text, GTlsCertificateFlags errors) {
    const struct { GTlsCertificateFlags flag; const char *text; } names[]={
        {G_TLS_CERTIFICATE_UNKNOWN_CA,"It is not issued by a trusted certificate authority."},
        {G_TLS_CERTIFICATE_BAD_IDENTITY,"It does not match the device address."},
        {G_TLS_CERTIFICATE_NOT_ACTIVATED,"It is not valid yet."},
        {G_TLS_CERTIFICATE_EXPIRED,"It has expired."},
        {G_TLS_CERTIFICATE_REVOKED,"It has been revoked."},
        {G_TLS_CERTIFICATE_INSECURE,"It uses an insecure algorithm."},
        {G_TLS_CERTIFICATE_GENERIC_ERROR,"It could not be validated."}};
    for (gsize i=0;i<G_N_ELEMENTS(names);i++) if (errors & names[i].flag) {
        if (text->len) g_string_append_c(text,' ');
        g_string_append(text,names[i].text);
    }
}
static gboolean accept_certificate(SoupMessage *message, GTlsCertificate *certificate, GTlsCertificateFlags errors, gpointer data) {
    OLNative *n=data;
    char *key=uri_key(soup_message_get_uri(message)), *hex=fingerprint(certificate);
    gboolean ok=hex && !g_strcmp0(g_hash_table_lookup(n->allowed,key),hex);
    if (!ok && hex) {
        GString *reason=g_string_new(NULL); describe(reason,errors);
        g_free(n->rejected); n->rejected=g_strdup_printf("%s\n%s\n%s",key,hex,reason->str);
        g_string_free(reason,TRUE);
    }
    g_free(key); g_free(hex); return ok;
}
static void guard_tls(OLNative *n, SoupMessage *message) {
    g_signal_connect(message,"accept-certificate",G_CALLBACK(accept_certificate),n);
}
static void fail_request(OLNative *n, GError *error) {
    if (n->rejected) { emit(n,"certificate",n->rejected,0); g_clear_pointer(&n->rejected,g_free); }
    else emit(n,"error",error->message,0);
}
void ol_native_allow(OLNative *n, const char *key, const char *sha256) {
    g_hash_table_replace(n->allowed,g_ascii_strdown(key,-1),g_ascii_strdown(sha256,-1));
}
typedef struct { OLNative *n; SoupMessage *message; } Request;
static void http_done(GObject *source, GAsyncResult *result, gpointer data) {
    Request *r=data; GError *error=NULL;
    GBytes *bytes=soup_session_send_and_read_finish(SOUP_SESSION(source),result,&error);
    if (error) { if (!g_error_matches(error,G_IO_ERROR,G_IO_ERROR_CANCELLED)) fail_request(r->n,error); g_clear_error(&error); }
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
    guard_tls(n,message);
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
    if (error) { if (!g_error_matches(error,G_IO_ERROR,G_IO_ERROR_CANCELLED)) fail_request(n,error); g_clear_error(&error); }
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
    guard_tls(n,message);
    soup_session_websocket_connect_async(n->http,message,origin,protocols,G_PRIORITY_DEFAULT,n->cancel,socket_ready,retain(n));
    g_object_unref(message);
}
void ol_native_send(OLNative *n, const char *json) {
    if (n->socket && soup_websocket_connection_get_state(n->socket)==SOUP_WEBSOCKET_STATE_OPEN) soup_websocket_connection_send_text(n->socket,json);
    else emit(n,"error","Janus socket is not connected",0);
}
// KVMD HID transport: /api/ws carries binary keyboard/mouse frames and JSON
// state events. It shares the login cookie jar and certificate approvals.
static void hid_message(SoupWebsocketConnection *socket, gint type, GBytes *bytes, gpointer data) {
    if (type!=SOUP_WEBSOCKET_DATA_TEXT) return;
    gsize size; const char *raw=g_bytes_get_data(bytes,&size); char *text=g_strndup(raw,size);
    emit(data,"hid",text,0); g_free(text);
}
static void hid_closed(SoupWebsocketConnection *socket, gpointer data) { emit(data,"hid-closed","Keyboard and mouse connection closed",0); }
static void hid_ready(GObject *source, GAsyncResult *result, gpointer data) {
    OLNative *n=data; GError *error=NULL;
    SoupWebsocketConnection *socket=soup_session_websocket_connect_finish(SOUP_SESSION(source),result,&error);
    if (error) {
        if (!g_error_matches(error,G_IO_ERROR,G_IO_ERROR_CANCELLED)) emit(n,"hid-closed",error->message,0);
        g_clear_error(&error); g_clear_pointer(&n->rejected,g_free);
    } else if (!g_atomic_int_get(&n->active)) { soup_websocket_connection_close(socket,1000,NULL); g_object_unref(socket); }
    else {
        n->hid=socket;
        soup_websocket_connection_set_keepalive_interval(socket,0);
        g_signal_connect(socket,"message",G_CALLBACK(hid_message),n);
        g_signal_connect(socket,"closed",G_CALLBACK(hid_closed),n);
        emit(n,"hid-open","",0);
    }
    release(n);
}
void ol_native_hid_socket(OLNative *n, const char *url, const char *origin) {
    SoupMessage *message=soup_message_new("GET",url);
    if (!message) { emit(n,"hid-closed","Invalid HID URL",0); return; }
    guard_tls(n,message);
    soup_session_websocket_connect_async(n->http,message,origin,NULL,G_PRIORITY_DEFAULT,n->cancel,hid_ready,retain(n));
    g_object_unref(message);
}
static gboolean hid_open(OLNative *n) {
    return n->hid && soup_websocket_connection_get_state(n->hid)==SOUP_WEBSOCKET_STATE_OPEN;
}
void ol_native_hid_send(OLNative *n, const unsigned char *bytes, int length) {
    if (hid_open(n) && length>0) soup_websocket_connection_send_binary(n->hid,bytes,length);
}
void ol_native_hid_text(OLNative *n, const char *text) { if (hid_open(n)) soup_websocket_connection_send_text(n->hid,text); }
int ol_native_hid_ready(OLNative *n) { return hid_open(n); }

static void inhibit(OLNative *n, gboolean enabled) {
    GtkNative *native=gtk_widget_get_native(n->picture);
    GdkSurface *surface=native ? gtk_native_get_surface(native) : NULL;
    if (!surface || !GDK_IS_TOPLEVEL(surface) || n->inhibited==enabled) return;
    if (enabled) gdk_toplevel_inhibit_system_shortcuts(GDK_TOPLEVEL(surface),NULL);
    else gdk_toplevel_restore_system_shortcuts(GDK_TOPLEVEL(surface));
    n->inhibited=enabled;
}
static void input(OLNative *n, int kind, int code, double x, double y) {
    if (n->input && g_atomic_int_get(&n->active)) n->input(kind,code,x,y,n->input_context);
}
static gboolean key_pressed(GtkEventControllerKey *c, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    input(data,OL_INPUT_KEY_DOWN,(int)keycode,0,0); return TRUE;
}
static void key_released(GtkEventControllerKey *c, guint keyval, guint keycode, GdkModifierType state, gpointer data) {
    input(data,OL_INPUT_KEY_UP,(int)keycode,0,0);
}
static void pressed(GtkGestureClick *g, int presses, double x, double y, gpointer data) {
    OLNative *n=data;
    gtk_gesture_set_state(GTK_GESTURE(g),GTK_EVENT_SEQUENCE_CLAIMED);
    if (!gtk_widget_has_focus(n->picture)) { gtk_widget_set_focusable(n->picture,TRUE); gtk_widget_grab_focus(n->picture); }
    input(n,OL_INPUT_BUTTON_DOWN,(int)gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g)),x,y);
}
static void released(GtkGestureClick *g, int presses, double x, double y, gpointer data) {
    input(data,OL_INPUT_BUTTON_UP,(int)gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g)),x,y);
}
static void motion(GtkEventControllerMotion *c, double x, double y, gpointer data) { input(data,OL_INPUT_MOTION,0,x,y); }
static gboolean scrolled(GtkEventControllerScroll *c, double dx, double dy, gpointer data) {
    // Report wheel notches. Touchpads report surface pixels; Swift accumulates fractions.
    double scale=gtk_event_controller_scroll_get_unit(c)==GDK_SCROLL_UNIT_SURFACE ? 1.0/20.0 : 1.0;
    input(data,OL_INPUT_SCROLL,0,dx*scale,dy*scale); return TRUE;
}
static void focus_enter(GtkEventControllerFocus *c, gpointer data) { inhibit(data,TRUE); input(data,OL_INPUT_FOCUS_IN,0,0,0); }
static void focus_leave(GtkEventControllerFocus *c, gpointer data) {
    OLNative *n=data;
    // Capture only after an explicit click or menu action, never via Tab or focus restore.
    gtk_widget_set_focusable(n->picture,FALSE);
    inhibit(n,FALSE); input(n,OL_INPUT_FOCUS_OUT,0,0,0);
}
void ol_native_input(OLNative *n, OLNativeInput callback, void *context) {
    n->input=callback; n->input_context=context;
    GtkWidget *w=n->picture;
    gtk_widget_set_focusable(w,FALSE);
    GtkEventController *key=gtk_event_controller_key_new();
    gtk_event_controller_set_propagation_phase(key,GTK_PHASE_CAPTURE);
    g_signal_connect(key,"key-pressed",G_CALLBACK(key_pressed),n);
    g_signal_connect(key,"key-released",G_CALLBACK(key_released),n);
    gtk_widget_add_controller(w,key);
    GtkGesture *click=gtk_gesture_click_new(); gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click),0);
    g_signal_connect(click,"pressed",G_CALLBACK(pressed),n);
    g_signal_connect(click,"released",G_CALLBACK(released),n);
    gtk_widget_add_controller(w,GTK_EVENT_CONTROLLER(click));
    GtkEventController *move=gtk_event_controller_motion_new();
    g_signal_connect(move,"motion",G_CALLBACK(motion),n);
    gtk_widget_add_controller(w,move);
    GtkEventController *scroll=gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_BOTH_AXES);
    g_signal_connect(scroll,"scroll",G_CALLBACK(scrolled),n);
    gtk_widget_add_controller(w,scroll);
    GtkEventController *focus=gtk_event_controller_focus_new();
    g_signal_connect(focus,"enter",G_CALLBACK(focus_enter),n);
    g_signal_connect(focus,"leave",G_CALLBACK(focus_leave),n);
    gtk_widget_add_controller(w,focus);
}
void ol_native_geometry(OLNative *n, double *width, double *height, double *video_width, double *video_height) {
    *width=gtk_widget_get_width(n->picture); *height=gtk_widget_get_height(n->picture);
    GdkPaintable *p=gtk_picture_get_paintable(GTK_PICTURE(n->picture));
    *video_width=p ? gdk_paintable_get_intrinsic_width(p) : 0;
    *video_height=p ? gdk_paintable_get_intrinsic_height(p) : 0;
}
void ol_native_focus(OLNative *n, int focused) {
    if (focused) { gtk_widget_set_focusable(n->picture,TRUE); gtk_widget_grab_focus(n->picture); }
    else {
        GtkRoot *root=gtk_widget_get_root(n->picture);
        if (root && gtk_widget_has_focus(n->picture)) gtk_root_set_focus(root,NULL);
    }
}
void ol_native_cursor(OLNative *n, const char *name) { gtk_widget_set_cursor_from_name(n->picture,name); }

void ol_native_close(OLNative *n) {
    if (!g_atomic_int_compare_and_exchange(&n->active,1,0)) return;
    recorder_abort(n);
    g_cancellable_cancel(n->cancel);
    inhibit(n,FALSE); n->input=NULL;
    if (n->hid) { g_signal_handlers_disconnect_by_data(n->hid,n); soup_websocket_connection_close(n->hid,1000,NULL); }
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

typedef struct {
    OLNative *n;
    SoupMessage *message;
    OLNativeHTTPResponse callback;
    void *context;
} APIRequest;

static void api_request_done(GObject *source, GAsyncResult *result, gpointer data) {
    APIRequest *r=data; GError *error=NULL;
    GBytes *bytes=soup_session_send_and_read_finish(SOUP_SESSION(source),result,&error);
    if (error) {
        if (!g_error_matches(error,G_IO_ERROR,G_IO_ERROR_CANCELLED) && g_atomic_int_get(&r->n->active) && r->callback) {
            r->callback(0,NULL,0,error->message,r->context);
        }
        g_clear_error(&error);
    } else {
        gsize size=0;
        const unsigned char *raw=g_bytes_get_data(bytes,&size);
        if (g_atomic_int_get(&r->n->active) && r->callback) {
            r->callback((int)soup_message_get_status(r->message),raw,(int)size,NULL,r->context);
        }
        g_bytes_unref(bytes);
    }
    g_object_unref(r->message); release(r->n); g_free(r);
}

void ol_native_request(OLNative *n, const char *method, const char *url,
                       const char *content_type, const unsigned char *body, int body_length,
                       OLNativeHTTPResponse callback, void *context) {
    if (!n || !g_atomic_int_get(&n->active)) {
        if (callback) callback(0,NULL,0,"Session is not active",context);
        return;
    }
    SoupMessage *message=soup_message_new(method,url);
    if (!message) {
        if (callback) callback(0,NULL,0,"Invalid API URL",context);
        return;
    }
    guard_tls(n,message);
    if (body && body_length>0) {
        GBytes *bytes=g_bytes_new(body,(gsize)body_length);
        soup_message_set_request_body_from_bytes(message,content_type ? content_type : "application/octet-stream",bytes);
        g_bytes_unref(bytes);
    } else if (content_type && (!g_strcmp0(method,"POST") || !g_strcmp0(method,"PUT"))) {
        GBytes *bytes=g_bytes_new("",0);
        soup_message_set_request_body_from_bytes(message,content_type,bytes);
        g_bytes_unref(bytes);
    }
    APIRequest *r=g_new0(APIRequest,1);
    r->n=retain(n); r->message=message; r->callback=callback; r->context=context;
    soup_session_send_and_read_async(n->http,message,G_PRIORITY_DEFAULT,n->cancel,api_request_done,r);
}

typedef struct {
    guint64 bytes_received;
    gint packets_lost, pli_count, nack_count, jitter_ms, rtt_ms;
    gboolean has_jitter, has_lost, has_pli, has_nack, has_rtt;
    char *codec, *remote_addr, *local_type, *remote_type, *proto;
} StatsAccum;

static gboolean collect_stats_field(GQuark field_id, const GValue *value, gpointer user_data) {
    if (!GST_VALUE_HOLDS_STRUCTURE(value)) return TRUE;
    const GstStructure *s=gst_value_get_structure(value);
    StatsAccum *acc=user_data;
    const char *name=gst_structure_get_name(s);
    const char *type_str=gst_structure_get_string(s,"type");
    if ((type_str && !g_strcmp0(type_str,"inbound-rtp")) || (name && g_str_has_prefix(name,"rtp-inbound-stream-stats"))) {
        guint64 bytes=0;
        if (gst_structure_get_uint64(s,"bytes-received",&bytes) && bytes>0) acc->bytes_received+=bytes;
        gint lost=0;
        if (gst_structure_get_int(s,"packets-lost",&lost)) { acc->packets_lost=lost; acc->has_lost=TRUE; }
        guint pli=0, nack=0;
        if (gst_structure_get_uint(s,"pli-count",&pli)) { acc->pli_count=(gint)pli; acc->has_pli=TRUE; }
        if (gst_structure_get_uint(s,"nack-count",&nack)) { acc->nack_count=(gint)nack; acc->has_nack=TRUE; }
        double jitter=0;
        if (gst_structure_get_double(s,"jitter",&jitter)) { acc->jitter_ms=(gint)llround(jitter*1000.0); acc->has_jitter=TRUE; }
    } else if ((type_str && !g_strcmp0(type_str,"candidate-pair")) || (name && g_str_has_prefix(name,"ice-candidate-pair"))) {
        double rtt=0;
        if (gst_structure_get_double(s,"current-round-trip-time",&rtt) && rtt>=0) {
            acc->rtt_ms=(gint)llround(rtt*1000.0); acc->has_rtt=TRUE;
        }
    } else if (type_str && !g_strcmp0(type_str,"codec")) {
        const char *mime=gst_structure_get_string(s,"mime-type");
        if (!mime) mime=gst_structure_get_string(s,"clock-rate");
        if (mime && g_str_has_prefix(mime,"video/") && !acc->codec) acc->codec=g_strdup(mime+6);
    } else if (type_str && !g_strcmp0(type_str,"remote-candidate")) {
        const char *addr=gst_structure_get_string(s,"address");
        guint port=0; gst_structure_get_uint(s,"port",&port);
        if (addr && !acc->remote_addr) acc->remote_addr=port ? g_strdup_printf("%s:%u",addr,port) : g_strdup(addr);
        const char *ct=gst_structure_get_string(s,"candidate-type");
        if (ct && !acc->remote_type) acc->remote_type=g_strdup(ct);
        const char *pr=gst_structure_get_string(s,"protocol");
        if (pr && !acc->proto) acc->proto=g_ascii_strup(pr,-1);
    } else if (type_str && !g_strcmp0(type_str,"local-candidate")) {
        const char *ct=gst_structure_get_string(s,"candidate-type");
        if (ct && !acc->local_type) acc->local_type=g_strdup(ct);
    }
    return TRUE;
}

static void stats_replied(GstPromise *promise, gpointer data) {
    OLNative *n=data;
    if (gst_promise_wait(promise)==GST_PROMISE_RESULT_REPLIED && g_atomic_int_get(&n->active)) {
        const GstStructure *reply=gst_promise_get_reply(promise);
        StatsAccum acc={0};
        if (reply) gst_structure_foreach(reply,collect_stats_field,&acc);
        gint64 now=g_get_monotonic_time();
        gint kbps=-1;
        if (n->last_stats_us>0 && now>n->last_stats_us && acc.bytes_received>=n->last_bytes_received && acc.bytes_received>0) {
            double dt=(double)(now-n->last_stats_us)/1000000.0;
            if (dt>0.1) kbps=(gint)llround(((double)(acc.bytes_received-n->last_bytes_received)*8.0/1000.0)/dt);
        }
        n->last_bytes_received=acc.bytes_received;
        n->last_stats_us=now;
        gint fps=n->rendered_frames_window;
        n->rendered_frames_window=0;
        GString *json=g_string_new("{");
        g_string_append_printf(json,"\"width\":%d,\"height\":%d,\"fps\":%d",n->last_frame_width,n->last_frame_height,fps);
        if (kbps>=0) g_string_append_printf(json,",\"kbps\":%d",kbps);
        if (acc.has_jitter) g_string_append_printf(json,",\"jitter_ms\":%d",acc.jitter_ms);
        if (acc.has_lost) g_string_append_printf(json,",\"packets_lost\":%d",acc.packets_lost);
        if (acc.has_pli) g_string_append_printf(json,",\"pli_count\":%d",acc.pli_count);
        if (acc.has_nack) g_string_append_printf(json,",\"nack_count\":%d",acc.nack_count);
        if (acc.has_rtt) g_string_append_printf(json,",\"rtt_ms\":%d",acc.rtt_ms);
        if (acc.codec) g_string_append_printf(json,",\"codec\":\"%s\"",acc.codec);
        if (acc.local_type && acc.remote_type) {
            g_string_append_printf(json,",\"path\":\"%s → %s%s%s\"",acc.local_type,acc.remote_type,acc.proto ? " · " : "",acc.proto ? acc.proto : "");
        }
        if (acc.remote_addr) g_string_append_printf(json,",\"remote\":\"%s\"",acc.remote_addr);
        g_string_append_c(json,'}');
        emit(n,"stats",json->str,0);
        g_string_free(json,TRUE);
        g_free(acc.codec); g_free(acc.remote_addr); g_free(acc.local_type); g_free(acc.remote_type); g_free(acc.proto);
    }
    gst_promise_unref(promise);
    release(n);
}

void ol_native_poll_stats(OLNative *n) {
    if (!n || !n->rtc || !g_atomic_int_get(&n->active) || !n->got_frame) return;
    GstPromise *promise=gst_promise_new_with_change_func(stats_replied,retain(n),NULL);
    g_signal_emit_by_name(n->rtc,"get-stats",NULL,promise);
}

int ol_native_screenshot(OLNative *n, const char *path, char **error_out) {
    if (!n || !n->picture || !path) {
        if (error_out) *error_out=g_strdup("No active video session.");
        return 0;
    }
    GdkPaintable *paintable=gtk_picture_get_paintable(GTK_PICTURE(n->picture));
    if (!paintable || !GDK_IS_TEXTURE(paintable)) {
        if (error_out) *error_out=g_strdup("No decoded video frame available yet.");
        return 0;
    }
    char *dir=g_path_get_dirname(path);
    if (dir) { g_mkdir_with_parents(dir,0755); g_free(dir); }
    if (!gdk_texture_save_to_png(GDK_TEXTURE(paintable),path)) {
        if (error_out) *error_out=g_strdup("Failed to write PNG screenshot to disk.");
        return 0;
    }
    return 1;
}

typedef void *(*VAGetDisplayDRMFunc)(int fd);
typedef int (*VAInitializeFunc)(void *dpy, int *major, int *minor);
typedef int (*VATerminateFunc)(void *dpy);
typedef const char *(*VAQueryVendorStringFunc)(void *dpy);
typedef int (*VAQueryConfigEntrypointsFunc)(void *dpy, int profile, int *entrypoints, int *num_entrypoints);

static gboolean probe_single_drm_node(const char *node_path, VAGetDisplayDRMFunc get_dpy, VAInitializeFunc va_init,
                                      VATerminateFunc va_term, VAQueryVendorStringFunc va_vendor,
                                      VAQueryConfigEntrypointsFunc va_entrypoints,
                                      gboolean *out_h264, gboolean *out_hevc, char **out_driver) {
    int fd=open(node_path,O_RDWR|O_CLOEXEC);
    if (fd<0) return FALSE;
    void *dpy=get_dpy(fd);
    if (!dpy) { close(fd); return FALSE; }
    int major=0, minor=0;
    if (va_init(dpy,&major,&minor)!=0) { close(fd); return FALSE; }
    const int h264_profiles[]={6,7,13};
    const int hevc_profiles[]={17,18};
    int eps[32]; int num_eps=0;
    *out_h264=FALSE; *out_hevc=FALSE;
    for (gsize i=0;i<G_N_ELEMENTS(h264_profiles);i++) {
        num_eps=0;
        if (va_entrypoints(dpy,h264_profiles[i],eps,&num_eps)==0) {
            for (int j=0;j<num_eps && j<32;j++) if (eps[j]==6 || eps[j]==8) *out_h264=TRUE;
        }
    }
    for (gsize i=0;i<G_N_ELEMENTS(hevc_profiles);i++) {
        num_eps=0;
        if (va_entrypoints(dpy,hevc_profiles[i],eps,&num_eps)==0) {
            for (int j=0;j<num_eps && j<32;j++) if (eps[j]==6 || eps[j]==8) *out_hevc=TRUE;
        }
    }
    if ((*out_h264 || *out_hevc) && out_driver) {
        const char *v=va_vendor ? va_vendor(dpy) : NULL;
        *out_driver=g_strdup(v ? v : "VA-API");
    }
    va_term(dpy);
    close(fd);
    return *out_h264 || *out_hevc;
}

static gboolean find_vaapi_encoder(const char *preferred_device, char **out_device, char **out_driver,
                                   gboolean *out_h264, gboolean *out_hevc) {
    void *libva=dlopen("libva.so.2",RTLD_LAZY|RTLD_LOCAL);
    if (!libva) libva=dlopen("libva.so",RTLD_LAZY|RTLD_LOCAL);
    void *libvadrm=dlopen("libva-drm.so.2",RTLD_LAZY|RTLD_LOCAL);
    if (!libvadrm) libvadrm=dlopen("libva-drm.so",RTLD_LAZY|RTLD_LOCAL);
    if (!libva || !libvadrm) {
        if (libva) dlclose(libva);
        if (libvadrm) dlclose(libvadrm);
        return FALSE;
    }
    VAGetDisplayDRMFunc get_dpy=(VAGetDisplayDRMFunc)dlsym(libvadrm,"vaGetDisplayDRM");
    VAInitializeFunc va_init=(VAInitializeFunc)dlsym(libva,"vaInitialize");
    VATerminateFunc va_term=(VATerminateFunc)dlsym(libva,"vaTerminate");
    VAQueryVendorStringFunc va_vendor=(VAQueryVendorStringFunc)dlsym(libva,"vaQueryVendorString");
    VAQueryConfigEntrypointsFunc va_eps=(VAQueryConfigEntrypointsFunc)dlsym(libva,"vaQueryConfigEntrypoints");
    if (!get_dpy || !va_init || !va_term || !va_eps) {
        dlclose(libvadrm); dlclose(libva); return FALSE;
    }
    gboolean found=FALSE;
    if (preferred_device && preferred_device[0]) {
        gboolean h264=FALSE, hevc=FALSE; char *drv=NULL;
        if (probe_single_drm_node(preferred_device,get_dpy,va_init,va_term,va_vendor,va_eps,&h264,&hevc,&drv)) {
            if (out_device) *out_device=g_strdup(preferred_device);
            if (out_driver) *out_driver=drv; else g_free(drv);
            if (out_h264) *out_h264=h264;
            if (out_hevc) *out_hevc=hevc;
            found=TRUE;
        }
    }
    for (int idx=128; !found && idx<=135; idx++) {
        char path[64]; g_snprintf(path,sizeof(path),"/dev/dri/renderD%d",idx);
        gboolean h264=FALSE, hevc=FALSE; char *drv=NULL;
        if (probe_single_drm_node(path,get_dpy,va_init,va_term,va_vendor,va_eps,&h264,&hevc,&drv)) {
            if (out_device) *out_device=g_strdup(path);
            if (out_driver) *out_driver=drv; else g_free(drv);
            if (out_h264) *out_h264=h264;
            if (out_hevc) *out_hevc=hevc;
            found=TRUE;
        }
    }
    dlclose(libvadrm); dlclose(libva);
    return found;
}

char *ol_vaapi_probe(const char *preferred_device) {
    char *dev=NULL, *drv=NULL; gboolean h264=FALSE, hevc=FALSE;
    if (!find_vaapi_encoder(preferred_device,&dev,&drv,&h264,&hevc)) {
        return g_strdup("{\"available\":false,\"device\":\"\",\"driver\":\"\",\"h264\":false,\"hevc\":false}");
    }
    GString *s=g_string_new("{\"available\":true,\"device\":\"");
    for (const char *p=dev;*p;p++) { if (*p=='"'||*p=='\\') g_string_append_c(s,'\\'); g_string_append_c(s,*p); }
    g_string_append(s,"\",\"driver\":\"");
    for (const char *p=drv?drv:"";*p;p++) { if (*p=='"'||*p=='\\') g_string_append_c(s,'\\'); g_string_append_c(s,*p); }
    g_string_append_printf(s,"\",\"h264\":%s,\"hevc\":%s}",h264?"true":"false",hevc?"true":"false");
    g_free(dev); g_free(drv);
    return g_string_free(s,FALSE);
}

struct OLRecorder {
    OLNative *owner;
    char *path, *backend;
    int width, height, stride, frames;
    gint64 start_us, last_push_us;
    guint timer_id;
    gboolean use_ffmpeg;
    GPid ffmpeg_pid;
    int ffmpeg_stdin;
    GAsyncQueue *queue;
    GThread *writer_thread;
    GstElement *gst_pipe, *gst_src;
};

static gpointer ffmpeg_writer_loop(gpointer data) {
    OLRecorder *rec=data;
    gsize frame_bytes=(gsize)rec->stride * (gsize)rec->height;
    while (TRUE) {
        GBytes *bytes=g_async_queue_pop(rec->queue);
        gsize sz=0; const guint8 *ptr=g_bytes_get_data(bytes,&sz);
        if (sz==0) { g_bytes_unref(bytes); break; }
        gsize written=0;
        while (written<frame_bytes && written<sz) {
            ssize_t n=write(rec->ffmpeg_stdin,ptr+written,frame_bytes-written);
            if (n<=0) break;
            written+=(gsize)n;
        }
        g_bytes_unref(bytes);
    }
    if (rec->ffmpeg_stdin>=0) { close(rec->ffmpeg_stdin); rec->ffmpeg_stdin=-1; }
    return NULL;
}

static void recorder_push_frame(OLRecorder *rec, GBytes *bytes, int width, int height, int stride) {
    if (!rec || !bytes || width!=rec->width || height!=rec->height) return;
    rec->last_push_us=g_get_monotonic_time();
    if (rec->use_ffmpeg) {
        if (g_async_queue_length(rec->queue)<15) {
            g_async_queue_push(rec->queue,g_bytes_ref(bytes));
            rec->frames++;
        }
    } else if (rec->gst_src) {
        gsize sz=0; const void *raw=g_bytes_get_data(bytes,&sz);
        GstBuffer *buf=gst_buffer_new_memdup(raw,sz);
        GstClockTime pts=(GstClockTime)((g_get_monotonic_time()-rec->start_us)*1000);
        GST_BUFFER_PTS(buf)=pts; GST_BUFFER_DTS(buf)=pts;
        GST_BUFFER_DURATION(buf)=GST_SECOND/30;
        if (gst_app_src_push_buffer(GST_APP_SRC(rec->gst_src),buf)==GST_FLOW_OK) rec->frames++;
    }
}

static gboolean recorder_keepalive_tick(gpointer data) {
    OLRecorder *rec=data; OLNative *n=rec->owner;
    if (!n || n->recorder!=rec || !n->last_frame_bytes) return G_SOURCE_CONTINUE;
    if (g_get_monotonic_time()-rec->last_push_us>=33000) {
        recorder_push_frame(rec,n->last_frame_bytes,n->last_frame_width,n->last_frame_height,n->last_frame_stride);
    }
    return G_SOURCE_CONTINUE;
}

static char *find_gst_vaapi_element(const char *va_dev, int hevc) {
    const char *base=va_dev ? strrchr(va_dev,'/') : NULL;
    base=base ? base+1 : "";
    GPtrArray *candidates=g_ptr_array_new_with_free_func(g_free);
    if (g_str_has_prefix(base,"renderD") && g_strcmp0(base,"renderD128")!=0) {
        g_ptr_array_add(candidates,g_strdup_printf("va%s%senc",base,hevc?"h265":"h264"));
        g_ptr_array_add(candidates,g_strdup_printf("va%s%slpenc",base,hevc?"h265":"h264"));
    } else {
        g_ptr_array_add(candidates,g_strdup(hevc?"vah265enc":"vah264enc"));
        g_ptr_array_add(candidates,g_strdup(hevc?"vah265lpenc":"vah264lpenc"));
        g_ptr_array_add(candidates,g_strdup(hevc?"vaapih265enc":"vaapih264enc"));
    }
    char *found=NULL;
    for (guint i=0;i<candidates->len && !found;i++) {
        const char *name=g_ptr_array_index(candidates,i);
        GstElementFactory *f=gst_element_factory_find(name);
        if (f) { found=g_strdup(name); gst_object_unref(f); }
    }
    g_ptr_array_free(candidates,TRUE);
    return found;
}

int ol_native_record_start(OLNative *n, const char *path, int hevc, const char *vaapi_device,
                           char **backend_out, char **error_out) {
    if (!n || !g_atomic_int_get(&n->active)) {
        if (error_out) *error_out=g_strdup("No active session.");
        return 0;
    }
    if (n->recorder) {
        if (error_out) *error_out=g_strdup("A recording is already in progress.");
        return 0;
    }
    if (!n->last_frame_bytes || n->last_frame_width<=0 || n->last_frame_height<=0) {
        if (error_out) *error_out=g_strdup("Wait for a video frame before starting a recording.");
        return 0;
    }
    char *dir=g_path_get_dirname(path);
    if (dir) { g_mkdir_with_parents(dir,0755); g_free(dir); }

    char *va_dev=NULL, *va_drv=NULL; gboolean va_h264=FALSE, va_hevc=FALSE;
    gboolean has_va=find_vaapi_encoder(vaapi_device,&va_dev,&va_drv,&va_h264,&va_hevc);
    gboolean can_va_codec=has_va && (hevc ? va_hevc : va_h264);

    OLRecorder *rec=g_new0(OLRecorder,1);
    rec->owner=n; rec->path=g_strdup(path);
    rec->width=n->last_frame_width; rec->height=n->last_frame_height; rec->stride=n->last_frame_stride;
    rec->start_us=g_get_monotonic_time(); rec->ffmpeg_stdin=-1;

    char *gst_va=can_va_codec ? find_gst_vaapi_element(va_dev,hevc) : NULL;
    if (gst_va) {
        char *desc=g_strdup_printf(
            "appsrc name=recsrc is-live=true format=time do-timestamp=false caps=\"video/x-raw,format=RGBA,width=%d,height=%d,framerate=30/1\" ! "
            "videoconvert ! video/x-raw,format=NV12 ! %s ! %s ! mp4mux faststart=true ! filesink name=recsink",
            rec->width,rec->height,gst_va,hevc?"h265parse":"h264parse");
        GError *err=NULL;
        rec->gst_pipe=gst_parse_launch(desc,&err);
        g_free(desc);
        if (rec->gst_pipe) {
            GstElement *sink=gst_bin_get_by_name(GST_BIN(rec->gst_pipe),"recsink");
            g_object_set(sink,"location",path,NULL); gst_object_unref(sink);
            rec->gst_src=gst_bin_get_by_name(GST_BIN(rec->gst_pipe),"recsrc");
            if (gst_element_set_state(rec->gst_pipe,GST_STATE_PLAYING)!=GST_STATE_CHANGE_FAILURE) {
                rec->backend=g_strdup_printf("VAAPI %s (%s · %s)",hevc?"HEVC":"H.264",va_dev,gst_va);
            } else {
                gst_clear_object(&rec->gst_src); gst_element_set_state(rec->gst_pipe,GST_STATE_NULL); gst_clear_object(&rec->gst_pipe);
            }
        }
        g_clear_error(&err); g_free(gst_va);
    }

    if (!rec->gst_pipe && can_va_codec) {
        char *ffmpeg_bin=g_find_program_in_path("ffmpeg");
        if (ffmpeg_bin) {
            char *va_arg=g_strdup_printf("vaapi=va:%s",va_dev);
            char *size_arg=g_strdup_printf("%dx%d",rec->width,rec->height);
            char *argv[]={
                ffmpeg_bin,"-y","-hide_banner","-loglevel","error",
                "-init_hw_device",va_arg,
                "-f","rawvideo","-pix_fmt","rgba","-s",size_arg,"-r","30","-i","pipe:0",
                "-vf","format=nv12,hwupload,scale_vaapi=w=trunc(iw/2)*2:h=trunc(ih/2)*2:format=nv12",
                "-c:v",hevc?"hevc_vaapi":"h264_vaapi","-qp","22",
                "-f","mp4","-movflags","+faststart",(char *)path,NULL
            };
            GError *err=NULL;
            if (g_spawn_async_with_pipes(NULL,argv,NULL,G_SPAWN_DO_NOT_REAP_CHILD|G_SPAWN_STDERR_TO_DEV_NULL|G_SPAWN_STDOUT_TO_DEV_NULL,
                                         NULL,NULL,&rec->ffmpeg_pid,&rec->ffmpeg_stdin,NULL,NULL,&err)) {
                rec->use_ffmpeg=TRUE;
                rec->queue=g_async_queue_new_full((GDestroyNotify)g_bytes_unref);
                rec->writer_thread=g_thread_new("overlook-vaapi-rec",ffmpeg_writer_loop,rec);
                rec->backend=g_strdup_printf("VAAPI %s (%s)",hevc?"HEVC":"H.264",va_dev);
            }
            g_clear_error(&err); g_free(va_arg); g_free(size_arg); g_free(ffmpeg_bin);
        }
    }

    if (!rec->gst_pipe && !rec->use_ffmpeg) {
        const char *sw_enc=NULL, *sw_parse="h264parse";
        if (hevc && gst_element_factory_find("x265enc")) { sw_enc="x265enc speed-preset=ultrafast"; sw_parse="h265parse"; }
        else if (gst_element_factory_find("x264enc")) { sw_enc="x264enc tune=zerolatency speed-preset=ultrafast"; }
        else if (gst_element_factory_find("openh264enc")) { sw_enc="openh264enc"; }
        if (sw_enc) {
            char *desc=g_strdup_printf(
                "appsrc name=recsrc is-live=true format=time do-timestamp=false caps=\"video/x-raw,format=RGBA,width=%d,height=%d,framerate=30/1\" ! "
                "videoconvert ! %s ! %s ! mp4mux faststart=true ! filesink name=recsink",
                rec->width,rec->height,sw_enc,sw_parse);
            GError *err=NULL;
            rec->gst_pipe=gst_parse_launch(desc,&err);
            g_free(desc); g_clear_error(&err);
            if (rec->gst_pipe) {
                GstElement *sink=gst_bin_get_by_name(GST_BIN(rec->gst_pipe),"recsink");
                g_object_set(sink,"location",path,NULL); gst_object_unref(sink);
                rec->gst_src=gst_bin_get_by_name(GST_BIN(rec->gst_pipe),"recsrc");
                if (gst_element_set_state(rec->gst_pipe,GST_STATE_PLAYING)!=GST_STATE_CHANGE_FAILURE) {
                    rec->backend=g_strdup("Software H.264 (VAAPI fallback)");
                } else {
                    gst_clear_object(&rec->gst_src); gst_element_set_state(rec->gst_pipe,GST_STATE_NULL); gst_clear_object(&rec->gst_pipe);
                }
            }
        }
    }

    g_free(va_dev); g_free(va_drv);
    if (!rec->gst_pipe && !rec->use_ffmpeg) {
        if (error_out) *error_out=g_strdup("Could not initialize VAAPI or software MP4 encoder.");
        g_free(rec->path); g_free(rec); return 0;
    }
    n->recorder=rec;
    recorder_push_frame(rec,n->last_frame_bytes,n->last_frame_width,n->last_frame_height,n->last_frame_stride);
    rec->timer_id=g_timeout_add(33,recorder_keepalive_tick,rec);
    if (backend_out) *backend_out=g_strdup(rec->backend ? rec->backend : "VAAPI");
    return 1;
}

static void recorder_free(OLRecorder *rec) {
    if (!rec) return;
    if (rec->timer_id) g_source_remove(rec->timer_id);
    if (rec->gst_src) gst_object_unref(rec->gst_src);
    if (rec->gst_pipe) { gst_element_set_state(rec->gst_pipe,GST_STATE_NULL); gst_object_unref(rec->gst_pipe); }
    if (rec->queue) g_async_queue_unref(rec->queue);
    g_free(rec->path); g_free(rec->backend); g_free(rec);
}

static void recorder_abort(OLNative *n) {
    if (!n || !n->recorder) return;
    double dur=0; int frames=0; char *err=NULL;
    ol_native_record_stop(n,&dur,&frames,&err);
    g_free(err);
}

int ol_native_record_stop(OLNative *n, double *duration_out, int *frames_out, char **error_out) {
    if (!n || !n->recorder) {
        if (error_out) *error_out=g_strdup("No recording is in progress.");
        return 0;
    }
    OLRecorder *rec=n->recorder;
    n->recorder=NULL;
    if (rec->timer_id) { g_source_remove(rec->timer_id); rec->timer_id=0; }
    if (rec->frames<2 && n->last_frame_bytes) {
        recorder_push_frame(rec,n->last_frame_bytes,n->last_frame_width,n->last_frame_height,n->last_frame_stride);
    }
    double duration=(double)(g_get_monotonic_time()-rec->start_us)/1000000.0;
    if (duration<0.1) duration=0.1;
    int status_ok=1;
    if (rec->use_ffmpeg) {
        g_async_queue_push(rec->queue,g_bytes_new_static("",0));
        if (rec->writer_thread) { g_thread_join(rec->writer_thread); rec->writer_thread=NULL; }
        int wstatus=0;
        waitpid(rec->ffmpeg_pid,&wstatus,0);
        g_spawn_close_pid(rec->ffmpeg_pid);
        if (!WIFEXITED(wstatus) || WEXITSTATUS(wstatus)!=0) {
            status_ok=0;
            if (error_out) *error_out=g_strdup("VAAPI encoder process exited with an error.");
        }
    } else if (rec->gst_pipe && rec->gst_src) {
        gst_app_src_end_of_stream(GST_APP_SRC(rec->gst_src));
        GstBus *bus=gst_element_get_bus(rec->gst_pipe);
        GstMessage *msg=gst_bus_timed_pop_filtered(bus,3*GST_SECOND,GST_MESSAGE_EOS|GST_MESSAGE_ERROR);
        if (msg) {
            if (GST_MESSAGE_TYPE(msg)==GST_MESSAGE_ERROR) {
                status_ok=0;
                if (error_out) *error_out=g_strdup("GStreamer recording pipeline reported an error.");
            }
            gst_message_unref(msg);
        }
        gst_object_unref(bus);
    }
    if (status_ok && !g_file_test(rec->path,G_FILE_TEST_EXISTS)) {
        status_ok=0;
        if (error_out) *error_out=g_strdup("Recording output file was not created.");
    }
    if (duration_out) *duration_out=duration;
    if (frames_out) *frames_out=rec->frames;
    recorder_free(rec);
    return status_ok;
}

int ol_native_is_recording(OLNative *n) {
    return (n && n->recorder!=NULL) ? 1 : 0;
}
