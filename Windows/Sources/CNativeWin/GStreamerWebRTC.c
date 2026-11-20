#ifndef GST_USE_UNSTABLE_API
#define GST_USE_UNSTABLE_API 1
#endif
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "NativeInternal.h"
#include <windows.h>
#include <shlobj.h>
#ifdef interface
#undef interface
#endif
#include <gst/gst.h>
#include <gst/webrtc/webrtc.h>
#include <gst/sdp/sdp.h>
#include <gst/app/gstappsink.h>
#include <gst/app/gstappsrc.h>
#include <gst/video/video.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct OLGstState {
    CRITICAL_SECTION lock;
    GstElement *pipeline;
    GstElement *rtc;
    GstElement *sender;
    GstElement *sender_rtc;
    gboolean recv_transceiver_added;
    ULONGLONG last_stats_ms;
    guint64 last_bytes_received;
};

struct OLRecorder {
    OLNative *owner;
    char *path;
    char *backend;
    int width;
    int height;
    int stride;
    int frames;
    ULONGLONG start_ms;
    ULONGLONG last_push_ms;
    LARGE_INTEGER qpc_freq;
    LARGE_INTEGER start_qpc;
    GstClockTime last_pts;
    int has_last_pts;
    uint32_t timer_id;
    GstElement *gst_pipe;
    GstElement *gst_src;
    CRITICAL_SECTION lock;
};

static INIT_ONCE g_gst_init_once = INIT_ONCE_STATIC_INIT;

static void prepend_env_path(const wchar_t *dir) {
    if (!dir || !dir[0]) return;
    DWORD cur_len = GetEnvironmentVariableW(L"PATH", NULL, 0);
    size_t dir_len = wcslen(dir);
    wchar_t *buf = (wchar_t *)calloc(dir_len + cur_len + 4, sizeof(wchar_t));
    if (!buf) return;
    wcscpy_s(buf, dir_len + cur_len + 4, dir);
    if (cur_len > 1) {
        wchar_t *cur = (wchar_t *)calloc(cur_len + 1, sizeof(wchar_t));
        if (cur) {
            if (GetEnvironmentVariableW(L"PATH", cur, cur_len) > 0) {
                if (_wcsnicmp(cur, dir, dir_len) != 0) {
                    wcscat_s(buf, dir_len + cur_len + 4, L";");
                    wcscat_s(buf, dir_len + cur_len + 4, cur);
                    SetEnvironmentVariableW(L"PATH", buf);
                }
            }
            free(cur);
        }
    } else {
        SetEnvironmentVariableW(L"PATH", buf);
    }
    free(buf);
}

static BOOL CALLBACK init_gstreamer_once(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    (void)once;
    (void)param;
    (void)ctx;

    wchar_t exe_dir[4096] = {0};
    DWORD n = GetModuleFileNameW(NULL, exe_dir, (DWORD)(sizeof(exe_dir) / sizeof(exe_dir[0])));
    if (n > 0 && n < 4096) {
        wchar_t *slash = wcsrchr(exe_dir, L'\\');
        if (slash) {
            *slash = L'\0';
            wchar_t plugin_dir[4096] = {0};
            if (swprintf_s(plugin_dir, 4096, L"%ls\\gstreamer-plugins", exe_dir) > 0) {
                DWORD attrs = GetFileAttributesW(plugin_dir);
                if (attrs != INVALID_FILE_ATTRIBUTES && (attrs & FILE_ATTRIBUTE_DIRECTORY)) {
                    prepend_env_path(exe_dir);
                    SetEnvironmentVariableW(L"GST_PLUGIN_SYSTEM_PATH_1_0", L"");
                    SetEnvironmentVariableW(L"GST_PLUGIN_PATH_1_0", plugin_dir);
                    SetEnvironmentVariableW(L"GST_REGISTRY_FORK", L"no");

                    wchar_t local_app[4096] = {0};
                    DWORD app_len = GetEnvironmentVariableW(L"LOCALAPPDATA", local_app, 4096);
                    if (app_len == 0 || app_len >= 4096) {
                        DWORD prof_len = GetEnvironmentVariableW(L"USERPROFILE", local_app, 3900);
                        if (prof_len > 0 && prof_len < 3900) {
                            wcscat_s(local_app, 4096, L"\\AppData\\Local");
                        } else {
                            local_app[0] = L'\0';
                        }
                    }
                    if (local_app[0]) {
                        wchar_t reg_dir[4096] = {0};
                        wchar_t reg_file[4096] = {0};
                        if (swprintf_s(reg_dir, 4096, L"%ls\\Overlook", local_app) > 0) {
                            CreateDirectoryW(reg_dir, NULL);
                            if (swprintf_s(reg_file, 4096, L"%ls\\gstreamer-registry-1.0.bin", reg_dir) > 0) {
                                SetEnvironmentVariableW(L"GST_REGISTRY_1_0", reg_file);
                            }
                        }
                    }
                }
            }
        }
    }

    gst_init(NULL, NULL);
    return TRUE;
}

static void ensure_gstreamer_initialized(void) {
    InitOnceExecuteOnce(&g_gst_init_once, init_gstreamer_once, NULL, NULL);
}

static void release_destroy(gpointer data) {
    ol_internal_release((OLNative *)data);
}

static void release_closure(gpointer data, GClosure *closure) {
    (void)closure;
    ol_internal_release((OLNative *)data);
}

static GstElement *ref_gst_element(OLGstState *gst, GstElement **field) {
    if (!gst || !field) return NULL;
    EnterCriticalSection(&gst->lock);
    GstElement *el = *field ? (GstElement *)gst_object_ref(*field) : NULL;
    LeaveCriticalSection(&gst->lock);
    return el;
}

static GstBusSyncReply bus_sync_handler(GstBus *bus, GstMessage *message, gpointer data) {
    (void)bus;
    OLNative *n = (OLNative *)data;
    if (GST_MESSAGE_TYPE(message) == GST_MESSAGE_ERROR) {
        GError *error = NULL;
        gchar *debug = NULL;
        gst_message_parse_error(message, &error, &debug);
        if (error) {
            ol_internal_emit_event(n, "error", error->message, 0);
            g_clear_error(&error);
        }
        g_free(debug);
    }
    gst_message_unref(message);
    return GST_BUS_DROP;
}

