#pragma once
#include "Native.h"
#include <stdint.h>

typedef struct OLGstState OLGstState;
typedef struct OLRecorder OLRecorder;

// Internal thread-safe bridge functions implemented in NativeWin.c
OLNative *ol_internal_retain(OLNative *n);
void ol_internal_release(OLNative *n);
int ol_internal_is_active(OLNative *n);
int ol_internal_try_begin_frame(OLNative *n);
void ol_internal_cancel_frame(OLNative *n);
void ol_internal_deliver_frame_locked(OLNative *n, uint8_t *owned_bgra, int width, int height, int stride);
void ol_internal_emit_event(OLNative *n, const char *event, const char *text, int number);
int ol_internal_copy_last_frame(OLNative *n, uint8_t **bytes_out, int *width_out, int *height_out, int *stride_out);
int ol_internal_take_rendered_frames(OLNative *n, int *width_out, int *height_out);
int ol_internal_has_frame(OLNative *n);

OLGstState *ol_internal_get_gst(OLNative *n);
void ol_internal_set_gst(OLNative *n, OLGstState *gst);
OLRecorder *ol_internal_get_recorder(OLNative *n);
void ol_internal_set_recorder(OLNative *n, OLRecorder *rec);

void ol_internal_ensure_parent_dir(const char *path);
int ol_internal_file_nonempty(const char *utf8_path);

// Lifecycle and capture hooks implemented in GStreamerWebRTC.c
void ol_gst_init_session(OLNative *n);
void ol_gst_close_session(OLNative *n);
void ol_gst_free_session(OLNative *n);
void ol_gst_recorder_push_frame(OLNative *n, const uint8_t *bgra, int width, int height, int stride);
void ol_gst_recorder_abort(OLNative *n);
int ol_gst_probe_encoders(int *h264_out, int *hevc_out);
