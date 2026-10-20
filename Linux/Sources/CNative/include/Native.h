#pragma once
// Call public APIs on the GTK main thread. Events are delivered there too.
// Strings are borrowed for the duration of a call; widget is owned by the session.
typedef struct OLNative OLNative;
typedef void (*OLNativeEvent)(const char *event, const char *text, int number, void *context);
OLNative *ol_native_new(OLNativeEvent callback, void *context);
void *ol_native_picture(OLNative *native);
void ol_native_http(OLNative *, const char *method, const char *url, const char *body);
void ol_native_cookie(OLNative *, const char *url, const char *token);
void ol_native_socket(OLNative *, const char *url, const char *origin);
void ol_native_send(OLNative *, const char *json);
void ol_native_offer(OLNative *, const char *sdp);
void ol_native_ice(OLNative *, unsigned int line, const char *candidate);
void ol_native_test(OLNative *, int h264);
void ol_native_close(OLNative *);