static GstFlowReturn sample_ready(GstAppSink *sink, gpointer data) {
    OLNative *n = (OLNative *)data;
    GstSample *sample = gst_app_sink_pull_sample(sink);
    if (!sample) return GST_FLOW_EOS;

    if (ol_internal_is_active(n) && ol_internal_try_begin_frame(n)) {
        GstVideoInfo info;
        GstVideoFrame frame;
        GstCaps *caps = gst_sample_get_caps(sample);
        GstBuffer *buf = gst_sample_get_buffer(sample);
        if (caps && buf &&
            gst_video_info_from_caps(&info, caps) &&
            gst_video_frame_map(&frame, &info, buf, GST_MAP_READ)) {
            int w = GST_VIDEO_INFO_WIDTH(&info);
            int h = GST_VIDEO_INFO_HEIGHT(&info);
            if (w > 0 && h > 0 && w <= 8192 && h <= 8192) {
                int stride = w * 4;
                size_t total = (size_t)stride * (size_t)h;
                uint8_t *pixels = (uint8_t *)malloc(total);
                if (pixels) {
                    const uint8_t *src = (const uint8_t *)GST_VIDEO_FRAME_PLANE_DATA(&frame, 0);
                    int src_stride = GST_VIDEO_FRAME_PLANE_STRIDE(&frame, 0);
                    if (src_stride == stride) {
                        memcpy(pixels, src, total);
                    } else if (src_stride > 0) {
                        size_t copy_bytes = (size_t)(src_stride < stride ? src_stride : stride);
                        for (int y = 0; y < h; y++) {
                            memcpy(pixels + (size_t)y * (size_t)stride,
                                   src + (size_t)y * (size_t)src_stride,
                                   copy_bytes);
                        }
                    }
                    gst_video_frame_unmap(&frame);
                    ol_internal_deliver_frame_locked(n, pixels, w, h, stride);
                } else {
                    gst_video_frame_unmap(&frame);
                    ol_internal_cancel_frame(n);
                }
            } else {
                gst_video_frame_unmap(&frame);
                ol_internal_cancel_frame(n);
            }
        } else {
            ol_internal_cancel_frame(n);
        }
    }

    gst_sample_unref(sample);
    return GST_FLOW_OK;
}

static void decoded_pad(GstElement *decode, GstPad *pad, gpointer data) {
    (void)decode;
    OLNative *n = (OLNative *)data;
    if (!ol_internal_is_active(n)) return;

    GstCaps *caps = gst_pad_get_current_caps(pad);
    if (!caps) return;
    const GstStructure *st = gst_caps_get_structure(caps, 0);
    gboolean is_video = st && g_str_has_prefix(gst_structure_get_name(st), "video/x-raw");
    GstCapsFeatures *features = gst_caps_get_features(caps, 0);
    gboolean is_d3d11 = (features && gst_caps_features_contains(features, "memory:D3D11Memory"));
    gst_caps_unref(caps);

    if (!is_video || !ol_internal_is_active(n)) return;

    GError *error = NULL;
    GstElement *output = NULL;
    if (is_d3d11) {
        output = gst_parse_bin_from_description(
            "d3d11convert ! d3d11download ! video/x-raw,format=BGRA ! appsink name=frames sync=false max-buffers=1 drop=true emit-signals=true",
            TRUE, &error);
        if (!output) {
            g_clear_error(&error);
            output = gst_parse_bin_from_description(
                "d3d11download ! videoconvert ! video/x-raw,format=BGRA ! appsink name=frames sync=false max-buffers=1 drop=true emit-signals=true",
                TRUE, &error);
        }
    }
    if (!output) {
        g_clear_error(&error);
        output = gst_parse_bin_from_description(
            "videoconvert ! video/x-raw,format=BGRA ! appsink name=frames sync=false max-buffers=1 drop=true emit-signals=true",
            TRUE, &error);
    }
    if (!output) {
        ol_internal_emit_event(n, "error", error ? error->message : "Cannot build video output bin", 0);
        g_clear_error(&error);
        return;
    }

    GstElement *sink = gst_bin_get_by_name(GST_BIN(output), "frames");
    if (sink) {
        g_signal_connect_data(sink, "new-sample", G_CALLBACK(sample_ready),
                              ol_internal_retain(n), release_closure, 0);
        gst_object_unref(sink);
    }

    OLGstState *gst = ol_internal_get_gst(n);
    GstElement *pipeline = ref_gst_element(gst, gst ? &gst->pipeline : NULL);
    if (!pipeline) {
        gst_object_unref(output);
        return;
    }

    gst_bin_add(GST_BIN(pipeline), output);
    GstPad *target = gst_element_get_static_pad(output, "sink");
    if (!target || gst_pad_link(pad, target) != GST_PAD_LINK_OK) {
        ol_internal_emit_event(n, "error", "Cannot link decoded video to Windows viewport", 0);
    }
    if (target) gst_object_unref(target);
    gst_element_sync_state_with_parent(output);
    gst_object_unref(pipeline);
}

static void incoming_pad(GstElement *rtc, GstPad *pad, gpointer data) {
    (void)rtc;
    OLNative *n = (OLNative *)data;
    if (GST_PAD_DIRECTION(pad) != GST_PAD_SRC || !ol_internal_is_active(n)) return;

    OLGstState *gst = ol_internal_get_gst(n);
    GstElement *pipeline = ref_gst_element(gst, gst ? &gst->pipeline : NULL);
    if (!pipeline) return;

    GstElement *decode = gst_element_factory_make("decodebin", NULL);
    if (!decode) {
        gst_object_unref(pipeline);
        ol_internal_emit_event(n, "error", "Missing GStreamer decodebin plugin", 0);
        return;
    }
    g_signal_connect_data(decode, "pad-added", G_CALLBACK(decoded_pad),
                          ol_internal_retain(n), release_closure, 0);
    gst_bin_add(GST_BIN(pipeline), decode);
    GstPad *target = gst_element_get_static_pad(decode, "sink");
    if (!target || gst_pad_link(pad, target) != GST_PAD_LINK_OK) {
        ol_internal_emit_event(n, "error", "Cannot link incoming RTP decoder", 0);
    }
    if (target) gst_object_unref(target);
    gst_element_sync_state_with_parent(decode);
    gst_object_unref(pipeline);
}

static void local_ice(GstElement *rtc, guint line, gchar *candidate, gpointer data) {
    (void)rtc;
    OLNative *n = (OLNative *)data;
    if (!ol_internal_is_active(n) || !candidate) return;
    OLGstState *gst = ol_internal_get_gst(n);
    GstElement *sender_rtc = ref_gst_element(gst, gst ? &gst->sender_rtc : NULL);
    if (sender_rtc) {
        g_signal_emit_by_name(sender_rtc, "add-ice-candidate", line, candidate);
        gst_object_unref(sender_rtc);
    } else {
        ol_internal_emit_event(n, "ice", candidate, (int)line);
    }
}

