#pragma once
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Call public APIs on the WinUI main thread. Events and frames are delivered there too.
typedef struct OLNative OLNative;
typedef void (*OLNativeEvent)(const char *event, const char *text, int number, void *context);

// Input callbacks run synchronously on the UI thread.
// Key codes are Windows Set 1 hardware scancodes (with 0x100 set for extended 0xE0 keys),
// button codes are Windows mouse button numbers (1=left, 2=middle, 3=right, 4=XButton1, 5=XButton2),
// coordinates are widget pixels.
typedef void (*OLNativeInput)(int kind, int code, double x, double y, void *context);

// Frame callback delivers decoded BGRA8 pixels on the UI thread for WinUI 3 WriteableBitmap.
typedef void (*OLNativeFrame)(const uint8_t *bgra, int width, int height, int stride, void *context);

enum {
    OL_INPUT_KEY_DOWN,
    OL_INPUT_KEY_UP,
    OL_INPUT_BUTTON_DOWN,
    OL_INPUT_BUTTON_UP,
    OL_INPUT_MOTION,
    OL_INPUT_SCROLL,
    OL_INPUT_FOCUS_IN,
    OL_INPUT_FOCUS_OUT
};

OLNative *ol_native_new(OLNativeEvent callback, void *context);
void *ol_native_picture(OLNative *native);
void ol_native_set_frame_callback(OLNative *native, OLNativeFrame callback, void *context);
void ol_native_set_widget_size(OLNative *native, double width, double height);

// Accept a certificate the system does not trust for "host:port" if its DER
// SHA-256 (lowercase hex) matches. A rejected certificate produces a
// "certificate" event with text "host:port\nsha256\nreason".
void ol_native_allow(OLNative *native, const char *key, const char *sha256);
void ol_native_http(OLNative *native, const char *method, const char *url, const char *body);
void ol_native_cookie(OLNative *native, const char *url, const char *token);
void ol_native_socket(OLNative *native, const char *url, const char *origin);
void ol_native_send(OLNative *native, const char *json);
void ol_native_offer(OLNative *native, const char *sdp);
void ol_native_create_offer(OLNative *native, const char *stun_server);
void ol_native_answer(OLNative *native, const char *sdp);
void ol_native_ice(OLNative *native, unsigned int line, const char *candidate);
void ol_native_hid_socket(OLNative *native, const char *url, const char *origin);
void ol_native_hid_send(OLNative *native, const unsigned char *bytes, int length);
void ol_native_hid_text(OLNative *native, const char *text);
int ol_native_hid_ready(OLNative *native);
void ol_native_input(OLNative *native, OLNativeInput callback, void *context);
void ol_native_emit_input(OLNative *native, int kind, int code, double x, double y);
void ol_native_geometry(OLNative *native, double *width, double *height, double *video_width, double *video_height);
void ol_native_focus(OLNative *native, int focused);
void ol_native_cursor(OLNative *native, const char *name);
void ol_native_test(OLNative *native, int h264);
void ol_native_close(OLNative *native);

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
void ol_native_free_string(char *str);

// Windows Credential Manager C helpers (Advapi32 CredWriteW / CredReadW / CredDeleteW)
char *ol_wincred_lookup(const char *address, char **message);
int ol_wincred_store(const char *address, const char *value, char **message);
int ol_wincred_clear(const char *address, char **message);
void ol_wincred_free(char *value);

// Windows Clipboard & UI Timer helpers
char *ol_win_clipboard_get(void);
void ol_win_clipboard_set(const char *text);
typedef int (*OLWinTimerCallback)(void *context);
uint32_t ol_win_timer_add(uint32_t interval_ms, OLWinTimerCallback callback, void *context);
void ol_win_timer_remove(uint32_t timer_id);
int ol_win_run_message_loop(void);
void ol_win_quit_message_loop(int exit_code);

// Native Windows 11 DWM Mica / WinUI 3 Fluent Desktop Window & Video Viewport
typedef void (*OLWinUICommandCallback)(const char *command, int index, void *context);
void ol_win_gui_init(OLWinUICommandCallback callback, void *context);
void ol_win_gui_set_title(const char *title, const char *subtitle);
void ol_win_gui_set_size(int width, int height);
void ol_win_gui_set_fullscreen(int fullscreen);
int ol_win_gui_is_fullscreen(void);
void ol_win_gui_present(void);
void ol_win_gui_close(void);
void ol_win_gui_toast(const char *message);
void ol_win_gui_set_mode(int is_session, OLNative *native);
void ol_win_gui_set_form(const char *address, const char *name, const char *username,
                         const char *password, const char *otp, int save_password);
void ol_win_gui_get_form(char *address, int addr_len, char *name, int name_len,
                         char *username, int user_len, char *password, int pass_len,
                         char *otp, int otp_len, int *save_password);
void ol_win_gui_clear_devices(void);
void ol_win_gui_add_device(const char *name, const char *host);
int ol_win_gui_cert_prompt(const char *heading, const char *body, const char *fingerprint);
void ol_win_gui_show_dialog(const char *title, const char *content);
void ol_win_gui_open_web(const char *url);

#ifdef __cplusplus
}
#endif
