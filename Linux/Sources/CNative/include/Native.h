#pragma once
// Call public APIs on the GTK main thread. Events are delivered there too.
// Strings are borrowed for the duration of a call; widget is owned by the session.
typedef struct OLNative OLNative;
typedef void (*OLNativeEvent)(const char *event, const char *text, int number, void *context);
// Input callbacks run synchronously on the GTK thread. Key codes are GDK hardware
// keycodes, button codes are GDK button numbers, coordinates are widget pixels.
typedef void (*OLNativeInput)(int kind, int code, double x, double y, void *context);
enum {
    OL_INPUT_KEY_DOWN, OL_INPUT_KEY_UP, OL_INPUT_BUTTON_DOWN, OL_INPUT_BUTTON_UP,
    OL_INPUT_MOTION, OL_INPUT_SCROLL, OL_INPUT_FOCUS_IN, OL_INPUT_FOCUS_OUT
};
OLNative *ol_native_new(OLNativeEvent callback, void *context);
void *ol_native_picture(OLNative *native);
// Accept a certificate the system does not trust for "host:port" if its DER
// SHA-256 (lowercase hex) matches. A rejected certificate produces a
// "certificate" event with text "host:port\nsha256\nreason".
void ol_native_allow(OLNative *, const char *key, const char *sha256);
void ol_native_http(OLNative *, const char *method, const char *url, const char *body);
void ol_native_cookie(OLNative *, const char *url, const char *token);
void ol_native_socket(OLNative *, const char *url, const char *origin);
void ol_native_send(OLNative *, const char *json);
void ol_native_offer(OLNative *, const char *sdp);
void ol_native_ice(OLNative *, unsigned int line, const char *candidate);
void ol_native_hid_socket(OLNative *, const char *url, const char *origin);
void ol_native_hid_send(OLNative *, const unsigned char *bytes, int length);
void ol_native_hid_text(OLNative *, const char *text);
int ol_native_hid_ready(OLNative *);
void ol_native_input(OLNative *, OLNativeInput callback, void *context);
void ol_native_geometry(OLNative *, double *width, double *height, double *video_width, double *video_height);
void ol_native_focus(OLNative *, int focused);
void ol_native_cursor(OLNative *, const char *name);
void ol_native_test(OLNative *, int h264);
void ol_native_close(OLNative *);

typedef void (*OLNativeHTTPResponse)(int status, const unsigned char *data, int length, const char *error, void *context);
void ol_native_request(OLNative *native, const char *method, const char *url,
                       const char *content_type, const unsigned char *body, int body_length,
                       OLNativeHTTPResponse callback, void *context);
void ol_native_poll_stats(OLNative *native);
int ol_native_screenshot(OLNative *native, const char *path, char **error_out);
char *ol_vaapi_probe(const char *preferred_device);
int ol_native_record_start(OLNative *native, const char *path, int hevc, const char *vaapi_device,
                           char **backend_out, char **error_out);
int ol_native_record_stop(OLNative *native, double *duration_out, int *frames_out, char **error_out);
int ol_native_is_recording(OLNative *native);