static void ice_state(GObject *rtc, GParamSpec *pspec, gpointer data) {
    (void)pspec;
    OLNative *n = (OLNative *)data;
    GstWebRTCICEConnectionState state = GST_WEBRTC_ICE_CONNECTION_STATE_NEW;
    g_object_get(rtc, "ice-connection-state", &state, NULL);
    if (state == GST_WEBRTC_ICE_CONNECTION_STATE_FAILED) {
        ol_internal_emit_event(n, "error",
            "ICE failed. Check network routing or firewall; TURN is not configured.", 0);
    }
}

static gboolean promise_ok(GstPromise *p, OLNative *n) {
    if (gst_promise_wait(p) != GST_PROMISE_RESULT_REPLIED) return FALSE;
    const GstStructure *reply = gst_promise_get_reply(p);
    GError *error = NULL;
    if (reply && gst_structure_get(reply, "error", G_TYPE_ERROR, &error, NULL)) {
        if (error) {
            ol_internal_emit_event(n, "error", error->message, 0);
            g_error_free(error);
        }
        return FALSE;
    }
    return ol_internal_is_active(n) != 0;
}

typedef struct {
    OLNative *n;
    GstWebRTCSessionDescription *desc;
} LocalDesc;

static void free_local_desc(gpointer data) {
    LocalDesc *local = (LocalDesc *)data;
    if (local->desc) gst_webrtc_session_description_free(local->desc);
    ol_internal_release(local->n);
    g_free(local);
}

static void local_answer_set(GstPromise *promise, gpointer data) {
    LocalDesc *local = (LocalDesc *)data;
    OLNative *n = local->n;
    if (promise_ok(promise, n) && local->desc) {
        OLGstState *gst = ol_internal_get_gst(n);
        GstElement *sender_rtc = ref_gst_element(gst, gst ? &gst->sender_rtc : NULL);
        if (sender_rtc) {
            g_signal_emit_by_name(sender_rtc, "set-remote-description", local->desc, NULL);
            gst_object_unref(sender_rtc);
        } else {
            gchar *sdp = gst_sdp_message_as_text(local->desc->sdp);
            if (sdp) {
                ol_internal_emit_event(n, "answer", sdp, 0);
                g_free(sdp);
            }
        }
    }
    gst_promise_unref(promise);
}

static void answer_created(GstPromise *promise, gpointer data) {
    OLNative *n = (OLNative *)data;
    if (promise_ok(promise, n)) {
        GstWebRTCSessionDescription *answer = NULL;
        const GstStructure *reply = gst_promise_get_reply(promise);
        if (reply) gst_structure_get(reply, "answer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &answer, NULL);
        if (answer) {
            OLGstState *gst = ol_internal_get_gst(n);
            GstElement *rtc = ref_gst_element(gst, gst ? &gst->rtc : NULL);
            if (rtc) {
                LocalDesc *local = g_new0(LocalDesc, 1);
                local->n = ol_internal_retain(n);
                local->desc = answer;
                GstPromise *next = gst_promise_new_with_change_func(local_answer_set, local, free_local_desc);
                g_signal_emit_by_name(rtc, "set-local-description", answer, next);
                gst_object_unref(rtc);
            } else {
                gst_webrtc_session_description_free(answer);
            }
        } else {
            ol_internal_emit_event(n, "error", "GStreamer did not generate an SDP answer", 0);
        }
    }
    gst_promise_unref(promise);
}

static void remote_offer_set(GstPromise *promise, gpointer data) {
    OLNative *n = (OLNative *)data;
    if (promise_ok(promise, n)) {
        OLGstState *gst = ol_internal_get_gst(n);
        GstElement *rtc = ref_gst_element(gst, gst ? &gst->rtc : NULL);
        if (rtc) {
            GstPromise *next = gst_promise_new_with_change_func(answer_created, ol_internal_retain(n), release_destroy);
            g_signal_emit_by_name(rtc, "create-answer", NULL, next);
            gst_object_unref(rtc);
        }
    }
    gst_promise_unref(promise);
}

static void client_local_offer_set(GstPromise *promise, gpointer data) {
    LocalDesc *local = (LocalDesc *)data;
    OLNative *n = local->n;
    if (promise_ok(promise, n) && local->desc) {
        gchar *sdp = gst_sdp_message_as_text(local->desc->sdp);
        if (sdp) {
            ol_internal_emit_event(n, "local-offer", sdp, 0);
            g_free(sdp);
        }
    }
    gst_promise_unref(promise);
}

static void client_offer_created(GstPromise *promise, gpointer data) {
    OLNative *n = (OLNative *)data;
    if (promise_ok(promise, n)) {
        GstWebRTCSessionDescription *offer = NULL;
        const GstStructure *reply = gst_promise_get_reply(promise);
        if (reply) gst_structure_get(reply, "offer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &offer, NULL);
        if (offer) {
            OLGstState *gst = ol_internal_get_gst(n);
            GstElement *rtc = ref_gst_element(gst, gst ? &gst->rtc : NULL);
            if (rtc) {
                LocalDesc *local = g_new0(LocalDesc, 1);
                local->n = ol_internal_retain(n);
                local->desc = offer;
                GstPromise *next = gst_promise_new_with_change_func(client_local_offer_set, local, free_local_desc);
                g_signal_emit_by_name(rtc, "set-local-description", offer, next);
                gst_object_unref(rtc);
            } else {
                gst_webrtc_session_description_free(offer);
            }
        } else {
            ol_internal_emit_event(n, "error", "GStreamer did not generate an SDP offer", 0);
        }
    }
    gst_promise_unref(promise);
}

static void client_remote_answer_set(GstPromise *promise, gpointer data) {
    OLNative *n = (OLNative *)data;
    (void)promise_ok(promise, n);
    gst_promise_unref(promise);
}

void ol_gst_init_session(OLNative *n) {
    if (!n) return;
    ensure_gstreamer_initialized();

    OLGstState *gst = (OLGstState *)calloc(1, sizeof(OLGstState));
    if (!gst) return;
    InitializeCriticalSection(&gst->lock);
    ol_internal_set_gst(n, gst);

    GstElement *pipeline = gst_pipeline_new("overlook-rx");
    GstElement *rtc = gst_element_factory_make("webrtcbin", "rtc");
    if (!pipeline || !rtc) {
        if (pipeline) gst_object_unref(pipeline);
        if (rtc) gst_object_unref(rtc);
        ol_internal_emit_event(n, "error",
            "Missing GStreamer webrtcbin or libnice plugins. Reinstall the complete Overlook package.", 0);
        return;
    }

    gst_bin_add(GST_BIN(pipeline), rtc);
    gst_object_ref(rtc);
    g_object_set(rtc, "bundle-policy", GST_WEBRTC_BUNDLE_POLICY_MAX_BUNDLE, "latency", 0, NULL);

    g_signal_connect_data(rtc, "pad-added", G_CALLBACK(incoming_pad),
                          ol_internal_retain(n), release_closure, 0);
    g_signal_connect_data(rtc, "on-ice-candidate", G_CALLBACK(local_ice),
                          ol_internal_retain(n), release_closure, 0);
    g_signal_connect_data(rtc, "notify::ice-connection-state", G_CALLBACK(ice_state),
                          ol_internal_retain(n), release_closure, 0);

    GstBus *bus = gst_element_get_bus(pipeline);
    if (bus) {
        gst_bus_set_sync_handler(bus, bus_sync_handler, ol_internal_retain(n), release_destroy);
        gst_object_unref(bus);
    }

    EnterCriticalSection(&gst->lock);
    gst->pipeline = pipeline;
    gst->rtc = rtc;
    LeaveCriticalSection(&gst->lock);

    if (gst_element_set_state(pipeline, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        ol_internal_emit_event(n, "error", "Cannot start native WebRTC pipeline. Check GStreamer plugins.", 0);
    }
}

void ol_gst_close_session(OLNative *n) {
    if (!n) return;
    OLGstState *gst = ol_internal_get_gst(n);
    if (!gst) return;

    EnterCriticalSection(&gst->lock);
    GstElement *pipeline = gst->pipeline;
    GstElement *rtc = gst->rtc;
    GstElement *sender = gst->sender;
    GstElement *sender_rtc = gst->sender_rtc;
    gst->pipeline = NULL;
    gst->rtc = NULL;
    gst->sender = NULL;
    gst->sender_rtc = NULL;
    LeaveCriticalSection(&gst->lock);

    if (rtc) {
        g_signal_handlers_disconnect_by_data(rtc, n);
    }
    if (sender_rtc) {
        g_signal_handlers_disconnect_by_data(sender_rtc, n);
    }
    if (pipeline) {
        GstBus *bus = gst_element_get_bus(pipeline);
        if (bus) {
            gst_bus_set_sync_handler(bus, NULL, NULL, NULL);
            gst_object_unref(bus);
        }
        gst_element_set_state(pipeline, GST_STATE_NULL);
        gst_object_unref(pipeline);
    }
    if (sender) {
        GstBus *bus = gst_element_get_bus(sender);
        if (bus) {
            gst_bus_set_sync_handler(bus, NULL, NULL, NULL);
            gst_object_unref(bus);
        }
        gst_element_set_state(sender, GST_STATE_NULL);
        gst_object_unref(sender);
    }
    if (rtc) gst_object_unref(rtc);
    if (sender_rtc) gst_object_unref(sender_rtc);
}

void ol_gst_free_session(OLNative *n) {
    if (!n) return;
    ol_gst_close_session(n);
    OLGstState *gst = ol_internal_get_gst(n);
    if (gst) {
        ol_internal_set_gst(n, NULL);
        DeleteCriticalSection(&gst->lock);
        free(gst);
    }
}

void ol_native_offer(OLNative *n, const char *sdp_text) {
    if (!n || !sdp_text || !ol_internal_is_active(n)) return;
    OLGstState *gst = ol_internal_get_gst(n);
    GstElement *rtc = ref_gst_element(gst, gst ? &gst->rtc : NULL);
    if (!rtc) return;

    GstSDPMessage *sdp = NULL;
    gst_sdp_message_new(&sdp);
    if (!sdp || gst_sdp_message_parse_buffer((const guint8 *)sdp_text, (guint)strlen(sdp_text), sdp) != GST_SDP_OK) {
        if (sdp) gst_sdp_message_free(sdp);
        gst_object_unref(rtc);
        ol_internal_emit_event(n, "error", "Invalid remote SDP offer", 0);
        return;
    }

    GstWebRTCSessionDescription *offer = gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_OFFER, sdp);
    GstPromise *promise = gst_promise_new_with_change_func(remote_offer_set, ol_internal_retain(n), release_destroy);
    g_signal_emit_by_name(rtc, "set-remote-description", offer, promise);
    gst_webrtc_session_description_free(offer);
    gst_object_unref(rtc);
}

void ol_native_create_offer(OLNative *n, const char *stun_server) {
    if (!n || !ol_internal_is_active(n)) return;
    OLGstState *gst = ol_internal_get_gst(n);
    if (!gst) return;

    EnterCriticalSection(&gst->lock);
    GstElement *rtc = gst->rtc ? (GstElement *)gst_object_ref(gst->rtc) : NULL;
    gboolean should_add_transceiver = (rtc != NULL && !gst->recv_transceiver_added);
    if (should_add_transceiver) gst->recv_transceiver_added = TRUE;
    LeaveCriticalSection(&gst->lock);

    if (!rtc) return;
    if (stun_server && stun_server[0]) {
        g_object_set(rtc, "stun-server", stun_server, NULL);
    }
    if (should_add_transceiver) {
        GstCaps *caps = gst_caps_from_string("application/x-rtp,media=video,encoding-name=H264,clock-rate=90000,payload=96");
        GstWebRTCRTPTransceiver *trans = NULL;
        g_signal_emit_by_name(rtc, "add-transceiver", GST_WEBRTC_RTP_TRANSCEIVER_DIRECTION_RECVONLY, caps, &trans);
        if (trans) gst_object_unref(trans);
        if (caps) gst_caps_unref(caps);
    }
    GstPromise *promise = gst_promise_new_with_change_func(client_offer_created, ol_internal_retain(n), release_destroy);
    g_signal_emit_by_name(rtc, "create-offer", NULL, promise);
    gst_object_unref(rtc);
}

void ol_native_answer(OLNative *n, const char *sdp_text) {
    if (!n || !sdp_text || !ol_internal_is_active(n)) return;
    OLGstState *gst = ol_internal_get_gst(n);
    GstElement *rtc = ref_gst_element(gst, gst ? &gst->rtc : NULL);
    if (!rtc) return;

    GstSDPMessage *sdp = NULL;
    gst_sdp_message_new(&sdp);
    if (!sdp || gst_sdp_message_parse_buffer((const guint8 *)sdp_text, (guint)strlen(sdp_text), sdp) != GST_SDP_OK) {
        if (sdp) gst_sdp_message_free(sdp);
        gst_object_unref(rtc);
        ol_internal_emit_event(n, "error", "Invalid remote SDP answer", 0);
        return;
    }

    GstWebRTCSessionDescription *answer = gst_webrtc_session_description_new(GST_WEBRTC_SDP_TYPE_ANSWER, sdp);
    GstPromise *promise = gst_promise_new_with_change_func(client_remote_answer_set, ol_internal_retain(n), release_destroy);
    g_signal_emit_by_name(rtc, "set-remote-description", answer, promise);
    gst_webrtc_session_description_free(answer);
    gst_object_unref(rtc);
}

void ol_native_ice(OLNative *n, unsigned int line, const char *candidate) {
    if (!n || !ol_internal_is_active(n) || !candidate) return;
    if (strncmp(candidate, "a=", 2) == 0) candidate += 2;
    if (!candidate[0] || strcmp(candidate, "end-of-candidates") == 0) return;
    OLGstState *gst = ol_internal_get_gst(n);
    GstElement *rtc = ref_gst_element(gst, gst ? &gst->rtc : NULL);
    if (rtc) {
        g_signal_emit_by_name(rtc, "add-ice-candidate", line, candidate);
        gst_object_unref(rtc);
    }
}

// ============================================================================
// Local Encoded WebRTC Loopback Verification
// ============================================================================

static void sender_ice(GstElement *rtc, guint line, gchar *candidate, gpointer data) {
    (void)rtc;
    ol_native_ice((OLNative *)data, line, candidate);
}

static void test_offer_created(GstPromise *promise, gpointer data) {
    OLNative *n = (OLNative *)data;
    if (promise_ok(promise, n)) {
        GstWebRTCSessionDescription *offer = NULL;
        const GstStructure *reply = gst_promise_get_reply(promise);
        if (reply) gst_structure_get(reply, "offer", GST_TYPE_WEBRTC_SESSION_DESCRIPTION, &offer, NULL);
        if (offer) {
            OLGstState *gst = ol_internal_get_gst(n);
            GstElement *sender_rtc = ref_gst_element(gst, gst ? &gst->sender_rtc : NULL);
            if (sender_rtc) {
                g_signal_emit_by_name(sender_rtc, "set-local-description", offer, NULL);
                gst_object_unref(sender_rtc);
            }
            gchar *sdp = gst_sdp_message_as_text(offer->sdp);
            if (sdp) {
                ol_native_offer(n, sdp);
                g_free(sdp);
            }
            gst_webrtc_session_description_free(offer);
        }
    }
    gst_promise_unref(promise);
}

static void test_negotiate(GstElement *rtc, gpointer data) {
    OLNative *n = (OLNative *)data;
    GstPromise *p = gst_promise_new_with_change_func(test_offer_created, ol_internal_retain(n), release_destroy);
    g_signal_emit_by_name(rtc, "create-offer", NULL, p);
}

static const char *find_first_factory(const char *const *candidates, size_t count) {
    for (size_t i = 0; i < count; i++) {
        GstElementFactory *f = gst_element_factory_find(candidates[i]);
        if (f) {
            gst_object_unref(f);
            return candidates[i];
        }
    }
    return NULL;
}

void ol_native_test(OLNative *n, int h264) {
    if (!n || !ol_internal_is_active(n)) return;
    ensure_gstreamer_initialized();

    OLGstState *gst = ol_internal_get_gst(n);
    if (!gst) return;

    char pipeline_desc[512];
    if (h264) {
        static const char *const kH264Encs[] = { "openh264enc", "mfh264enc", "x264enc" };
        const char *enc = find_first_factory(kH264Encs, sizeof(kH264Encs) / sizeof(kH264Encs[0]));
        if (!enc) {
            ol_internal_emit_event(n, "error", "No H.264 encoder plugin available for local WebRTC test", 0);
            return;
        }
        const char *enc_args = (strcmp(enc, "x264enc") == 0) ? "x264enc tune=zerolatency speed-preset=ultrafast" : enc;
        snprintf(pipeline_desc, sizeof(pipeline_desc),
                 "videotestsrc is-live=true ! video/x-raw,width=320,height=240,framerate=15/1 ! "
                 "videoconvert ! %s ! h264parse ! rtph264pay config-interval=-1 ! "
                 "application/x-rtp,media=video,encoding-name=H264,payload=96 ! "
                 "webrtcbin name=sender bundle-policy=max-bundle",
                 enc_args);
    } else {
        snprintf(pipeline_desc, sizeof(pipeline_desc),
                 "videotestsrc is-live=true ! video/x-raw,width=320,height=240,framerate=15/1 ! "
                 "videoconvert ! vp8enc deadline=1 ! rtpvp8pay ! "
                 "application/x-rtp,media=video,encoding-name=VP8,payload=96 ! "
                 "webrtcbin name=sender bundle-policy=max-bundle");
    }

    GError *error = NULL;
    GstElement *sender = gst_parse_launch(pipeline_desc, &error);
    if (!sender) {
        ol_internal_emit_event(n, "error", error ? error->message : "Cannot start local WebRTC test sender", 0);
        g_clear_error(&error);
        return;
    }
    g_clear_error(&error);

    GstElement *sender_rtc = gst_bin_get_by_name(GST_BIN(sender), "sender");
    if (!sender_rtc) {
        gst_object_unref(sender);
        ol_internal_emit_event(n, "error", "Missing sender webrtcbin element", 0);
        return;
    }

    g_signal_connect_data(sender_rtc, "on-negotiation-needed", G_CALLBACK(test_negotiate),
                          ol_internal_retain(n), release_closure, 0);
    g_signal_connect_data(sender_rtc, "on-ice-candidate", G_CALLBACK(sender_ice),
                          ol_internal_retain(n), release_closure, 0);

    GstBus *bus = gst_element_get_bus(sender);
    if (bus) {
        gst_bus_set_sync_handler(bus, bus_sync_handler, ol_internal_retain(n), release_destroy);
        gst_object_unref(bus);
    }

    EnterCriticalSection(&gst->lock);
    GstElement *old_sender = gst->sender;
    GstElement *old_sender_rtc = gst->sender_rtc;
    gst->sender = sender;
    gst->sender_rtc = sender_rtc;
    LeaveCriticalSection(&gst->lock);

    if (old_sender_rtc) g_signal_handlers_disconnect_by_data(old_sender_rtc, n);
    if (old_sender) {
        GstBus *old_bus = gst_element_get_bus(old_sender);
        if (old_bus) {
            gst_bus_set_sync_handler(old_bus, NULL, NULL, NULL);
            gst_object_unref(old_bus);
        }
        gst_element_set_state(old_sender, GST_STATE_NULL);
        gst_object_unref(old_sender);
    }
    if (old_sender_rtc) gst_object_unref(old_sender_rtc);

    if (gst_element_set_state(sender, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        ol_internal_emit_event(n, "error", "Cannot start local WebRTC test sender pipeline", 0);
    }
}

// ============================================================================
// WebRTC Receiver Statistics
// ============================================================================

typedef struct {
    guint64 bytes_received;
    gint packets_lost;
    gint pli_count;
    gint nack_count;
    gint jitter_ms;
    gint rtt_ms;
    gboolean has_jitter;
    gboolean has_lost;
    gboolean has_pli;
    gboolean has_nack;
    gboolean has_rtt;
    char *codec;
    char *remote_addr;
    char *local_type;
    char *remote_type;
    char *proto;
    guint64 last_bytes_received;
    ULONGLONG last_stats_ms;
} StatsAccum;

static void json_append_escaped(GString *s, const char *str) {
    if (!str) return;
    for (const char *p = str; *p; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '"' || c == '\\') {
            g_string_append_c(s, '\\');
            g_string_append_c(s, (char)c);
        } else if (c >= 0x20) {
            g_string_append_c(s, (char)c);
        }
    }
}

static gboolean collect_stats_field(GQuark field_id, const GValue *value, gpointer user_data) {
    (void)field_id;
    if (!GST_VALUE_HOLDS_STRUCTURE(value)) return TRUE;
    const GstStructure *s = gst_value_get_structure(value);
    StatsAccum *acc = (StatsAccum *)user_data;
    const char *name = gst_structure_get_name(s);
    const char *type_str = gst_structure_get_string(s, "type");

    if ((type_str && g_strcmp0(type_str, "inbound-rtp") == 0) ||
        (name && g_str_has_prefix(name, "rtp-inbound-stream-stats"))) {
        guint64 bytes = 0;
        if (gst_structure_get_uint64(s, "bytes-received", &bytes) && bytes > 0) acc->bytes_received += bytes;
        gint lost = 0;
        if (gst_structure_get_int(s, "packets-lost", &lost)) { acc->packets_lost = lost; acc->has_lost = TRUE; }
        guint pli = 0, nack = 0;
        if (gst_structure_get_uint(s, "pli-count", &pli)) { acc->pli_count = (gint)pli; acc->has_pli = TRUE; }
        if (gst_structure_get_uint(s, "nack-count", &nack)) { acc->nack_count = (gint)nack; acc->has_nack = TRUE; }
        double jitter = 0;
        if (gst_structure_get_double(s, "jitter", &jitter)) { acc->jitter_ms = (gint)llround(jitter * 1000.0); acc->has_jitter = TRUE; }
    } else if ((type_str && g_strcmp0(type_str, "candidate-pair") == 0) ||
               (name && g_str_has_prefix(name, "ice-candidate-pair"))) {
        double rtt = 0;
        if (gst_structure_get_double(s, "current-round-trip-time", &rtt) && rtt >= 0) {
            acc->rtt_ms = (gint)llround(rtt * 1000.0);
            acc->has_rtt = TRUE;
        }
    } else if (type_str && g_strcmp0(type_str, "codec") == 0) {
        const char *mime = gst_structure_get_string(s, "mime-type");
        if (mime && g_str_has_prefix(mime, "video/") && !acc->codec) {
            acc->codec = g_strdup(mime + 6);
        }
    } else if (type_str && g_strcmp0(type_str, "remote-candidate") == 0) {
        const char *addr = gst_structure_get_string(s, "address");
        guint port = 0;
        gst_structure_get_uint(s, "port", &port);
        if (addr && !acc->remote_addr) {
            acc->remote_addr = port ? g_strdup_printf("%s:%u", addr, port) : g_strdup(addr);
        }
        const char *ct = gst_structure_get_string(s, "candidate-type");
        if (ct && !acc->remote_type) acc->remote_type = g_strdup(ct);
        const char *pr = gst_structure_get_string(s, "protocol");
        if (pr && !acc->proto) acc->proto = g_ascii_strup(pr, -1);
    } else if (type_str && g_strcmp0(type_str, "local-candidate") == 0) {
        const char *ct = gst_structure_get_string(s, "candidate-type");
        if (ct && !acc->local_type) acc->local_type = g_strdup(ct);
    }
    return TRUE;
}

static void stats_replied(GstPromise *promise, gpointer data) {
    OLNative *n = (OLNative *)data;
    if (gst_promise_wait(promise) == GST_PROMISE_RESULT_REPLIED && ol_internal_is_active(n)) {
        const GstStructure *reply = gst_promise_get_reply(promise);
        StatsAccum acc = {0};
        if (reply) gst_structure_foreach(reply, collect_stats_field, &acc);

        ULONGLONG now = GetTickCount64();
        gint kbps = -1;
        OLGstState *gst = ol_internal_get_gst(n);
        if (gst) {
            EnterCriticalSection(&gst->lock);
            if (gst->last_stats_ms > 0 && now > gst->last_stats_ms &&
                acc.bytes_received >= gst->last_bytes_received && acc.bytes_received > 0) {
                double dt = (double)(now - gst->last_stats_ms) / 1000.0;
                if (dt > 0.1) {
                    kbps = (gint)llround(((double)(acc.bytes_received - gst->last_bytes_received) * 8.0 / 1000.0) / dt);
                }
            }
            gst->last_bytes_received = acc.bytes_received;
            gst->last_stats_ms = now;
            LeaveCriticalSection(&gst->lock);
        }

        int fw = 0, fh = 0;
        int fps = ol_internal_take_rendered_frames(n, &fw, &fh);

        GString *json = g_string_new("{");
        g_string_append_printf(json, "\"width\":%d,\"height\":%d,\"fps\":%d", fw, fh, fps);
        if (kbps >= 0) g_string_append_printf(json, ",\"kbps\":%d", kbps);
        if (acc.has_jitter) g_string_append_printf(json, ",\"jitter_ms\":%d", acc.jitter_ms);
        if (acc.has_lost) g_string_append_printf(json, ",\"packets_lost\":%d", acc.packets_lost);
        if (acc.has_pli) g_string_append_printf(json, ",\"pli_count\":%d", acc.pli_count);
        if (acc.has_nack) g_string_append_printf(json, ",\"nack_count\":%d", acc.nack_count);
        if (acc.has_rtt) g_string_append_printf(json, ",\"rtt_ms\":%d", acc.rtt_ms);
        if (acc.codec) {
            g_string_append(json, ",\"codec\":\"");
            json_append_escaped(json, acc.codec);
            g_string_append_c(json, '"');
        }
        if (acc.local_type && acc.remote_type) {
            g_string_append(json, ",\"path\":\"");
            json_append_escaped(json, acc.local_type);
            g_string_append(json, " -> ");
            json_append_escaped(json, acc.remote_type);
            if (acc.proto) {
                g_string_append(json, " / ");
                json_append_escaped(json, acc.proto);
            }
            g_string_append_c(json, '"');
        }
        if (acc.remote_addr) {
            g_string_append(json, ",\"remote\":\"");
            json_append_escaped(json, acc.remote_addr);
            g_string_append_c(json, '"');
        }
        g_string_append_c(json, '}');
        ol_internal_emit_event(n, "stats", json->str, 0);
        g_string_free(json, TRUE);

        g_free(acc.codec);
        g_free(acc.remote_addr);
        g_free(acc.local_type);
        g_free(acc.remote_type);
        g_free(acc.proto);
    }
    gst_promise_unref(promise);
}

void ol_native_poll_stats(OLNative *n) {
    if (!n || !ol_internal_is_active(n) || !ol_internal_has_frame(n)) return;
    OLGstState *gst = ol_internal_get_gst(n);
    GstElement *rtc = ref_gst_element(gst, gst ? &gst->rtc : NULL);
    if (!rtc) return;

    GstPromise *promise = gst_promise_new_with_change_func(stats_replied, ol_internal_retain(n), release_destroy);
    g_signal_emit_by_name(rtc, "get-stats", NULL, promise);
    gst_object_unref(rtc);
}

// ============================================================================
// Native GStreamer MP4 Recording & Encoder Probe
// ============================================================================

int ol_gst_probe_encoders(int *h264_out, int *hevc_out) {
    ensure_gstreamer_initialized();
    static const char *const kH264[] = { "mfh264enc", "nvh264enc", "amfh264enc", "qsvh264enc", "openh264enc", "x264enc" };
    static const char *const kHEVC[] = { "mfh265enc", "nvh265enc", "amfh265enc", "qsvh265enc", "x265enc" };
    int h264 = find_first_factory(kH264, sizeof(kH264) / sizeof(kH264[0])) != NULL;
    int hevc = find_first_factory(kHEVC, sizeof(kHEVC) / sizeof(kHEVC[0])) != NULL;
    if (h264_out) *h264_out = h264;
    if (hevc_out) *hevc_out = hevc;
    return h264 || hevc;
}

static void recorder_push_bytes(OLRecorder *rec, const uint8_t *bgra, int width, int height, int stride) {
    if (!rec || !bgra || width != rec->width || height != rec->height || stride <= 0) return;
    EnterCriticalSection(&rec->lock);
    if (rec->gst_src) {
        size_t sz = (size_t)stride * (size_t)height;
        GstBuffer *buf = gst_buffer_new_memdup(bgra, (gsize)sz);
        if (buf) {
            LARGE_INTEGER now_qpc;
            QueryPerformanceCounter(&now_qpc);
            GstClockTime pts = 0;
            if (rec->qpc_freq.QuadPart > 0 && now_qpc.QuadPart > rec->start_qpc.QuadPart) {
                guint64 delta = (guint64)(now_qpc.QuadPart - rec->start_qpc.QuadPart);
                guint64 freq = (guint64)rec->qpc_freq.QuadPart;
                pts = (delta / freq) * GST_SECOND + ((delta % freq) * GST_SECOND) / freq;
            }
            if (rec->has_last_pts) {
                GstClockTime min_pts = rec->last_pts + (5 * GST_MSECOND);
                if (pts < min_pts) pts = min_pts;
            }
            rec->last_pts = pts;
            rec->has_last_pts = 1;
            rec->last_push_ms = GetTickCount64();
            GST_BUFFER_PTS(buf) = pts;
            GST_BUFFER_DTS(buf) = GST_CLOCK_TIME_NONE;
            GST_BUFFER_DURATION(buf) = GST_SECOND / 30;
            if (gst_app_src_push_buffer(GST_APP_SRC(rec->gst_src), buf) == GST_FLOW_OK) {
                rec->frames++;
            }
        }
    }
    LeaveCriticalSection(&rec->lock);
}

void ol_gst_recorder_push_frame(OLNative *n, const uint8_t *bgra, int width, int height, int stride) {
    if (!n) return;
    OLRecorder *rec = ol_internal_get_recorder(n);
    if (rec) {
        recorder_push_bytes(rec, bgra, width, height, stride);
    }
}

static int recorder_keepalive_tick(void *ctx) {
    OLRecorder *rec = (OLRecorder *)ctx;
    if (!rec || !rec->owner || ol_internal_get_recorder(rec->owner) != rec) return 0;
    if (GetTickCount64() - rec->last_push_ms >= 33) {
        uint8_t *bytes = NULL;
        int w = 0, h = 0, stride = 0;
        if (ol_internal_copy_last_frame(rec->owner, &bytes, &w, &h, &stride)) {
            recorder_push_bytes(rec, bytes, w, h, stride);
            free(bytes);
        }
    }
    return 1;
}

typedef struct {
    const char *element;
    const char *parse;
    const char *format;
    const char *label;
} RecBackend;

static int try_start_recorder_pipeline(OLRecorder *rec, const char *path, const RecBackend *b) {
    GstElementFactory *factory = gst_element_factory_find(b->element);
    if (!factory) return 0;
    gst_object_unref(factory);

    const char *enc_str = (strcmp(b->element, "x264enc") == 0)
        ? "x264enc tune=zerolatency speed-preset=ultrafast"
        : b->element;
    char *desc = g_strdup_printf(
        "appsrc name=recsrc is-live=false format=time do-timestamp=false "
        "max-bytes=0 max-buffers=16 leaky-type=downstream "
        "caps=\"video/x-raw,format=BGRA,width=%d,height=%d,framerate=30/1\" ! "
        "videoconvert ! video/x-raw,format=%s ! %s ! %s ! mp4mux faststart=true ! filesink name=recsink",
        rec->width, rec->height, b->format, enc_str, b->parse);
    if (!desc) return 0;

    GError *err = NULL;
    GstElement *pipe = gst_parse_launch(desc, &err);
    g_free(desc);
    g_clear_error(&err);
    if (!pipe) return 0;

    GstElement *sink = gst_bin_get_by_name(GST_BIN(pipe), "recsink");
    GstElement *src = gst_bin_get_by_name(GST_BIN(pipe), "recsrc");
    if (!sink || !src) {
        if (sink) gst_object_unref(sink);
        if (src) gst_object_unref(src);
        gst_object_unref(pipe);
        return 0;
    }

    g_object_set(sink, "location", path, NULL);
    gst_object_unref(sink);

    if (gst_element_set_state(pipe, GST_STATE_PLAYING) == GST_STATE_CHANGE_FAILURE) {
        gst_object_unref(src);
        gst_element_set_state(pipe, GST_STATE_NULL);
        gst_object_unref(pipe);
        return 0;
    }

    rec->gst_pipe = pipe;
    rec->gst_src = src;
    rec->backend = _strdup(b->label);
    return 1;
}

int ol_native_record_start(OLNative *n, const char *path, int hevc, const char *vaapi_device,
                           char **backend_out, char **error_out) {
    (void)vaapi_device;
    ensure_gstreamer_initialized();
    if (!n || !ol_internal_is_active(n)) {
        if (error_out) *error_out = _strdup("No active session.");
        return 0;
    }
    if (ol_internal_get_recorder(n) != NULL) {
        if (error_out) *error_out = _strdup("A recording is already in progress.");
        return 0;
    }
    if (!path || !path[0]) {
        if (error_out) *error_out = _strdup("Invalid recording output path.");
        return 0;
    }

    uint8_t *first_bytes = NULL;
    int fw = 0, fh = 0, fstride = 0;
    if (!ol_internal_copy_last_frame(n, &first_bytes, &fw, &fh, &fstride)) {
        if (error_out) *error_out = _strdup("Wait for a video frame before starting a recording.");
        return 0;
    }

    ol_internal_ensure_parent_dir(path);

    OLRecorder *rec = (OLRecorder *)calloc(1, sizeof(OLRecorder));
    if (!rec) {
        free(first_bytes);
        if (error_out) *error_out = _strdup("Out of memory starting recording.");
        return 0;
    }
    InitializeCriticalSection(&rec->lock);
    rec->owner = n;
    rec->path = _strdup(path);
    rec->width = fw;
    rec->height = fh;
    rec->stride = fstride;

    static const RecBackend kHevcCandidates[] = {
        { "mfh265enc", "h265parse", "NV12", "Media Foundation HEVC" },
        { "nvh265enc", "h265parse", "NV12", "NVENC HEVC" },
        { "x265enc",   "h265parse", "I420", "Software HEVC (x265)" }
    };
    static const RecBackend kH264Candidates[] = {
        { "mfh264enc",   "h264parse", "NV12", "Media Foundation H.264" },
        { "nvh264enc",   "h264parse", "NV12", "NVENC H.264" },
        { "openh264enc", "h264parse", "I420", "OpenH264 (Software)" },
        { "x264enc",     "h264parse", "I420", "Software H.264 (x264)" }
    };

    int started = 0;
    if (hevc) {
        for (size_t i = 0; i < sizeof(kHevcCandidates) / sizeof(kHevcCandidates[0]) && !started; i++) {
            started = try_start_recorder_pipeline(rec, path, &kHevcCandidates[i]);
        }
    }
    for (size_t i = 0; i < sizeof(kH264Candidates) / sizeof(kH264Candidates[0]) && !started; i++) {
        started = try_start_recorder_pipeline(rec, path, &kH264Candidates[i]);
    }

    if (!started) {
        free(first_bytes);
        DeleteCriticalSection(&rec->lock);
        free(rec->path);
        free(rec->backend);
        free(rec);
        if (error_out) *error_out = _strdup("No GStreamer H.264/HEVC encoder plugin is available for recording.");
        return 0;
    }

    QueryPerformanceFrequency(&rec->qpc_freq);
    QueryPerformanceCounter(&rec->start_qpc);
    rec->start_ms = GetTickCount64();

    recorder_push_bytes(rec, first_bytes, fw, fh, fstride);
    free(first_bytes);
    ol_internal_set_recorder(n, rec);

    rec->timer_id = ol_win_timer_add(33, recorder_keepalive_tick, rec);
    if (backend_out) *backend_out = _strdup(rec->backend ? rec->backend : "Media Foundation");
    return 1;
}

int ol_native_record_stop(OLNative *n, double *duration_out, int *frames_out, char **error_out) {
    if (!n) {
        if (error_out) *error_out = _strdup("No active session.");
        return 0;
    }
    OLRecorder *rec = ol_internal_get_recorder(n);
    if (!rec) {
        if (error_out) *error_out = _strdup("No recording is in progress.");
        return 0;
    }
    ol_internal_set_recorder(n, NULL);
    if (rec->timer_id) {
        ol_win_timer_remove(rec->timer_id);
        rec->timer_id = 0;
    }

    if (rec->frames < 2) {
        uint8_t *bytes = NULL;
        int w = 0, h = 0, stride = 0;
        if (ol_internal_copy_last_frame(n, &bytes, &w, &h, &stride)) {
            recorder_push_bytes(rec, bytes, w, h, stride);
            free(bytes);
        }
    }

    int status_ok = 1;
    EnterCriticalSection(&rec->lock);
    GstElement *pipe = rec->gst_pipe;
    GstElement *src = rec->gst_src;
    rec->gst_pipe = NULL;
    rec->gst_src = NULL;
    LeaveCriticalSection(&rec->lock);

    if (pipe && src) {
        gst_app_src_end_of_stream(GST_APP_SRC(src));
        GstBus *bus = gst_element_get_bus(pipe);
        if (bus) {
            GstMessage *msg = gst_bus_timed_pop_filtered(bus, 5 * GST_SECOND, GST_MESSAGE_EOS | GST_MESSAGE_ERROR);
            if (msg) {
                if (GST_MESSAGE_TYPE(msg) == GST_MESSAGE_ERROR) {
                    status_ok = 0;
                    GError *err = NULL;
                    gchar *dbg = NULL;
                    gst_message_parse_error(msg, &err, &dbg);
                    if (error_out) {
                        *error_out = _strdup((err && err->message) ? err->message : "GStreamer recording failed.");
                    }
                    g_clear_error(&err);
                    g_free(dbg);
                }
                gst_message_unref(msg);
            }
            gst_object_unref(bus);
        }
        gst_element_set_state(pipe, GST_STATE_NULL);
    }
    if (src) gst_object_unref(src);
    if (pipe) gst_object_unref(pipe);

    if (status_ok && !ol_internal_file_nonempty(rec->path)) {
        status_ok = 0;
        if (error_out) *error_out = _strdup("Recording output file was not created or is empty.");
    }

    double dur = (double)(GetTickCount64() - rec->start_ms) / 1000.0;
    if (dur < 0.05) dur = 0.05;
    if (duration_out) *duration_out = dur;
    if (frames_out) *frames_out = rec->frames;

    DeleteCriticalSection(&rec->lock);
    free(rec->path);
    free(rec->backend);
    free(rec);
    return status_ok;
}

void ol_gst_recorder_abort(OLNative *n) {
    if (!n || !ol_internal_get_recorder(n)) return;
    double dur = 0;
    int frames = 0;
    char *err = NULL;
    ol_native_record_stop(n, &dur, &frames, &err);
    free(err);
}

int ol_native_is_recording(OLNative *n) {
    return (n && ol_internal_get_recorder(n) != NULL) ? 1 : 0;
}
