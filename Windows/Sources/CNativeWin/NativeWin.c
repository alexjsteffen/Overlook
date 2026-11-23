#include "NativeInternal.h"

#ifdef _WIN32
#ifndef _CRT_SECURE_NO_WARNINGS
#define _CRT_SECURE_NO_WARNINGS
#endif
#ifndef COBJMACROS
#define COBJMACROS
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>
#include <windowsx.h>
#include <objbase.h>
#include <winhttp.h>
#include <wincrypt.h>
#include <bcrypt.h>
#include <wincred.h>
#include <dxgi.h>
#include <dwmapi.h>
#include <commctrl.h>
#include <shellapi.h>
#include <ctype.h>
#include <math.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WM_OL_EVENT     (WM_APP + 0x101)
#define WM_OL_FRAME     (WM_APP + 0x102)
#define WM_OL_HTTP_RESP (WM_APP + 0x103)

#define OL_MAX_HTTP_RESPONSE_BYTES (64u * 1024u * 1024u)

typedef struct AllowedPin {
    char *key;
    char *sha256;
    struct AllowedPin *next;
} AllowedPin;

struct OLNative {
    volatile LONG refs;
    volatile LONG active;
    volatile LONG frame_pending;
    OLNativeEvent callback;
    void *context;
    OLNativeFrame frame_cb;
    void *frame_context;
    OLNativeInput input;
    void *input_context;

    CRITICAL_SECTION lock;
    AllowedPin *allowed;
    char *cookie_token;

    HINTERNET ws_session;
    HINTERNET ws_connect;
    HINTERNET ws_handle;
    volatile LONG ws_open;

    HINTERNET hid_session;
    HINTERNET hid_connect;
    HINTERNET hid_handle;
    volatile LONG hid_open;

    double widget_width;
    double widget_height;
    uint8_t *last_frame_bytes;
    int last_frame_width;
    int last_frame_height;
    int last_frame_stride;
    int got_frame;
    int focused;
    int inhibited;
    int rendered_frames_window;

    OLGstState *gst;
    OLRecorder *recorder;
};

// ============================================================================
// Allocation, UTF-8 / UTF-16 & Console Helpers
// ============================================================================

static char *alloc_printf(const char *fmt, ...) {
    va_list ap, ap2;
    va_start(ap, fmt);
    va_copy(ap2, ap);
    int len = vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (len < 0) {
        va_end(ap2);
        return NULL;
    }
    char *buf = (char *)malloc((size_t)len + 1);
    if (buf) {
        vsnprintf(buf, (size_t)len + 1, fmt, ap2);
    }
    va_end(ap2);
    return buf;
}

static wchar_t *utf8_to_wide(const char *s) {
    if (!s) return _wcsdup(L"");
    int len = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (len <= 0) return _wcsdup(L"");
    wchar_t *w = (wchar_t *)calloc((size_t)len, sizeof(wchar_t));
    if (!w) return _wcsdup(L"");
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, len);
    return w;
}

static char *wide_to_utf8(const wchar_t *w) {
    if (!w) return _strdup("");
    int len = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (len <= 0) return _strdup("");
    char *s = (char *)calloc((size_t)len, 1);
    if (!s) return _strdup("");
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s, len, NULL, NULL);
    return s;
}

void ol_win_attach_console_if_needed(void) {
    HANDLE hOut = GetStdHandle(STD_OUTPUT_HANDLE);
    DWORD type = (hOut && hOut != INVALID_HANDLE_VALUE) ? GetFileType(hOut) : FILE_TYPE_UNKNOWN;
    if (type == FILE_TYPE_UNKNOWN) {
        if (AttachConsole(ATTACH_PARENT_PROCESS)) {
            FILE *fp = NULL;
            freopen_s(&fp, "CONOUT$", "w", stdout);
            freopen_s(&fp, "CONOUT$", "w", stderr);
            setvbuf(stdout, NULL, _IONBF, 0);
            setvbuf(stderr, NULL, _IONBF, 0);
        }
    }
}

// ============================================================================
// UI Thread Message Pump, Timer Dispatch & Internal Bridge
// ============================================================================

static HWND g_msg_hwnd = NULL;
static HHOOK g_kb_hook = NULL;
static OLNative *g_captured_native = NULL;

typedef struct TimerSlot {
    uint32_t id;
    OLWinTimerCallback cb;
    void *ctx;
    struct TimerSlot *next;
} TimerSlot;

static TimerSlot *g_timers = NULL;
static uint32_t g_next_timer_id = 1000;

typedef struct QueuedEvent {
    OLNative *n;
    char *event;
    char *text;
    int number;
} QueuedEvent;

typedef struct QueuedFrame {
    OLNative *n;
    uint8_t *pixels;
    int width;
    int height;
    int stride;
} QueuedFrame;

typedef struct QueuedHTTP {
    OLNative *n;
    OLNativeHTTPResponse cb;
    void *ctx;
    int status;
    uint8_t *data;
    int length;
    char *error;
} QueuedHTTP;

static OLNative *retain_native(OLNative *n) {
    if (n) InterlockedIncrement(&n->refs);
    return n;
}

static void release_native(OLNative *n) {
    if (!n) return;
    if (InterlockedDecrement(&n->refs) == 0) {
        ol_gst_recorder_abort(n);
        ol_gst_free_session(n);
        EnterCriticalSection(&n->lock);
        AllowedPin *p = n->allowed;
        while (p) {
            AllowedPin *next = p->next;
            free(p->key);
            free(p->sha256);
            free(p);
            p = next;
        }
        if (n->cookie_token) {
            SecureZeroMemory(n->cookie_token, strlen(n->cookie_token));
            free(n->cookie_token);
            n->cookie_token = NULL;
        }
        free(n->last_frame_bytes);
        n->last_frame_bytes = NULL;
        LeaveCriticalSection(&n->lock);
        DeleteCriticalSection(&n->lock);
        free(n);
    }
}

static void emit_event(OLNative *n, const char *event, const char *text, int number) {
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0) || !g_msg_hwnd) return;
    QueuedEvent *e = (QueuedEvent *)calloc(1, sizeof(QueuedEvent));
    if (!e) return;
    e->n = retain_native(n);
    e->event = _strdup(event ? event : "");
    e->text = _strdup(text ? text : "");
    e->number = number;
    if (!e->event || !e->text || !PostMessageW(g_msg_hwnd, WM_OL_EVENT, 0, (LPARAM)e)) {
        release_native(e->n);
        free(e->event);
        free(e->text);
        free(e);
    }
}

static LRESULT CALLBACK msg_wnd_proc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    if (msg == WM_OL_EVENT) {
        QueuedEvent *e = (QueuedEvent *)lParam;
        if (e) {
            if (InterlockedCompareExchange(&e->n->active, 0, 0) && e->n->callback) {
                e->n->callback(e->event, e->text, e->number, e->n->context);
            }
            release_native(e->n);
            free(e->event);
            free(e->text);
            free(e);
        }
        return 0;
    } else if (msg == WM_OL_FRAME) {
        QueuedFrame *f = (QueuedFrame *)lParam;
        if (f) {
            OLNative *n = f->n;
            if (InterlockedCompareExchange(&n->active, 0, 0)) {
                EnterCriticalSection(&n->lock);
                free(n->last_frame_bytes);
                n->last_frame_bytes = f->pixels;
                f->pixels = NULL;
                n->last_frame_width = f->width;
                n->last_frame_height = f->height;
                n->last_frame_stride = f->stride;
                n->rendered_frames_window++;
                int first_frame = !n->got_frame;
                if (first_frame) n->got_frame = 1;
                const uint8_t *frame_ptr = n->last_frame_bytes;
                LeaveCriticalSection(&n->lock);

                if (frame_ptr) {
                    ol_gst_recorder_push_frame(n, frame_ptr, f->width, f->height, f->stride);
                    if (n->frame_cb) {
                        n->frame_cb(frame_ptr, f->width, f->height, f->stride, n->frame_context);
                    }
                }
                if (first_frame && n->callback) {
                    n->callback("frame", "Native WebRTC video connected", 0, n->context);
                }
            }
            InterlockedExchange(&n->frame_pending, 0);
            free(f->pixels);
            release_native(n);
            free(f);
        }
        return 0;
    } else if (msg == WM_OL_HTTP_RESP) {
        QueuedHTTP *r = (QueuedHTTP *)lParam;
        if (r) {
            if (r->cb) {
                if (InterlockedCompareExchange(&r->n->active, 0, 0)) {
                    r->cb(r->status, r->data, r->length, r->error, r->ctx);
                } else {
                    r->cb(0, NULL, 0, "Session closed.", r->ctx);
                }
            }
            release_native(r->n);
            free(r->data);
            free(r->error);
            free(r);
        }
        return 0;
    } else if (msg == WM_TIMER) {
        uint32_t tid = (uint32_t)wParam;
        TimerSlot *curr = g_timers;
        while (curr) {
            if (curr->id == tid) {
                OLWinTimerCallback cb = curr->cb;
                void *ctx = curr->ctx;
                int keep = cb ? cb(ctx) : 0;
                if (!keep) {
                    ol_win_timer_remove(tid);
                }
                break;
            }
            curr = curr->next;
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

static void ensure_msg_hwnd(void) {
    if (g_msg_hwnd) return;
    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = msg_wnd_proc;
    wc.hInstance = GetModuleHandleW(NULL);
    wc.lpszClassName = L"OverlookNativeMsgWnd";
    RegisterClassExW(&wc);
    g_msg_hwnd = CreateWindowExW(0, wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, NULL, wc.hInstance, NULL);
}

static void ensure_parent_dir(const char *filepath) {
    if (!filepath) return;
    wchar_t *wpath = utf8_to_wide(filepath);
    for (wchar_t *p = wpath; *p; p++) {
        if (*p == L'/' || *p == L'\\') {
            wchar_t saved = *p;
            *p = L'\0';
            if (wcslen(wpath) > 2) CreateDirectoryW(wpath, NULL);
            *p = saved;
        }
    }
    free(wpath);
}

OLNative *ol_internal_retain(OLNative *n) {
    return retain_native(n);
}

void ol_internal_release(OLNative *n) {
    release_native(n);
}

int ol_internal_is_active(OLNative *n) {
    return (n && InterlockedCompareExchange(&n->active, 0, 0) != 0) ? 1 : 0;
}

int ol_internal_try_begin_frame(OLNative *n) {
    return (n && InterlockedCompareExchange(&n->frame_pending, 1, 0) == 0) ? 1 : 0;
}

void ol_internal_cancel_frame(OLNative *n) {
    if (n) InterlockedExchange(&n->frame_pending, 0);
}

void ol_internal_deliver_frame_locked(OLNative *n, uint8_t *owned_bgra, int width, int height, int stride) {
    if (!n || !owned_bgra || !InterlockedCompareExchange(&n->active, 0, 0) || !g_msg_hwnd) {
        free(owned_bgra);
        if (n) InterlockedExchange(&n->frame_pending, 0);
        return;
    }
    QueuedFrame *f = (QueuedFrame *)calloc(1, sizeof(QueuedFrame));
    if (!f) {
        free(owned_bgra);
        InterlockedExchange(&n->frame_pending, 0);
        return;
    }
    f->n = retain_native(n);
    f->pixels = owned_bgra;
    f->width = width;
    f->height = height;
    f->stride = stride;
    if (!PostMessageW(g_msg_hwnd, WM_OL_FRAME, 0, (LPARAM)f)) {
        InterlockedExchange(&n->frame_pending, 0);
        free(owned_bgra);
        release_native(n);
        free(f);
    }
}

void ol_internal_emit_event(OLNative *n, const char *event, const char *text, int number) {
    emit_event(n, event, text, number);
}

int ol_internal_copy_last_frame(OLNative *n, uint8_t **bytes_out, int *width_out, int *height_out, int *stride_out) {
    if (!n || !bytes_out) return 0;
    *bytes_out = NULL;
    EnterCriticalSection(&n->lock);
    int w = n->last_frame_width;
    int h = n->last_frame_height;
    int stride = n->last_frame_stride;
    if (!n->last_frame_bytes || w <= 0 || h <= 0 || stride <= 0) {
        LeaveCriticalSection(&n->lock);
        return 0;
    }
    size_t sz = (size_t)stride * (size_t)h;
    uint8_t *copy = (uint8_t *)malloc(sz);
    if (copy) memcpy(copy, n->last_frame_bytes, sz);
    LeaveCriticalSection(&n->lock);
    if (!copy) return 0;
    *bytes_out = copy;
    if (width_out) *width_out = w;
    if (height_out) *height_out = h;
    if (stride_out) *stride_out = stride;
    return 1;
}

int ol_internal_take_rendered_frames(OLNative *n, int *width_out, int *height_out) {
    if (!n) return 0;
    EnterCriticalSection(&n->lock);
    int fps = n->rendered_frames_window;
    n->rendered_frames_window = 0;
    if (width_out) *width_out = n->last_frame_width;
    if (height_out) *height_out = n->last_frame_height;
    LeaveCriticalSection(&n->lock);
    return fps;
}

int ol_internal_has_frame(OLNative *n) {
    if (!n) return 0;
    EnterCriticalSection(&n->lock);
    int has = n->got_frame;
    LeaveCriticalSection(&n->lock);
    return has;
}

OLGstState *ol_internal_get_gst(OLNative *n) {
    if (!n) return NULL;
    EnterCriticalSection(&n->lock);
    OLGstState *gst = n->gst;
    LeaveCriticalSection(&n->lock);
    return gst;
}

void ol_internal_set_gst(OLNative *n, OLGstState *gst) {
    if (!n) return;
    EnterCriticalSection(&n->lock);
    n->gst = gst;
    LeaveCriticalSection(&n->lock);
}

OLRecorder *ol_internal_get_recorder(OLNative *n) {
    if (!n) return NULL;
    EnterCriticalSection(&n->lock);
    OLRecorder *rec = n->recorder;
    LeaveCriticalSection(&n->lock);
    return rec;
}

void ol_internal_set_recorder(OLNative *n, OLRecorder *rec) {
    if (!n) return;
    EnterCriticalSection(&n->lock);
    n->recorder = rec;
    LeaveCriticalSection(&n->lock);
}

void ol_internal_ensure_parent_dir(const char *path) {
    ensure_parent_dir(path);
}

int ol_internal_file_nonempty(const char *utf8_path) {
    if (!utf8_path || !utf8_path[0]) return 0;
    wchar_t *wpath = utf8_to_wide(utf8_path);
    WIN32_FILE_ATTRIBUTE_DATA fad;
    BOOL ok = GetFileAttributesExW(wpath, GetFileExInfoStandard, &fad);
    free(wpath);
    return ok && !(fad.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) &&
           (fad.nFileSizeLow > 0 || fad.nFileSizeHigh > 0);
}

// ============================================================================
// Low-Level Keyboard Hook for System Shortcut Capture (Alt+Tab, Win, F11)
// ============================================================================

static HWND g_main_hwnd = NULL;
static HWND g_video_hwnd = NULL;

static LRESULT CALLBACK low_level_kb_proc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode == HC_ACTION && g_captured_native && g_captured_native->inhibited) {
        HWND fg = GetForegroundWindow();
        if (fg && (fg == g_main_hwnd || fg == g_video_hwnd)) {
            KBDLLHOOKSTRUCT *kb = (KBDLLHOOKSTRUCT *)lParam;
            int isDown = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN);
            int isUp = (wParam == WM_KEYUP || wParam == WM_SYSKEYUP);
            if (isDown || isUp) {
                int ext = (kb->flags & LLKHF_EXTENDED) ? 0x100 : 0;
                int code = ((int)(kb->scanCode & 0xFF)) | ext;
                ol_native_emit_input(g_captured_native, isDown ? OL_INPUT_KEY_DOWN : OL_INPUT_KEY_UP, code, 0, 0);
                return 1;
            }
        }
    }
    return CallNextHookEx(g_kb_hook, nCode, wParam, lParam);
}

static void update_kb_hook(OLNative *n, int enabled) {
    if (n) n->inhibited = enabled;
    if (enabled) {
        g_captured_native = n;
        if (!g_kb_hook) {
            g_kb_hook = SetWindowsHookExW(WH_KEYBOARD_LL, low_level_kb_proc, GetModuleHandleW(NULL), 0);
        }
    } else {
        if (!n || g_captured_native == n) g_captured_native = NULL;
        if (g_kb_hook && !g_captured_native) {
            UnhookWindowsHookEx(g_kb_hook);
            g_kb_hook = NULL;
        }
    }
}

// ============================================================================
// SHA-256 Certificate Pinning & Credential-Free TLS Probe
// ============================================================================

static char *sha256_hex(const uint8_t *data, size_t len) {
    BCRYPT_ALG_HANDLE hAlg = NULL;
    uint8_t hash[32] = {0};
    if (BCryptOpenAlgorithmProvider(&hAlg, BCRYPT_SHA256_ALGORITHM, NULL, 0) == 0) {
        BCryptHash(hAlg, NULL, 0, (PUCHAR)data, (ULONG)len, hash, sizeof(hash));
        BCryptCloseAlgorithmProvider(hAlg, 0);
    }
    char *hex = (char *)calloc(65, 1);
    if (!hex) return NULL;
    for (int i = 0; i < 32; i++) {
        sprintf_s(hex + i * 2, 3, "%02x", hash[i]);
    }
    return hex;
}

static int is_pin_allowed(OLNative *n, const char *key, const char *sha256) {
    if (!n || !key || !sha256) return 0;
    int allowed = 0;
    EnterCriticalSection(&n->lock);
    AllowedPin *p = n->allowed;
    while (p) {
        if (_stricmp(p->key, key) == 0 && _stricmp(p->sha256, sha256) == 0) {
            allowed = 1;
            break;
        }
        p = p->next;
    }
    LeaveCriticalSection(&n->lock);
    return allowed;
}

void ol_native_allow(OLNative *n, const char *key, const char *sha256) {
    if (!n || !key || !sha256) return;
    EnterCriticalSection(&n->lock);
    AllowedPin *p = n->allowed;
    while (p) {
        if (_stricmp(p->key, key) == 0) {
            free(p->sha256);
            p->sha256 = _strdup(sha256);
            LeaveCriticalSection(&n->lock);
            return;
        }
        p = p->next;
    }
    AllowedPin *node = (AllowedPin *)calloc(1, sizeof(AllowedPin));
    if (node) {
        node->key = _strdup(key);
        node->sha256 = _strdup(sha256);
        node->next = n->allowed;
        n->allowed = node;
    }
    LeaveCriticalSection(&n->lock);
}

typedef struct ParsedURL {
    int is_https;
    wchar_t host[256];
    char host_utf8[256];
    INTERNET_PORT port;
    wchar_t path[4096];
    char key[300];
} ParsedURL;

static int parse_url(const char *url_str, ParsedURL *out) {
    memset(out, 0, sizeof(*out));
    if (!url_str || !url_str[0]) return 0;
    wchar_t *wurl = utf8_to_wide(url_str);
    int is_wss = (_wcsnicmp(wurl, L"wss://", 6) == 0);
    int is_ws = (_wcsnicmp(wurl, L"ws://", 5) == 0);
    wchar_t normalized[4096] = {0};
    int fmt_ok = 1;
    if (is_wss) {
        fmt_ok = (swprintf_s(normalized, 4096, L"https://%ls", wurl + 6) > 0);
    } else if (is_ws) {
        fmt_ok = (swprintf_s(normalized, 4096, L"http://%ls", wurl + 5) > 0);
    } else {
        wcsncpy_s(normalized, 4096, wurl, _TRUNCATE);
    }
    free(wurl);
    if (!fmt_ok) return 0;

    URL_COMPONENTS uc = {0};
    uc.dwStructSize = sizeof(uc);
    uc.lpszHostName = out->host;
    uc.dwHostNameLength = 255;
    uc.lpszUrlPath = out->path;
    uc.dwUrlPathLength = 4095;
    if (!WinHttpCrackUrl(normalized, 0, 0, &uc)) return 0;

    out->is_https = (uc.nScheme == INTERNET_SCHEME_HTTPS);
    out->port = uc.nPort ? uc.nPort : (out->is_https ? 443 : 80);
    if (out->path[0] == L'\0') wcscpy_s(out->path, 4096, L"/");

    char *h = wide_to_utf8(out->host);
    for (char *c = h; *c; c++) *c = (char)tolower((unsigned char)*c);
    strncpy_s(out->host_utf8, sizeof(out->host_utf8), h, _TRUNCATE);
    free(h);
    sprintf_s(out->key, sizeof(out->key), "%s:%d", out->host_utf8, (int)out->port);
    return 1;
}

static void add_cookie_header(OLNative *n, HINTERNET hReq) {
    char *tok = NULL;
    EnterCriticalSection(&n->lock);
    if (n->cookie_token && n->cookie_token[0]) {
        tok = _strdup(n->cookie_token);
    }
    LeaveCriticalSection(&n->lock);
    if (!tok) return;

    char *hdr = alloc_printf("Cookie: auth_token=%s; nano-kvm-token=%s\r\n", tok, tok);
    SecureZeroMemory(tok, strlen(tok));
    free(tok);
    if (!hdr) return;

    wchar_t *whdr = utf8_to_wide(hdr);
    SecureZeroMemory(hdr, strlen(hdr));
    free(hdr);
    if (whdr) {
        WinHttpAddRequestHeaders(hReq, whdr, (DWORD)-1L, WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
        free(whdr);
    }
}

static int verify_pinned_certificate(OLNative *n, HINTERNET hReq, const char *key, char **cert_event_out) {
    PCCERT_CONTEXT pCert = NULL;
    DWORD cbCert = sizeof(pCert);
    if (!WinHttpQueryOption(hReq, WINHTTP_OPTION_SERVER_CERT_CONTEXT, &pCert, &cbCert) || !pCert) {
        return 0;
    }
    char *hex = sha256_hex(pCert->pbCertEncoded, pCert->cbCertEncoded);
    CertFreeCertificateContext(pCert);
    if (!hex) return 0;

    int ok = is_pin_allowed(n, key, hex);
    if (!ok && cert_event_out) {
        *cert_event_out = alloc_printf("%s\n%s\nIt is not issued by a trusted certificate authority.", key, hex);
    }
    free(hex);
    return ok;
}

// Performs a credential-free, cookie-free HEAD / probe with ignore flags so we
// inspect and verify the peer certificate pin BEFORE transmitting credentials.
static int probe_untrusted_certificate(OLNative *n, HINTERNET hConnect, const ParsedURL *pu, char **cert_event_out) {
    if (cert_event_out) *cert_event_out = NULL;
    HINTERNET hProbe = WinHttpOpenRequest(hConnect, L"HEAD", L"/", NULL, WINHTTP_NO_REFERER,
                                          WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE);
    if (!hProbe) return 0;
    DWORD secFlags = SECURITY_FLAG_IGNORE_UNKNOWN_CA |
                     SECURITY_FLAG_IGNORE_CERT_CN_INVALID |
                     SECURITY_FLAG_IGNORE_CERT_DATE_INVALID |
                     SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
    WinHttpSetOption(hProbe, WINHTTP_OPTION_SECURITY_FLAGS, &secFlags, sizeof(secFlags));
    int ok = 0;
    if (WinHttpSendRequest(hProbe, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) {
        ok = verify_pinned_certificate(n, hProbe, pu->key, cert_event_out);
    }
    WinHttpCloseHandle(hProbe);
    return ok;
}

static HINTERNET open_winhttp_session(void) {
    HINTERNET hSession = WinHttpOpen(L"Overlook/1.0.2 (Windows)", WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                     WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession) {
        hSession = WinHttpOpen(L"Overlook/1.0.2 (Windows)", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                               WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    }
    if (hSession) {
        WinHttpSetTimeouts(hSession, 10000, 10000, 15000, 15000);
    }
    return hSession;
}

// ============================================================================
// Async HTTP Requests (Login & General REST API)
// ============================================================================

typedef struct HTTPJob {
    OLNative *n;
    char *method;
    char *url;
    char *content_type;
    uint8_t *body;
    int body_len;
    int is_login;
    OLNativeHTTPResponse cb;
    void *ctx;
} HTTPJob;

static void dispatch_http_callback(OLNative *n, OLNativeHTTPResponse cb, void *ctx,
                                   int status, uint8_t *data, int length, const char *err_msg) {
    if (!cb) {
        free(data);
        return;
    }
    if (!g_msg_hwnd) {
        cb(0, NULL, 0, err_msg ? err_msg : "Window unavailable", ctx);
        free(data);
        return;
    }
    QueuedHTTP *q = (QueuedHTTP *)calloc(1, sizeof(QueuedHTTP));
    if (!q) {
        free(data);
        return;
    }
    q->n = retain_native(n);
    q->cb = cb;
    q->ctx = ctx;
    q->status = status;
    q->data = data;
    q->length = length;
    q->error = err_msg ? _strdup(err_msg) : NULL;
    if (!PostMessageW(g_msg_hwnd, WM_OL_HTTP_RESP, 0, (LPARAM)q)) {
        release_native(q->n);
        free(q->data);
        free(q->error);
        free(q);
    }
}

static void fail_http_job(const HTTPJob *job, const char *msg) {
    if (job->is_login) {
        emit_event(job->n, "error", msg, 0);
    } else {
        dispatch_http_callback(job->n, job->cb, job->ctx, 0, NULL, 0, msg);
    }
}

static DWORD WINAPI http_worker_thread(LPVOID param) {
    HTTPJob *job = (HTTPJob *)param;
    OLNative *n = job->n;
    ParsedURL pu;
    if (!parse_url(job->url, &pu)) {
        fail_http_job(job, "Invalid API URL");
        goto cleanup;
    }

    HINTERNET hSession = open_winhttp_session();
    if (!hSession) {
        fail_http_job(job, "Could not initialize WinHTTP session");
        goto cleanup;
    }

    HINTERNET hConnect = WinHttpConnect(hSession, pu.host, pu.port, 0);
    if (!hConnect) {
        WinHttpCloseHandle(hSession);
        fail_http_job(job, "Could not connect to host");
        goto cleanup;
    }

    wchar_t *wmethod = utf8_to_wide(job->method);
    DWORD flags = pu.is_https ? WINHTTP_FLAG_SECURE : 0;
    HINTERNET hReq = WinHttpOpenRequest(hConnect, wmethod, pu.path, NULL, WINHTTP_NO_REFERER,
                                        WINHTTP_DEFAULT_ACCEPT_TYPES, flags);
    free(wmethod);

    if (!hReq) {
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        fail_http_job(job, "Could not open HTTP request");
        goto cleanup;
    }

    if (job->is_login) {
        DWORD disableRedir = WINHTTP_DISABLE_REDIRECTS;
        WinHttpSetOption(hReq, WINHTTP_OPTION_DISABLE_FEATURE, &disableRedir, sizeof(disableRedir));
    }

    add_cookie_header(n, hReq);
    if (job->content_type && job->content_type[0]) {
        char *hdr = alloc_printf("Content-Type: %s\r\n", job->content_type);
        if (hdr) {
            wchar_t *whdr = utf8_to_wide(hdr);
            free(hdr);
            if (whdr) {
                WinHttpAddRequestHeaders(hReq, whdr, (DWORD)-1L, WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
                free(whdr);
            }
        }
    }

    BOOL sent = WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                   job->body_len > 0 ? job->body : WINHTTP_NO_REQUEST_DATA,
                                   (DWORD)job->body_len, (DWORD)job->body_len, 0);
    if (!sent && GetLastError() == ERROR_WINHTTP_SECURE_FAILURE && pu.is_https) {
        char *cert_event = NULL;
        if (!probe_untrusted_certificate(n, hConnect, &pu, &cert_event)) {
            WinHttpCloseHandle(hReq);
            WinHttpCloseHandle(hConnect);
            WinHttpCloseHandle(hSession);
            if (job->is_login) {
                if (cert_event) {
                    emit_event(n, "certificate", cert_event, 0);
                } else {
                    emit_event(n, "error", "The device certificate could not be verified.", 0);
                }
            } else {
                dispatch_http_callback(n, job->cb, job->ctx, 0, NULL, 0, "The device certificate could not be verified.");
            }
            free(cert_event);
            goto cleanup;
        }
        free(cert_event);

        DWORD secFlags = SECURITY_FLAG_IGNORE_UNKNOWN_CA |
                         SECURITY_FLAG_IGNORE_CERT_CN_INVALID |
                         SECURITY_FLAG_IGNORE_CERT_DATE_INVALID |
                         SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
        WinHttpSetOption(hReq, WINHTTP_OPTION_SECURITY_FLAGS, &secFlags, sizeof(secFlags));
        sent = WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                  job->body_len > 0 ? job->body : WINHTTP_NO_REQUEST_DATA,
                                  (DWORD)job->body_len, (DWORD)job->body_len, 0);
        if (sent && !verify_pinned_certificate(n, hReq, pu.key, NULL)) {
            WinHttpCloseHandle(hReq);
            WinHttpCloseHandle(hConnect);
            WinHttpCloseHandle(hSession);
            fail_http_job(job, "The device certificate changed unexpectedly.");
            goto cleanup;
        }
    }

    if (!sent || !WinHttpReceiveResponse(hReq, NULL)) {
        WinHttpCloseHandle(hReq);
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        fail_http_job(job, job->is_login
            ? "Network request failed. Check the device address and port."
            : "Network request failed.");
        goto cleanup;
    }

    DWORD statusCode = 0;
    DWORD statusSize = sizeof(statusCode);
    WinHttpQueryHeaders(hReq, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX, &statusCode, &statusSize, WINHTTP_NO_HEADER_INDEX);

    if (job->is_login) {
        wchar_t cookieHdr[4096] = {0};
        DWORD cookieLen = sizeof(cookieHdr);
        DWORD idx = 0;
        while (WinHttpQueryHeaders(hReq, WINHTTP_QUERY_SET_COOKIE, WINHTTP_HEADER_NAME_BY_INDEX,
                                   cookieHdr, &cookieLen, &idx)) {
            char *cstr = wide_to_utf8(cookieHdr);
            const char *tok = strstr(cstr, "auth_token=");
            if (!tok) tok = strstr(cstr, "nano-kvm-token=");
            if (tok) {
                tok = strchr(tok, '=');
                if (tok) {
                    tok++;
                    const char *end = strchr(tok, ';');
                    size_t tlen = end ? (size_t)(end - tok) : strlen(tok);
                    if (tlen > 0) {
                        EnterCriticalSection(&n->lock);
                        if (n->cookie_token) {
                            SecureZeroMemory(n->cookie_token, strlen(n->cookie_token));
                            free(n->cookie_token);
                        }
                        n->cookie_token = (char *)calloc(tlen + 1, 1);
                        if (n->cookie_token) memcpy(n->cookie_token, tok, tlen);
                        LeaveCriticalSection(&n->lock);
                    }
                }
            }
            SecureZeroMemory(cstr, strlen(cstr));
            free(cstr);
            cookieLen = sizeof(cookieHdr);
        }
    }

    uint8_t *respBuf = NULL;
    size_t respLen = 0;
    DWORD avail = 0;
    while (WinHttpQueryDataAvailable(hReq, &avail) && avail > 0) {
        if (avail > OL_MAX_HTTP_RESPONSE_BYTES - respLen) {
            free(respBuf);
            respBuf = NULL;
            respLen = 0;
            break;
        }
        uint8_t *next = (uint8_t *)realloc(respBuf, respLen + avail + 1);
        if (!next) {
            free(respBuf);
            respBuf = NULL;
            respLen = 0;
            break;
        }
        respBuf = next;
        DWORD readBytes = 0;
        if (WinHttpReadData(hReq, respBuf + respLen, avail, &readBytes)) {
            respLen += readBytes;
            respBuf[respLen] = 0;
        } else {
            break;
        }
    }

    WinHttpCloseHandle(hReq);
    WinHttpCloseHandle(hConnect);
    WinHttpCloseHandle(hSession);

    if (job->is_login) {
        emit_event(n, "http", respBuf ? (const char *)respBuf : "", (int)statusCode);
        free(respBuf);
    } else {
        dispatch_http_callback(n, job->cb, job->ctx, (int)statusCode, respBuf, (int)respLen, NULL);
    }

cleanup:
    release_native(n);
    free(job->method);
    free(job->url);
    free(job->content_type);
    if (job->body) {
        SecureZeroMemory(job->body, (size_t)job->body_len);
        free(job->body);
    }
    free(job);
    return 0;
}

void ol_native_http(OLNative *n, const char *method, const char *url, const char *body) {
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0)) return;
    HTTPJob *job = (HTTPJob *)calloc(1, sizeof(HTTPJob));
    if (!job) return;
    job->n = retain_native(n);
    job->method = _strdup(method ? method : "POST");
    job->url = _strdup(url ? url : "");
    job->content_type = _strdup("application/x-www-form-urlencoded");
    job->body_len = body ? (int)strlen(body) : 0;
    if (job->body_len > 0) {
        job->body = (uint8_t *)malloc((size_t)job->body_len);
        if (job->body) memcpy(job->body, body, (size_t)job->body_len);
        else job->body_len = 0;
    }
    job->is_login = 1;
    HANDLE th = CreateThread(NULL, 0, http_worker_thread, job, 0, NULL);
    if (th) {
        CloseHandle(th);
    } else {
        release_native(job->n);
        free(job->method);
        free(job->url);
        free(job->content_type);
        if (job->body) {
            SecureZeroMemory(job->body, (size_t)job->body_len);
            free(job->body);
        }
        free(job);
        emit_event(n, "error", "Could not start HTTP request thread.", 0);
    }
}

void ol_native_request(OLNative *n, const char *method, const char *url,
                       const char *content_type, const unsigned char *body, int body_length,
                       OLNativeHTTPResponse callback, void *context) {
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0)) {
        if (callback) callback(0, NULL, 0, "Session is not active", context);
        return;
    }
    HTTPJob *job = (HTTPJob *)calloc(1, sizeof(HTTPJob));
    if (!job) {
        if (callback) callback(0, NULL, 0, "Out of memory", context);
        return;
    }
    job->n = retain_native(n);
    job->method = _strdup(method ? method : "GET");
    job->url = _strdup(url ? url : "");
    job->content_type = content_type ? _strdup(content_type) : NULL;
    if (body && body_length > 0) {
        job->body = (uint8_t *)malloc((size_t)body_length);
        if (job->body) {
            memcpy(job->body, body, (size_t)body_length);
            job->body_len = body_length;
        }
    }
    job->is_login = 0;
    job->cb = callback;
    job->ctx = context;
    HANDLE th = CreateThread(NULL, 0, http_worker_thread, job, 0, NULL);
    if (th) {
        CloseHandle(th);
    } else {
        release_native(job->n);
        free(job->method);
        free(job->url);
        free(job->content_type);
        free(job->body);
        free(job);
        if (callback) callback(0, NULL, 0, "Could not start HTTP request thread.", context);
    }
}

void ol_native_cookie(OLNative *n, const char *url, const char *token) {
    (void)url;
    if (!n || !token) return;
    EnterCriticalSection(&n->lock);
    if (n->cookie_token) {
        SecureZeroMemory(n->cookie_token, strlen(n->cookie_token));
        free(n->cookie_token);
    }
    n->cookie_token = _strdup(token);
    LeaveCriticalSection(&n->lock);
}

// ============================================================================
// WinHTTP WebSockets (Signaling & HID)
// ============================================================================

typedef struct WSStartArgs {
    OLNative *n;
    char *url;
    char *origin;
    int is_hid;
} WSStartArgs;

static DWORD WINAPI ws_worker_thread(LPVOID param) {
    WSStartArgs *args = (WSStartArgs *)param;
    OLNative *n = args->n;
    int is_hid = args->is_hid;
    ParsedURL pu;
    if (!parse_url(args->url, &pu)) {
        emit_event(n, is_hid ? "hid-closed" : "error", "Invalid WebSocket URL", 0);
        goto done;
    }

    HINTERNET hSession = open_winhttp_session();
    HINTERNET hConnect = hSession ? WinHttpConnect(hSession, pu.host, pu.port, 0) : NULL;
    HINTERNET hReq = hConnect ? WinHttpOpenRequest(hConnect, L"GET", pu.path, NULL, WINHTTP_NO_REFERER,
                                                   WINHTTP_DEFAULT_ACCEPT_TYPES,
                                                   pu.is_https ? WINHTTP_FLAG_SECURE : 0) : NULL;
    if (!hReq) {
        if (hConnect) WinHttpCloseHandle(hConnect);
        if (hSession) WinHttpCloseHandle(hSession);
        emit_event(n, is_hid ? "hid-closed" : "error", "Could not open WebSocket request", 0);
        goto done;
    }

    WinHttpSetOption(hReq, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, NULL, 0);
    add_cookie_header(n, hReq);
    if (!is_hid && strstr(args->url, "/janus/ws") != NULL) {
        WinHttpAddRequestHeaders(hReq, L"Sec-WebSocket-Protocol: janus-protocol\r\n", (DWORD)-1L, WINHTTP_ADDREQ_FLAG_ADD);
    }
    if (args->origin && args->origin[0]) {
        char *ohdr = alloc_printf("Origin: %s\r\n", args->origin);
        if (ohdr) {
            wchar_t *wohdr = utf8_to_wide(ohdr);
            free(ohdr);
            if (wohdr) {
                WinHttpAddRequestHeaders(hReq, wohdr, (DWORD)-1L, WINHTTP_ADDREQ_FLAG_ADD);
                free(wohdr);
            }
        }
    }

    BOOL sent = WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
    if (!sent && GetLastError() == ERROR_WINHTTP_SECURE_FAILURE && pu.is_https) {
        char *cert_event = NULL;
        if (!probe_untrusted_certificate(n, hConnect, &pu, &cert_event)) {
            WinHttpCloseHandle(hReq);
            WinHttpCloseHandle(hConnect);
            WinHttpCloseHandle(hSession);
            if (!is_hid && cert_event) emit_event(n, "certificate", cert_event, 0);
            else emit_event(n, is_hid ? "hid-closed" : "error", "Certificate not trusted", 0);
            free(cert_event);
            goto done;
        }
        free(cert_event);

        DWORD secFlags = SECURITY_FLAG_IGNORE_UNKNOWN_CA |
                         SECURITY_FLAG_IGNORE_CERT_CN_INVALID |
                         SECURITY_FLAG_IGNORE_CERT_DATE_INVALID |
                         SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
        WinHttpSetOption(hReq, WINHTTP_OPTION_SECURITY_FLAGS, &secFlags, sizeof(secFlags));
        sent = WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
        if (sent && !verify_pinned_certificate(n, hReq, pu.key, NULL)) {
            WinHttpCloseHandle(hReq);
            WinHttpCloseHandle(hConnect);
            WinHttpCloseHandle(hSession);
            emit_event(n, is_hid ? "hid-closed" : "error", "Certificate changed unexpectedly", 0);
            goto done;
        }
    }

    if (!sent || !WinHttpReceiveResponse(hReq, NULL)) {
        WinHttpCloseHandle(hReq);
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        emit_event(n, is_hid ? "hid-closed" : "error", "WebSocket handshake failed", 0);
        goto done;
    }

    HINTERNET hWs = WinHttpWebSocketCompleteUpgrade(hReq, 0);
    WinHttpCloseHandle(hReq);
    if (!hWs) {
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        emit_event(n, is_hid ? "hid-closed" : "error", "WebSocket upgrade rejected by server", 0);
        goto done;
    }

    HINTERNET old_ws = NULL, old_connect = NULL, old_session = NULL;
    EnterCriticalSection(&n->lock);
    if (!InterlockedCompareExchange(&n->active, 0, 0)) {
        LeaveCriticalSection(&n->lock);
        WinHttpCloseHandle(hWs);
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        goto done;
    }
    if (is_hid) {
        old_ws = n->hid_handle; old_connect = n->hid_connect; old_session = n->hid_session;
        n->hid_session = hSession;
        n->hid_connect = hConnect;
        n->hid_handle = hWs;
        InterlockedExchange(&n->hid_open, 1);
    } else {
        old_ws = n->ws_handle; old_connect = n->ws_connect; old_session = n->ws_session;
        n->ws_session = hSession;
        n->ws_connect = hConnect;
        n->ws_handle = hWs;
        InterlockedExchange(&n->ws_open, 1);
    }
    LeaveCriticalSection(&n->lock);

    if (old_ws) WinHttpCloseHandle(old_ws);
    if (old_connect) WinHttpCloseHandle(old_connect);
    if (old_session) WinHttpCloseHandle(old_session);

    emit_event(n, is_hid ? "hid-open" : "open", "", 0);

    size_t cap = 65536;
    uint8_t *buf = (uint8_t *)malloc(cap);
    size_t offset = 0;

    while (buf && InterlockedCompareExchange(&n->active, 0, 0)) {
        DWORD readBytes = 0;
        WINHTTP_WEB_SOCKET_BUFFER_TYPE bufType = WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE;
        if (offset + 4096 >= cap) {
            if (cap >= OL_MAX_HTTP_RESPONSE_BYTES) break;
            cap *= 2;
            uint8_t *next = (uint8_t *)realloc(buf, cap);
            if (!next) break;
            buf = next;
        }
        DWORD err = WinHttpWebSocketReceive(hWs, buf + offset, (DWORD)(cap - offset - 1), &readBytes, &bufType);
        if (err != NO_ERROR) break;
        if (bufType == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) break;

        offset += readBytes;
        if (bufType == WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE) {
            buf[offset] = 0;
            emit_event(n, is_hid ? "hid" : "ws", (const char *)buf, 0);
            offset = 0;
        } else if (bufType == WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE) {
            offset = 0;
        }
    }
    free(buf);

    HINTERNET close_ws = NULL, close_connect = NULL, close_session = NULL;
    EnterCriticalSection(&n->lock);
    if (is_hid) {
        if (n->hid_handle == hWs) {
            InterlockedExchange(&n->hid_open, 0);
            close_ws = n->hid_handle; n->hid_handle = NULL;
            close_connect = n->hid_connect; n->hid_connect = NULL;
            close_session = n->hid_session; n->hid_session = NULL;
        }
    } else {
        if (n->ws_handle == hWs) {
            InterlockedExchange(&n->ws_open, 0);
            close_ws = n->ws_handle; n->ws_handle = NULL;
            close_connect = n->ws_connect; n->ws_connect = NULL;
            close_session = n->ws_session; n->ws_session = NULL;
        }
    }
    LeaveCriticalSection(&n->lock);

    if (close_ws) WinHttpCloseHandle(close_ws);
    if (close_connect) WinHttpCloseHandle(close_connect);
    if (close_session) WinHttpCloseHandle(close_session);

    if (InterlockedCompareExchange(&n->active, 0, 0)) {
        if (is_hid) {
            emit_event(n, "hid-closed", "Keyboard and mouse connection closed", 0);
        } else {
            emit_event(n, "error", "Video signaling connection closed", 0);
        }
    }

done:
    release_native(n);
    free(args->url);
    free(args->origin);
    free(args);
    return 0;
}

static void start_ws_worker(OLNative *n, const char *url, const char *origin, int is_hid) {
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0)) return;
    WSStartArgs *args = (WSStartArgs *)calloc(1, sizeof(WSStartArgs));
    if (!args) return;
    args->n = retain_native(n);
    args->url = _strdup(url ? url : "");
    args->origin = _strdup(origin ? origin : "");
    args->is_hid = is_hid;
    HANDLE th = CreateThread(NULL, 0, ws_worker_thread, args, 0, NULL);
    if (th) {
        CloseHandle(th);
    } else {
        release_native(args->n);
        free(args->url);
        free(args->origin);
        free(args);
        emit_event(n, is_hid ? "hid-closed" : "error", "Could not start WebSocket thread", 0);
    }
}

void ol_native_socket(OLNative *n, const char *url, const char *origin) {
    start_ws_worker(n, url, origin, 0);
}

void ol_native_send(OLNative *n, const char *json) {
    if (!n || !json || !InterlockedCompareExchange(&n->ws_open, 0, 0)) {
        emit_event(n, "error", "Signaling socket is not connected", 0);
        return;
    }
    EnterCriticalSection(&n->lock);
    HINTERNET hWs = n->ws_handle;
    LeaveCriticalSection(&n->lock);
    if (hWs) {
        WinHttpWebSocketSend(hWs, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, (PVOID)json, (DWORD)strlen(json));
    }
}

void ol_native_hid_socket(OLNative *n, const char *url, const char *origin) {
    start_ws_worker(n, url, origin, 1);
}

int ol_native_hid_ready(OLNative *n) {
    return n ? (int)InterlockedCompareExchange(&n->hid_open, 0, 0) : 0;
}

void ol_native_hid_send(OLNative *n, const unsigned char *bytes, int length) {
    if (!n || !bytes || length <= 0 || !ol_native_hid_ready(n)) return;
    EnterCriticalSection(&n->lock);
    HINTERNET hWs = n->hid_handle;
    LeaveCriticalSection(&n->lock);
    if (hWs) {
        WinHttpWebSocketSend(hWs, WINHTTP_WEB_SOCKET_BINARY_MESSAGE_BUFFER_TYPE, (PVOID)bytes, (DWORD)length);
    }
}

void ol_native_hid_text(OLNative *n, const char *text) {
    if (!n || !text || !ol_native_hid_ready(n)) return;
    EnterCriticalSection(&n->lock);
    HINTERNET hWs = n->hid_handle;
    LeaveCriticalSection(&n->lock);
    if (hWs) {
        WinHttpWebSocketSend(hWs, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, (PVOID)text, (DWORD)strlen(text));
    }
}

// ============================================================================
// DXGI Hardware Encoder Probe & PNG Screenshots
// ============================================================================

static void append_json_escaped(char *dst, size_t dst_cap, size_t *pos, const char *src) {
    if (!dst || !pos || !src || *pos + 1 >= dst_cap) return;
    for (const char *p = src; *p && *pos + 3 < dst_cap; p++) {
        unsigned char c = (unsigned char)*p;
        if (c == '"' || c == '\\') {
            dst[(*pos)++] = '\\';
            dst[(*pos)++] = (char)c;
        } else if (c >= 0x20) {
            dst[(*pos)++] = (char)c;
        }
    }
    dst[*pos] = '\0';
}

char *ol_vaapi_probe(const char *preferred_device) {
    (void)preferred_device;
    int gst_h264 = 0, gst_hevc = 0;
    int gst_ok = ol_gst_probe_encoders(&gst_h264, &gst_hevc);

    static const GUID kIID_IDXGIFactory1 = {
        0x770aae78, 0xf26f, 0x4dba, { 0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 }
    };
    char *gpu_name = NULL;
    const char *drv = "Direct3D11 / Media Foundation";

    IDXGIFactory1 *pFactory = NULL;
    if (SUCCEEDED(CreateDXGIFactory1(&kIID_IDXGIFactory1, (void **)&pFactory)) && pFactory) {
        IDXGIAdapter1 *pAdapter = NULL;
        if (SUCCEEDED(pFactory->lpVtbl->EnumAdapters1(pFactory, 0, &pAdapter)) && pAdapter) {
            DXGI_ADAPTER_DESC1 desc;
            if (SUCCEEDED(pAdapter->lpVtbl->GetDesc1(pAdapter, &desc))) {
                gpu_name = wide_to_utf8(desc.Description);
                if (desc.VendorId == 0x10DE) drv = "NVIDIA NVENC / D3D11";
                else if (desc.VendorId == 0x1002) drv = "AMD AMF / D3D11";
                else if (desc.VendorId == 0x8086) drv = "Intel QSV / D3D11";
            }
            pAdapter->lpVtbl->Release(pAdapter);
        }
        pFactory->lpVtbl->Release(pFactory);
    }

    const char *device_label = (gpu_name && gpu_name[0]) ? gpu_name : "Windows Media Foundation";
    size_t cap = strlen(device_label) * 2 + strlen(drv) * 2 + 128;
    char *json = (char *)calloc(cap, 1);
    if (json) {
        size_t pos = 0;
        const char *p1 = "{\"available\":";
        size_t l1 = strlen(p1);
        memcpy(json + pos, p1, l1); pos += l1;
        const char *avail = (gst_ok || gpu_name != NULL) ? "true" : "false";
        size_t la = strlen(avail);
        memcpy(json + pos, avail, la); pos += la;
        const char *p2 = ",\"device\":\"";
        memcpy(json + pos, p2, 11); pos += 11;
        append_json_escaped(json, cap, &pos, device_label);
        const char *p3 = "\",\"driver\":\"";
        memcpy(json + pos, p3, 12); pos += 12;
        append_json_escaped(json, cap, &pos, drv);
        snprintf(json + pos, cap - pos, "\",\"h264\":%s,\"hevc\":%s}",
                 gst_h264 ? "true" : "false", gst_hevc ? "true" : "false");
    }
    free(gpu_name);
    return json ? json : _strdup("{\"available\":false,\"device\":\"\",\"driver\":\"\",\"h264\":false,\"hevc\":false}");
}

static uint32_t crc32_calc(const uint8_t *buf, size_t len) {
    uint32_t c = 0xFFFFFFFFU;
    for (size_t i = 0; i < len; i++) {
        c ^= buf[i];
        for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320U ^ (c >> 1)) : (c >> 1);
    }
    return c ^ 0xFFFFFFFFU;
}

static int write_be32(FILE *fp, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    return fwrite(b, 1, 4, fp) == 4;
}

static int write_png_chunk(FILE *fp, const char type[4], const uint8_t *data, uint32_t len) {
    uint8_t *crc_buf = (uint8_t *)malloc((size_t)4 + (size_t)len);
    if (!crc_buf) return 0;
    memcpy(crc_buf, type, 4);
    if (len > 0 && data) memcpy(crc_buf + 4, data, len);
    uint32_t crc = crc32_calc(crc_buf, (size_t)4 + (size_t)len);
    free(crc_buf);

    if (!write_be32(fp, len)) return 0;
    if (fwrite(type, 1, 4, fp) != 4) return 0;
    if (len > 0 && data && fwrite(data, 1, len, fp) != len) return 0;
    if (!write_be32(fp, crc)) return 0;
    return 1;
}

int ol_native_screenshot(OLNative *n, const char *path, char **error_out) {
    if (error_out) *error_out = NULL;
    if (!n || !path || !path[0]) {
        if (error_out) *error_out = _strdup("No active video session.");
        return 0;
    }

    uint8_t *frame_bytes = NULL;
    int w = 0, h = 0, stride = 0;
    if (!ol_internal_copy_last_frame(n, &frame_bytes, &w, &h, &stride) || w <= 0 || h <= 0 || w > 8192 || h > 8192) {
        free(frame_bytes);
        if (error_out) *error_out = _strdup("No decoded video frame available yet.");
        return 0;
    }

    ensure_parent_dir(path);
    wchar_t *wpath = utf8_to_wide(path);
    FILE *fp = NULL;
    _wfopen_s(&fp, wpath, L"wb");
    free(wpath);
    if (!fp) {
        free(frame_bytes);
        if (error_out) *error_out = _strdup("Failed to open screenshot file for writing.");
        return 0;
    }

    const uint8_t sig[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    int ok = (fwrite(sig, 1, 8, fp) == 8);

    uint8_t ihdr[13] = {
        (uint8_t)(w >> 24), (uint8_t)(w >> 16), (uint8_t)(w >> 8), (uint8_t)w,
        (uint8_t)(h >> 24), (uint8_t)(h >> 16), (uint8_t)(h >> 8), (uint8_t)h,
        8, 6, 0, 0, 0
    };
    if (ok) ok = write_png_chunk(fp, "IHDR", ihdr, 13);

    size_t row_bytes = (size_t)w * 4 + 1;
    size_t raw_size = row_bytes * (size_t)h;
    size_t num_blocks = (raw_size + 65534) / 65535;
    size_t idat_len = 2 + raw_size + num_blocks * 5 + 4;
    uint8_t *idat = ok ? (uint8_t *)malloc(idat_len) : NULL;
    if (!idat) ok = 0;

    if (ok) {
        size_t pos = 0;
        idat[pos++] = 0x78;
        idat[pos++] = 0x01;

        uint32_t s1 = 1, s2 = 0;
        size_t rem = raw_size;
        int cur_y = 0;
        size_t cur_row_off = 0;

        while (rem > 0) {
            uint16_t blen = (uint16_t)(rem > 65535 ? 65535 : rem);
            rem -= blen;
            idat[pos++] = (rem == 0) ? 0x01 : 0x00;
            idat[pos++] = (uint8_t)(blen & 0xFF);
            idat[pos++] = (uint8_t)(blen >> 8);
            uint16_t nlen = ~blen;
            idat[pos++] = (uint8_t)(nlen & 0xFF);
            idat[pos++] = (uint8_t)(nlen >> 8);

            for (uint16_t i = 0; i < blen; i++) {
                uint8_t byte = 0;
                if (cur_row_off == 0) {
                    byte = 0;
                } else {
                    size_t px = (cur_row_off - 1) / 4;
                    size_t ch = (cur_row_off - 1) % 4;
                    const uint8_t *src = frame_bytes + (size_t)cur_y * (size_t)stride + px * 4;
                    if (ch == 0) byte = src[2];
                    else if (ch == 1) byte = src[1];
                    else if (ch == 2) byte = src[0];
                    else byte = src[3];
                }
                idat[pos++] = byte;
                s1 = (s1 + byte) % 65521;
                s2 = (s2 + s1) % 65521;
                cur_row_off++;
                if (cur_row_off == row_bytes) {
                    cur_row_off = 0;
                    cur_y++;
                }
            }
        }
        uint32_t adler = (s2 << 16) | s1;
        idat[pos++] = (uint8_t)(adler >> 24);
        idat[pos++] = (uint8_t)(adler >> 16);
        idat[pos++] = (uint8_t)(adler >> 8);
        idat[pos++] = (uint8_t)adler;

        ok = write_png_chunk(fp, "IDAT", idat, (uint32_t)pos);
    }
    free(idat);
    free(frame_bytes);

    if (ok) ok = write_png_chunk(fp, "IEND", NULL, 0);
    if (ferror(fp)) ok = 0;
    if (fclose(fp) != 0) ok = 0;

    if (!ok && error_out) {
        *error_out = _strdup("Failed to write PNG screenshot data.");
    }
    return ok ? 1 : 0;
}

// ============================================================================
// Lifecycle, Input & Geometry
// ============================================================================

OLNative *ol_native_new(OLNativeEvent callback, void *context) {
    ensure_msg_hwnd();
    OLNative *n = (OLNative *)calloc(1, sizeof(OLNative));
    if (!n) return NULL;
    InitializeCriticalSection(&n->lock);
    n->refs = 1;
    n->active = 1;
    n->callback = callback;
    n->context = context;
    n->widget_width = 1280.0;
    n->widget_height = 720.0;
    ol_gst_init_session(n);
    return n;
}

void *ol_native_picture(OLNative *n) {
    return (void *)n;
}

void ol_native_set_frame_callback(OLNative *n, OLNativeFrame callback, void *context) {
    if (!n) return;
    n->frame_cb = callback;
    n->frame_context = context;
}

void ol_native_set_widget_size(OLNative *n, double width, double height) {
    if (!n) return;
    if (width > 0) n->widget_width = width;
    if (height > 0) n->widget_height = height;
}

void ol_native_input(OLNative *n, OLNativeInput callback, void *context) {
    if (!n) return;
    n->input = callback;
    n->input_context = context;
}

void ol_native_emit_input(OLNative *n, int kind, int code, double x, double y) {
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0) || !n->input) return;
    if (kind == OL_INPUT_FOCUS_IN) update_kb_hook(n, 1);
    else if (kind == OL_INPUT_FOCUS_OUT) update_kb_hook(n, 0);
    n->input(kind, code, x, y, n->input_context);
}

void ol_native_geometry(OLNative *n, double *width, double *height, double *video_width, double *video_height) {
    if (!n) return;
    EnterCriticalSection(&n->lock);
    if (width) *width = n->widget_width;
    if (height) *height = n->widget_height;
    if (video_width) *video_width = (double)n->last_frame_width;
    if (video_height) *video_height = (double)n->last_frame_height;
    LeaveCriticalSection(&n->lock);
}

void ol_native_focus(OLNative *n, int focused) {
    if (!n) return;
    n->focused = focused;
    ol_native_emit_input(n, focused ? OL_INPUT_FOCUS_IN : OL_INPUT_FOCUS_OUT, 0, 0, 0);
}

void ol_native_cursor(OLNative *n, const char *name) {
    (void)n;
    if (name && strcmp(name, "none") == 0) {
        SetCursor(NULL);
    } else {
        SetCursor(LoadCursorW(NULL, IDC_ARROW));
    }
}

void ol_native_close(OLNative *n) {
    if (!n) return;
    if (InterlockedCompareExchange(&n->active, 0, 1) != 1) return;

    ol_gst_recorder_abort(n);
    update_kb_hook(n, 0);
    n->input = NULL;
    n->frame_cb = NULL;

    ol_gst_close_session(n);

    EnterCriticalSection(&n->lock);
    InterlockedExchange(&n->ws_open, 0);
    InterlockedExchange(&n->hid_open, 0);
    HINTERNET ws_h = n->ws_handle; n->ws_handle = NULL;
    HINTERNET ws_c = n->ws_connect; n->ws_connect = NULL;
    HINTERNET ws_s = n->ws_session; n->ws_session = NULL;
    HINTERNET hid_h = n->hid_handle; n->hid_handle = NULL;
    HINTERNET hid_c = n->hid_connect; n->hid_connect = NULL;
    HINTERNET hid_s = n->hid_session; n->hid_session = NULL;
    LeaveCriticalSection(&n->lock);

    if (ws_h) WinHttpCloseHandle(ws_h);
    if (ws_c) WinHttpCloseHandle(ws_c);
    if (ws_s) WinHttpCloseHandle(ws_s);
    if (hid_h) WinHttpCloseHandle(hid_h);
    if (hid_c) WinHttpCloseHandle(hid_c);
    if (hid_s) WinHttpCloseHandle(hid_s);

    release_native(n);
}

char *ol_native_strdup(const char *str) {
    return _strdup(str ? str : "");
}

void ol_native_free_string(char *str) {
    free(str);
}

// ============================================================================
// Windows Credential Manager (Advapi32 CredWriteW / CredReadW / CredDeleteW)
// ============================================================================

static wchar_t *make_cred_target(const char *address) {
    char *utf8 = alloc_printf("io.github.overlook.Windows:%s", address ? address : "");
    wchar_t *w = utf8_to_wide(utf8 ? utf8 : "io.github.overlook.Windows:");
    free(utf8);
    return w;
}

char *ol_wincred_lookup(const char *address, char **message) {
    if (message) *message = NULL;
    wchar_t *target = make_cred_target(address);
    PCREDENTIALW pcred = NULL;
    if (!CredReadW(target, CRED_TYPE_GENERIC, 0, &pcred)) {
        DWORD err = GetLastError();
        free(target);
        if (err == ERROR_NOT_FOUND) return NULL;
        if (message) *message = _strdup("Could not read credential from Windows Credential Manager.");
        return NULL;
    }
    free(target);
    char *val = (char *)calloc((size_t)pcred->CredentialBlobSize + 1, 1);
    if (val && pcred->CredentialBlob && pcred->CredentialBlobSize > 0) {
        memcpy(val, pcred->CredentialBlob, pcred->CredentialBlobSize);
    }
    CredFree(pcred);
    return val;
}

int ol_wincred_store(const char *address, const char *value, char **message) {
    if (message) *message = NULL;
    wchar_t *target = make_cred_target(address);
    CREDENTIALW cred = {0};
    cred.Type = CRED_TYPE_GENERIC;
    cred.TargetName = target;
    cred.Comment = L"Overlook KVM password";
    cred.CredentialBlobSize = (DWORD)(value ? strlen(value) : 0);
    cred.CredentialBlob = (LPBYTE)value;
    cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
    cred.UserName = L"Overlook";
    BOOL ok = CredWriteW(&cred, 0);
    free(target);
    if (!ok && message) {
        *message = _strdup("Could not store password in Windows Credential Manager.");
    }
    return ok ? 1 : 0;
}

int ol_wincred_clear(const char *address, char **message) {
    if (message) *message = NULL;
    wchar_t *target = make_cred_target(address);
    BOOL ok = CredDeleteW(target, CRED_TYPE_GENERIC, 0);
    DWORD err = GetLastError();
    free(target);
    if (!ok && err == ERROR_NOT_FOUND) return 1;
    if (!ok && message) {
        *message = _strdup("Could not remove password from Windows Credential Manager.");
    }
    return ok ? 1 : 0;
}

void ol_wincred_free(char *value) {
    if (!value) return;
    SecureZeroMemory(value, strlen(value));
    free(value);
}

// ============================================================================
// Windows Clipboard & UI Timer Helpers
// ============================================================================

char *ol_win_clipboard_get(void) {
    if (!OpenClipboard(NULL)) return _strdup("");
    HANDLE hData = GetClipboardData(CF_UNICODETEXT);
    if (!hData) {
        CloseClipboard();
        return _strdup("");
    }
    const wchar_t *wtext = (const wchar_t *)GlobalLock(hData);
    char *utf8 = wide_to_utf8(wtext);
    GlobalUnlock(hData);
    CloseClipboard();
    return utf8;
}

void ol_win_clipboard_set(const char *text) {
    if (!OpenClipboard(NULL)) return;
    EmptyClipboard();
    wchar_t *wtext = utf8_to_wide(text ? text : "");
    size_t bytes = (wcslen(wtext) + 1) * sizeof(wchar_t);
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (hMem) {
        void *ptr = GlobalLock(hMem);
        if (ptr) {
            memcpy(ptr, wtext, bytes);
            GlobalUnlock(hMem);
            if (!SetClipboardData(CF_UNICODETEXT, hMem)) {
                GlobalFree(hMem);
            }
        } else {
            GlobalFree(hMem);
        }
    }
    free(wtext);
    CloseClipboard();
}

uint32_t ol_win_timer_add(uint32_t interval_ms, OLWinTimerCallback callback, void *context) {
    ensure_msg_hwnd();
    uint32_t id = ++g_next_timer_id;
    TimerSlot *slot = (TimerSlot *)calloc(1, sizeof(TimerSlot));
    if (!slot) return 0;
    slot->id = id;
    slot->cb = callback;
    slot->ctx = context;
    slot->next = g_timers;
    g_timers = slot;
    SetTimer(g_msg_hwnd, (UINT_PTR)id, (UINT)interval_ms, NULL);
    return id;
}

void ol_win_timer_remove(uint32_t timer_id) {
    if (!timer_id) return;
    if (g_msg_hwnd) KillTimer(g_msg_hwnd, (UINT_PTR)timer_id);
    TimerSlot **pp = &g_timers;
    while (*pp) {
        if ((*pp)->id == timer_id) {
            TimerSlot *victim = *pp;
            *pp = victim->next;
            free(victim);
            return;
        }
        pp = &((*pp)->next);
    }
}

static int route_gui_message(MSG *msg);

int ol_win_run_message_loop(void) {
    ensure_msg_hwnd();
    HRESULT hrCom = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    MSG msg = {0};
    BOOL bRet;
    while ((bRet = GetMessageW(&msg, NULL, 0, 0)) != 0) {
        if (bRet == -1) break;
        if (route_gui_message(&msg)) continue;
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    if (SUCCEEDED(hrCom)) {
        CoUninitialize();
    }
    return (int)msg.wParam;
}

void ol_win_quit_message_loop(int exit_code) {
    PostQuitMessage(exit_code);
}

// ============================================================================
// Native Windows 11 DWM Mica / Fluent Win32 Desktop Window & Video Viewport
// ============================================================================

#define ID_BTN_NEW_CONN     2001
#define ID_BTN_REMOVE_DEV   2002
#define ID_LIST_DEVICES     2003
#define ID_EDIT_ADDRESS     2004
#define ID_EDIT_NAME        2005
#define ID_EDIT_USERNAME    2006
#define ID_EDIT_PASSWORD    2007
#define ID_EDIT_OTP         2008
#define ID_CHK_SAVEPASS     2009
#define ID_BTN_CONNECT      2010
#define ID_BTN_WEB          2011
#define ID_BTN_BOOKMARK     2012
#define ID_BTN_INFO         2013
#define ID_BTN_SETTINGS     2014
#define ID_BTN_SCREENSHOT   2015
#define ID_BTN_RECORD       2016
#define ID_BTN_OCR          2017
#define ID_BTN_PASTE        2018
#define ID_BTN_CAD          2019
#define ID_BTN_FULLSCREEN   2020
#define ID_BTN_DISCONNECT   2021
#define ID_BTN_SIDEBAR      2022

static HWND g_lbl_header_title = NULL;
static HWND g_lbl_header_sub = NULL;
static HWND g_lbl_status_toast = NULL;
static HWND g_btn_sidebar = NULL;
static HWND g_tooltip_hwnd = NULL;
static HWND g_list_devices = NULL;
static HWND g_btn_new_conn = NULL;
static HWND g_btn_remove_dev = NULL;
static HWND g_form_controls[24];
static int g_form_control_count = 0;
static HWND g_edit_address = NULL;
static HWND g_edit_name = NULL;
static HWND g_edit_username = NULL;
static HWND g_edit_password = NULL;
static HWND g_edit_otp = NULL;
static HWND g_chk_savepass = NULL;
static HWND g_btn_connect = NULL;
static HWND g_btn_web = NULL;
static HWND g_btn_bookmark = NULL;
static HWND g_btn_info = NULL;
static HWND g_btn_settings = NULL;
static HWND g_btn_screenshot = NULL;
static HWND g_btn_record = NULL;
static HWND g_btn_ocr = NULL;
static HWND g_btn_paste = NULL;
static HWND g_btn_cad = NULL;
static HWND g_btn_fullscreen = NULL;
static HWND g_btn_disconnect = NULL;

static HFONT g_font_regular = NULL;
static HFONT g_font_bold = NULL;
static HFONT g_font_title = NULL;
static HBRUSH g_brush_bg = NULL;
static HBRUSH g_brush_card = NULL;
static HBRUSH g_brush_input = NULL;
static HICON g_icon_small = NULL;
static HICON g_icon_large = NULL;

static OLWinUICommandCallback g_gui_cb = NULL;
static void *g_gui_ctx = NULL;
static OLNative *g_video_native = NULL;
static int g_is_session_mode = 0;
static int g_is_fullscreen = 0;
static int g_sidebar_visible = 1;
static WINDOWPLACEMENT g_prev_placement = { sizeof(WINDOWPLACEMENT) };
static int g_mouse_buttons_mask = 0;
static int g_last_list_sel = LB_ERR;
static ULONGLONG g_last_sel_ms = 0;

static UINT g_ui_dpi = 96;
static int g_color_scheme = 0;
static BOOL g_dark = FALSE, g_high_contrast = FALSE;
static COLORREF g_bg, g_card, g_input, g_text, g_muted, g_border, g_accent, g_accent_text;
static RECT g_connection_card;
static HWND g_sidebar_heading = NULL, g_empty_devices = NULL;

static int ui_px(int value) { return MulDiv(value, (int)g_ui_dpi, 96); }

static int sidebar_width(int logical_w) {
    if (g_is_fullscreen || !g_sidebar_visible) return 0;
    return logical_w < 1000 ? 208 : 248;
}

static void update_sidebar_button_state(void) {
    if (!g_btn_sidebar) return;
    SetWindowTextW(g_btn_sidebar, g_sidebar_visible ? L"Hide sidebar" : L"Show sidebar");
    if (g_tooltip_hwnd) {
        TOOLINFOW ti = {0};
        ti.cbSize = sizeof(ti);
        ti.hwnd = g_main_hwnd;
        ti.uId = (UINT_PTR)g_btn_sidebar;
        ti.lpszText = g_sidebar_visible ? L"Hide sidebar (Ctrl+B)" : L"Show sidebar (Ctrl+B)";
        SendMessageW(g_tooltip_hwnd, TTM_UPDATETIPTEXTW, 0, (LPARAM)&ti);
    }
    InvalidateRect(g_btn_sidebar, NULL, FALSE);
}

static void place(HWND control, int x, int y, int width, int height) {
    MoveWindow(control, ui_px(x), ui_px(y + (g_is_fullscreen ? 0 : 40)), ui_px(width), ui_px(height), TRUE);
}

static void rounded(HDC dc, RECT rc, COLORREF fill, COLORREF border, int radius) {
    HBRUSH brush = CreateSolidBrush(fill);
    HPEN pen = CreatePen(PS_SOLID, 1, border);
    HGDIOBJ oldBrush = SelectObject(dc, brush);
    HGDIOBJ oldPen = SelectObject(dc, pen);
    RoundRect(dc, rc.left, rc.top, rc.right, rc.bottom, ui_px(radius), ui_px(radius));
    SelectObject(dc, oldBrush);
    SelectObject(dc, oldPen);
    DeleteObject(brush);
    DeleteObject(pen);
}

static void refresh_theme(void) {
    DWORD light = 1, size = sizeof(light);
    RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                 L"AppsUseLightTheme", RRF_RT_REG_DWORD, NULL, &light, &size);
    HIGHCONTRASTW hc = { sizeof(hc) };
    SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(hc), &hc, 0);
    g_high_contrast = (hc.dwFlags & HCF_HIGHCONTRASTON) != 0;
    g_dark = g_color_scheme == 2 || (g_color_scheme == 0 && !light);
    g_bg = g_dark ? RGB(32, 32, 32) : RGB(243, 243, 243);
    g_card = g_dark ? RGB(39, 39, 39) : RGB(255, 255, 255);
    g_input = g_dark ? RGB(48, 48, 48) : RGB(250, 250, 250);
    g_text = g_dark ? RGB(245, 245, 245) : RGB(26, 26, 26);
    g_muted = g_dark ? RGB(178, 178, 178) : RGB(96, 96, 96);
    g_border = g_dark ? RGB(65, 65, 65) : RGB(222, 222, 222);
    g_accent = g_dark ? RGB(96, 205, 255) : RGB(0, 103, 192);
    g_accent_text = g_dark ? RGB(0, 40, 60) : RGB(255, 255, 255);
    if (g_high_contrast) {
        g_bg = g_card = g_input = GetSysColor(COLOR_WINDOW);
        g_text = g_muted = GetSysColor(COLOR_WINDOWTEXT);
        g_border = GetSysColor(COLOR_WINDOWTEXT);
        g_accent = GetSysColor(COLOR_HIGHLIGHT);
        g_accent_text = GetSysColor(COLOR_HIGHLIGHTTEXT);
    }
    if (g_brush_bg) DeleteObject(g_brush_bg);
    if (g_brush_card) DeleteObject(g_brush_card);
    if (g_brush_input) DeleteObject(g_brush_input);
    g_brush_bg = CreateSolidBrush(g_bg);
    g_brush_card = CreateSolidBrush(g_card);
    g_brush_input = CreateSolidBrush(g_input);
    if (g_main_hwnd) {
        DwmSetWindowAttribute(g_main_hwnd, 20, &g_dark, sizeof(g_dark));
        int backdrop = g_high_contrast ? 1 : 2, corners = 2;
        DwmSetWindowAttribute(g_main_hwnd, 38, &backdrop, sizeof(backdrop));
        DwmSetWindowAttribute(g_main_hwnd, 33, &corners, sizeof(corners));
        RedrawWindow(g_main_hwnd, NULL, NULL, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN);
    }
}

void ol_win_gui_set_color_scheme(int scheme) {
    g_color_scheme = scheme;
    refresh_theme();
}

static BOOL CALLBACK apply_font(HWND child, LPARAM unused) {
    (void)unused;
    HFONT font = child == g_form_controls[0] ? g_font_title :
        (child == g_lbl_header_title || child == g_sidebar_heading || child == g_btn_connect) ? g_font_bold : g_font_regular;
    SendMessageW(child, WM_SETFONT, (WPARAM)font, TRUE);
    return TRUE;
}

static void refresh_fonts(void) {
    HFONT oldRegular = g_font_regular, oldBold = g_font_bold, oldTitle = g_font_title;
    g_font_regular = CreateFontW(-ui_px(14), 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_font_bold = CreateFontW(-ui_px(14), 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    g_font_title = CreateFontW(-ui_px(28), 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET, 0, 0, CLEARTYPE_QUALITY, 0, L"Segoe UI");
    if (g_main_hwnd) EnumChildWindows(g_main_hwnd, apply_font, 0);
    if (oldRegular) DeleteObject(oldRegular);
    if (oldBold) DeleteObject(oldBold);
    if (oldTitle) DeleteObject(oldTitle);
    if (g_list_devices) SendMessageW(g_list_devices, LB_SETITEMHEIGHT, 0, ui_px(60));
}

static LRESULT CALLBACK fluent_control_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR id, DWORD_PTR data) {
    (void)id;
    (void)data;
    if (hwnd == g_chk_savepass && msg == WM_PAINT) {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        RECT rc;
        GetClientRect(hwnd, &rc);
        FillRect(dc, &rc, g_brush_card);
        BOOL checked = SendMessageW(hwnd, BM_GETCHECK, 0, 0) == BST_CHECKED;
        RECT box = { ui_px(1), ui_px(3), ui_px(19), ui_px(21) };
        rounded(dc, box, checked ? g_accent : g_input, checked ? g_accent : g_border, 4);
        if (checked) {
            HPEN pen = CreatePen(PS_SOLID, ui_px(2), g_accent_text);
            HGDIOBJ oldPen = SelectObject(dc, pen);
            MoveToEx(dc, ui_px(5), ui_px(12), NULL);
            LineTo(dc, ui_px(9), ui_px(16));
            LineTo(dc, ui_px(15), ui_px(8));
            SelectObject(dc, oldPen);
            DeleteObject(pen);
        }
        wchar_t label[128] = {0};
        GetWindowTextW(hwnd, label, 128);
        rc.left = ui_px(28);
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, g_text);
        HGDIOBJ oldFont = SelectObject(dc, g_font_regular);
        DrawTextW(dc, label, -1, &rc, DT_SINGLELINE | DT_VCENTER);
        SelectObject(dc, oldFont);
        if (GetFocus() == hwnd) DrawFocusRect(dc, &rc);
        EndPaint(hwnd, &ps);
        return 0;
    }
    if (msg == WM_MOUSEMOVE) {
        if (!GetPropW(hwnd, L"OverlookHover")) {
            SetPropW(hwnd, L"OverlookHover", (HANDLE)1);
            TRACKMOUSEEVENT track = { sizeof(track), TME_LEAVE, hwnd, 0 };
            TrackMouseEvent(&track);
            InvalidateRect(hwnd, NULL, FALSE);
        }
    } else if (msg == WM_MOUSELEAVE) {
        RemovePropW(hwnd, L"OverlookHover");
        InvalidateRect(hwnd, NULL, FALSE);
    } else if (msg == WM_SETFOCUS || msg == WM_KILLFOCUS || msg == WM_ENABLE) {
        InvalidateRect(hwnd, NULL, FALSE);
        if (g_main_hwnd) InvalidateRect(g_main_hwnd, NULL, FALSE);
    } else if (msg == WM_NCDESTROY) {
        RemovePropW(hwnd, L"OverlookHover");
        RemoveWindowSubclass(hwnd, fluent_control_proc, 1);
    }
    return DefSubclassProc(hwnd, msg, wp, lp);
}

static BOOL CALLBACK style_control(HWND child, LPARAM unused) {
    (void)unused;
    wchar_t cls[32] = {0};
    GetClassNameW(child, cls, 32);
    if (_wcsicmp(cls, L"BUTTON") == 0) {
        LONG_PTR style = GetWindowLongPtrW(child, GWL_STYLE);
        if ((style & BS_TYPEMASK) != BS_AUTOCHECKBOX) {
            SetWindowLongPtrW(child, GWL_STYLE, (style & ~BS_TYPEMASK) | BS_OWNERDRAW | WS_TABSTOP);
        }
        SetWindowSubclass(child, fluent_control_proc, 1, 0);
    } else if (_wcsicmp(cls, L"EDIT") == 0) {
        SetWindowLongPtrW(child, GWL_EXSTYLE, GetWindowLongPtrW(child, GWL_EXSTYLE) & ~WS_EX_CLIENTEDGE);
        SetWindowPos(child, NULL, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
        SendMessageW(child, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, MAKELPARAM(ui_px(10), ui_px(10)));
        SetWindowSubclass(child, fluent_control_proc, 1, 0);
    }
    return TRUE;
}

static void draw_control(const DRAWITEMSTRUCT *draw) {
    HDC dc = draw->hDC;
    RECT rc = draw->rcItem;
    SetBkMode(dc, TRANSPARENT);
    if (draw->CtlType == ODT_LISTBOX) {
        FillRect(dc, &rc, g_brush_bg);
        if (draw->itemID == (UINT)-1) return;
        BOOL selected = (draw->itemState & ODS_SELECTED) != 0;
        RECT tile = rc;
        InflateRect(&tile, -ui_px(2), -ui_px(3));
        if (selected) {
            rounded(dc, tile, g_card, g_border, 8);
            RECT marker = { tile.left, tile.top + ui_px(12), tile.left + ui_px(3), tile.bottom - ui_px(12) };
            rounded(dc, marker, g_accent, g_accent, 3);
        }
        int len = (int)SendMessageW(draw->hwndItem, LB_GETTEXTLEN, draw->itemID, 0);
        if (len < 0) return;
        wchar_t *label = (wchar_t *)calloc((size_t)len + 1, sizeof(wchar_t));
        if (!label) return;
        SendMessageW(draw->hwndItem, LB_GETTEXT, draw->itemID, (LPARAM)label);
        wchar_t *host = wcschr(label, L'\n');
        if (host) *host++ = 0;
        RECT text = { tile.left + ui_px(16), tile.top + ui_px(7), tile.right - ui_px(10), tile.top + ui_px(29) };
        HGDIOBJ oldFont = SelectObject(dc, g_font_bold);
        SetTextColor(dc, g_text);
        DrawTextW(dc, label, -1, &text, DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        if (host) {
            OffsetRect(&text, 0, ui_px(22));
            SelectObject(dc, g_font_regular);
            SetTextColor(dc, g_muted);
            DrawTextW(dc, host, -1, &text, DT_SINGLELINE | DT_END_ELLIPSIS | DT_NOPREFIX);
        }
        SelectObject(dc, oldFont);
        free(label);
        if (draw->itemState & ODS_FOCUS) {
            InflateRect(&tile, -2, -2);
            DrawFocusRect(dc, &tile);
        }
        return;
    }

    BOOL primary = draw->hwndItem == g_btn_connect;
    BOOL disabled = (draw->itemState & ODS_DISABLED) != 0;
    BOOL hover = GetPropW(draw->hwndItem, L"OverlookHover") != NULL;
    COLORREF fill = primary ? g_accent : g_card;
    if (!primary && hover) fill = g_input;
    if (draw->itemState & ODS_SELECTED) fill = g_border;
    FillRect(dc, &rc,
             (draw->hwndItem == g_btn_connect || draw->hwndItem == g_btn_web || draw->hwndItem == g_btn_bookmark)
                 ? g_brush_card : g_brush_bg);
    InflateRect(&rc, -1, -1);
    rounded(dc, rc, fill, primary ? g_accent : g_border, 8);
    if (draw->hwndItem == g_btn_sidebar) {
        int cx = (rc.left + rc.right) / 2;
        int cy = (rc.top + rc.bottom) / 2;
        int left = cx - ui_px(8);
        int right = cx + ui_px(8);
        int top = cy - ui_px(6);
        int bottom = cy + ui_px(6);
        int splitX = left + ui_px(5);
        int stroke = ui_px(1);
        if (stroke < 1) stroke = 1;
        COLORREF fg = disabled ? g_muted : g_text;

        if (g_sidebar_visible) {
            RECT pane = { left + stroke, top + stroke, splitX, bottom - stroke };
            HBRUSH paneBrush = CreateSolidBrush(fg);
            FillRect(dc, &pane, paneBrush);
            DeleteObject(paneBrush);
        }

        HPEN pen = CreatePen(PS_SOLID, stroke, fg);
        HGDIOBJ oldPen = SelectObject(dc, pen);
        MoveToEx(dc, splitX, top, NULL);
        LineTo(dc, splitX, bottom);
        SelectObject(dc, oldPen);
        DeleteObject(pen);

        HPEN framePen = CreatePen(PS_INSIDEFRAME, stroke, fg);
        oldPen = SelectObject(dc, framePen);
        HGDIOBJ oldBrush = SelectObject(dc, GetStockObject(HOLLOW_BRUSH));
        RoundRect(dc, left, top, right, bottom, ui_px(3), ui_px(3));
        SelectObject(dc, oldBrush);
        SelectObject(dc, oldPen);
        DeleteObject(framePen);
    } else {
        wchar_t label[128] = {0};
        GetWindowTextW(draw->hwndItem, label, 128);
        HGDIOBJ oldFont = SelectObject(dc, primary ? g_font_bold : g_font_regular);
        SetTextColor(dc, disabled ? g_muted : primary ? g_accent_text : g_text);
        DrawTextW(dc, label, -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
        SelectObject(dc, oldFont);
    }
    if (draw->itemState & ODS_FOCUS) {
        InflateRect(&rc, -ui_px(3), -ui_px(3));
        DrawFocusRect(dc, &rc);
    }
}

static void video_frame_render_cb(const uint8_t *bgra, int width, int height, int stride, void *context) {
    (void)bgra; (void)width; (void)height; (void)stride; (void)context;
    if (g_video_hwnd && IsWindowVisible(g_video_hwnd)) {
        InvalidateRect(g_video_hwnd, NULL, FALSE);
    }
}

static void release_captured_mouse_buttons(HWND hwnd) {
    OLNative *n = g_video_native;
    if (g_mouse_buttons_mask && n && InterlockedCompareExchange(&n->active, 0, 0)) {
        for (int b = 1; b <= 9; b++) {
            if (g_mouse_buttons_mask & (1 << b)) {
                ol_native_emit_input(n, OL_INPUT_BUTTON_UP, b, 0.0, 0.0);
            }
        }
    }
    g_mouse_buttons_mask = 0;
    if (GetCapture() == hwnd) {
        ReleaseCapture();
    }
}

static LRESULT CALLBACK video_wnd_proc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    OLNative *n = g_video_native;
    int is_active = (n && InterlockedCompareExchange(&n->active, 0, 0) != 0);

    switch (msg) {
    case WM_ERASEBKGND:
        return 1;
    case WM_SIZE: {
        int w = LOWORD(lParam);
        int h = HIWORD(lParam);
        if (is_active && w > 0 && h > 0) {
            ol_native_set_widget_size(n, (double)w, (double)h);
        }
        InvalidateRect(hwnd, NULL, FALSE);
        return 0;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC hdc = BeginPaint(hwnd, &ps);
        RECT rc;
        GetClientRect(hwnd, &rc);
        int cw = rc.right - rc.left;
        int ch = rc.bottom - rc.top;
        HBRUSH black = (HBRUSH)GetStockObject(BLACK_BRUSH);
        int painted = 0;

        if (is_active && cw > 0 && ch > 0) {
            EnterCriticalSection(&n->lock);
            int fw = n->last_frame_width;
            int fh = n->last_frame_height;
            const uint8_t *pixels = n->last_frame_bytes;
            if (pixels && fw > 0 && fh > 0) {
                double scaleX = (double)cw / (double)fw;
                double scaleY = (double)ch / (double)fh;
                double scale = scaleX < scaleY ? scaleX : scaleY;
                int dw = (int)(fw * scale);
                int dh = (int)(fh * scale);
                int dx = (cw - dw) / 2;
                int dy = (ch - dh) / 2;

                if (dy > 0) {
                    RECT topBar = { 0, 0, cw, dy };
                    RECT botBar = { 0, dy + dh, cw, ch };
                    FillRect(hdc, &topBar, black);
                    FillRect(hdc, &botBar, black);
                }
                if (dx > 0) {
                    RECT leftBar = { 0, 0, dx, ch };
                    RECT rightBar = { dx + dw, 0, cw, ch };
                    FillRect(hdc, &leftBar, black);
                    FillRect(hdc, &rightBar, black);
                }

                BITMAPINFO bmi;
                ZeroMemory(&bmi, sizeof(bmi));
                bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
                bmi.bmiHeader.biWidth = fw;
                bmi.bmiHeader.biHeight = -fh;
                bmi.bmiHeader.biPlanes = 1;
                bmi.bmiHeader.biBitCount = 32;
                bmi.bmiHeader.biCompression = BI_RGB;

                SetStretchBltMode(hdc, HALFTONE);
                SetBrushOrgEx(hdc, 0, 0, NULL);
                StretchDIBits(hdc, dx, dy, dw, dh, 0, 0, fw, fh, pixels, &bmi, DIB_RGB_COLORS, SRCCOPY);
                painted = 1;
            }
            LeaveCriticalSection(&n->lock);
        }

        if (!painted) {
            FillRect(hdc, &rc, black);
            SetBkMode(hdc, TRANSPARENT);
            SetTextColor(hdc, RGB(180, 188, 200));
            HGDIOBJ oldFont = SelectObject(hdc, g_font_regular ? g_font_regular : GetStockObject(DEFAULT_GUI_FONT));
            DrawTextW(hdc, L"Waiting for KVM video stream\u2026 (Click inside viewport to capture keyboard)",
                      -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
            SelectObject(hdc, oldFont);
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_LBUTTONDOWN:
        SetFocus(hwnd);
        if (GetCapture() != hwnd) SetCapture(hwnd);
        g_mouse_buttons_mask |= (1 << 1);
        if (is_active) {
            ol_native_focus(n, 1);
            ol_native_emit_input(n, OL_INPUT_BUTTON_DOWN, 1, (double)GET_X_LPARAM(lParam), (double)GET_Y_LPARAM(lParam));
        }
        return 0;
    case WM_LBUTTONUP:
        g_mouse_buttons_mask &= ~(1 << 1);
        if (g_mouse_buttons_mask == 0 && GetCapture() == hwnd) ReleaseCapture();
        if (is_active) {
            ol_native_emit_input(n, OL_INPUT_BUTTON_UP, 1, (double)GET_X_LPARAM(lParam), (double)GET_Y_LPARAM(lParam));
        }
        return 0;
    case WM_MBUTTONDOWN:
        SetFocus(hwnd);
        if (GetCapture() != hwnd) SetCapture(hwnd);
        g_mouse_buttons_mask |= (1 << 2);
        if (is_active) {
            ol_native_emit_input(n, OL_INPUT_BUTTON_DOWN, 2, (double)GET_X_LPARAM(lParam), (double)GET_Y_LPARAM(lParam));
        }
        return 0;
    case WM_MBUTTONUP:
        g_mouse_buttons_mask &= ~(1 << 2);
        if (g_mouse_buttons_mask == 0 && GetCapture() == hwnd) ReleaseCapture();
        if (is_active) {
            ol_native_emit_input(n, OL_INPUT_BUTTON_UP, 2, (double)GET_X_LPARAM(lParam), (double)GET_Y_LPARAM(lParam));
        }
        return 0;
    case WM_RBUTTONDOWN:
        SetFocus(hwnd);
        if (GetCapture() != hwnd) SetCapture(hwnd);
        g_mouse_buttons_mask |= (1 << 3);
        if (is_active) {
            ol_native_emit_input(n, OL_INPUT_BUTTON_DOWN, 3, (double)GET_X_LPARAM(lParam), (double)GET_Y_LPARAM(lParam));
        }
        return 0;
    case WM_RBUTTONUP:
        g_mouse_buttons_mask &= ~(1 << 3);
        if (g_mouse_buttons_mask == 0 && GetCapture() == hwnd) ReleaseCapture();
        if (is_active) {
            ol_native_emit_input(n, OL_INPUT_BUTTON_UP, 3, (double)GET_X_LPARAM(lParam), (double)GET_Y_LPARAM(lParam));
        }
        return 0;
    case WM_XBUTTONDOWN: {
        int btn = (GET_XBUTTON_WPARAM(wParam) == XBUTTON1) ? 4 : 5;
        SetFocus(hwnd);
        if (GetCapture() != hwnd) SetCapture(hwnd);
        g_mouse_buttons_mask |= (1 << btn);
        if (is_active) {
            ol_native_emit_input(n, OL_INPUT_BUTTON_DOWN, btn, (double)GET_X_LPARAM(lParam), (double)GET_Y_LPARAM(lParam));
        }
        return TRUE;
    }
    case WM_XBUTTONUP: {
        int btn = (GET_XBUTTON_WPARAM(wParam) == XBUTTON1) ? 4 : 5;
        g_mouse_buttons_mask &= ~(1 << btn);
        if (g_mouse_buttons_mask == 0 && GetCapture() == hwnd) ReleaseCapture();
        if (is_active) {
            ol_native_emit_input(n, OL_INPUT_BUTTON_UP, btn, (double)GET_X_LPARAM(lParam), (double)GET_Y_LPARAM(lParam));
        }
        return TRUE;
    }
    case WM_MOUSEMOVE:
        if (is_active) {
            ol_native_emit_input(n, OL_INPUT_MOTION, 0, (double)GET_X_LPARAM(lParam), (double)GET_Y_LPARAM(lParam));
        }
        return 0;
    case WM_MOUSEWHEEL:
        if (is_active) {
            double dy = (double)GET_WHEEL_DELTA_WPARAM(wParam) / (double)WHEEL_DELTA;
            ol_native_emit_input(n, OL_INPUT_SCROLL, 0, 0.0, dy);
        }
        return 0;
    case WM_MOUSEHWHEEL:
        if (is_active) {
            double dx = (double)GET_WHEEL_DELTA_WPARAM(wParam) / (double)WHEEL_DELTA;
            ol_native_emit_input(n, OL_INPUT_SCROLL, 0, dx, 0.0);
        }
        return 0;
    case WM_CAPTURECHANGED:
        if ((HWND)lParam != hwnd) {
            release_captured_mouse_buttons(hwnd);
        }
        return 0;
    case WM_SETFOCUS:
        if (is_active) ol_native_focus(n, 1);
        return 0;
    case WM_KILLFOCUS:
        release_captured_mouse_buttons(hwnd);
        if (is_active) ol_native_focus(n, 0);
        return 0;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
        if (is_active) {
            int scan = (int)((lParam >> 16) & 0xFF);
            int ext = (lParam & (1 << 24)) ? 0x100 : 0;
            ol_native_emit_input(n, OL_INPUT_KEY_DOWN, scan | ext, 0, 0);
            return 0;
        }
        break;
    case WM_KEYUP:
    case WM_SYSKEYUP:
        if (is_active) {
            int scan = (int)((lParam >> 16) & 0xFF);
            int ext = (lParam & (1 << 24)) ? 0x100 : 0;
            ol_native_emit_input(n, OL_INPUT_KEY_UP, scan | ext, 0, 0);
            return 0;
        }
        break;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

static int route_gui_message(MSG *msg) {
    if (!g_main_hwnd) return 0;
    if (msg->message == WM_KEYDOWN && !g_captured_native && msg->wParam == VK_F11) {
        ol_win_gui_set_fullscreen(!g_is_fullscreen);
        return 1;
    }
    if (g_is_session_mode && GetFocus() == g_video_hwnd) return 0;
    if (msg->message == WM_KEYDOWN && !g_captured_native && !g_is_fullscreen &&
        (msg->hwnd == g_main_hwnd || IsChild(g_main_hwnd, msg->hwnd)) &&
        msg->wParam == 'B' &&
        (GetKeyState(VK_CONTROL) & 0x8000) &&
        !(GetKeyState(VK_MENU) & 0x8000) &&
        !(GetKeyState(VK_SHIFT) & 0x8000) &&
        (msg->lParam & (1u << 30)) == 0) {
        SendMessageW(g_main_hwnd, WM_COMMAND, ID_BTN_SIDEBAR, 0);
        return 1;
    }
    if (msg->message == WM_KEYDOWN && msg->wParam == VK_RETURN && !g_is_session_mode) {
        wchar_t cls[32] = {0};
        HWND focused = GetFocus();
        if (focused && GetClassNameW(focused, cls, 32) && _wcsicmp(cls, L"EDIT") == 0) {
            SendMessageW(g_main_hwnd, WM_COMMAND, ID_BTN_CONNECT, 0);
            return 1;
        }
    }
    return IsDialogMessageW(g_main_hwnd, msg);
}

static void layout_main_window(HWND hwnd) {
    if (!hwnd) return;
    RECT rc;
    GetClientRect(hwnd, &rc);
    int w = MulDiv(rc.right, 96, (int)g_ui_dpi);
    int h = MulDiv(rc.bottom, 96, (int)g_ui_dpi) - (g_is_fullscreen ? 0 : 40);
    if (w <= 0 || h <= 0 || !g_btn_connect) return;
    int sidebar = sidebar_width(w);
    int header = g_is_fullscreen ? 0 : 76, footer = g_is_fullscreen ? 0 : 36;
    int showChrome = g_is_fullscreen ? SW_HIDE : SW_SHOW;
    int showSidebar = (!g_is_fullscreen && g_sidebar_visible) ? SW_SHOW : SW_HIDE;
    HWND sidebarControls[] = {
        g_sidebar_heading, g_btn_new_conn, g_btn_remove_dev, g_list_devices
    };
    for (int i = 0; i < 4; i++) ShowWindow(sidebarControls[i], showSidebar);
    ShowWindow(g_empty_devices,
               (!g_is_fullscreen && g_sidebar_visible && SendMessageW(g_list_devices, LB_GETCOUNT, 0, 0) == 0)
                   ? SW_SHOW : SW_HIDE);
    EnableWindow(g_btn_remove_dev, SendMessageW(g_list_devices, LB_GETCURSEL, 0, 0) != LB_ERR);

    HWND chromeControls[] = {
        g_btn_sidebar, g_lbl_header_title, g_lbl_header_sub, g_lbl_status_toast,
        g_btn_settings, g_btn_info
    };
    for (int i = 0; i < 6; i++) ShowWindow(chromeControls[i], showChrome);

    place(g_btn_sidebar, 16, 20, 36, 36);
    if (sidebar > 0) {
        place(g_sidebar_heading, 64, 20, sidebar - 80, 36);
        place(g_btn_new_conn, 16, 76, sidebar - 32, 36);
        place(g_list_devices, 12, 128, sidebar - 24, h - 228);
        place(g_empty_devices, 24, 148, sidebar - 48, 80);
        place(g_btn_remove_dev, 16, h - 88, sidebar - 32, 36);
    }
    int headerLeft = sidebar > 0 ? sidebar + 28 : 64;
    int headerWidth = w - headerLeft - 212;
    if (headerWidth < 0) headerWidth = 0;
    place(g_lbl_header_title, headerLeft, 17, headerWidth, 24);
    place(g_lbl_header_sub, headerLeft, 43, headerWidth, 20);
    place(g_lbl_status_toast, 24, h - 28, w - 48, 22);
    place(g_btn_settings, w - 112, 20, 88, 36);
    place(g_btn_info, w - 192, 20, 72, 36);

    HWND commands[] = {
        g_btn_screenshot, g_btn_record, g_btn_ocr, g_btn_paste,
        g_btn_cad, g_btn_fullscreen, g_btn_disconnect
    };
    int widths[] = { 88, 72, 60, 64, 104, 92, 100 };
    int x = sidebar + 20, y = header + 12, toolbar = 0;
    for (int i = 0; i < 7; i++) {
        ShowWindow(commands[i], g_is_session_mode && !g_is_fullscreen ? SW_SHOW : SW_HIDE);
        if (x + widths[i] > w - 20) {
            x = sidebar + 20;
            y += 44;
        }
        place(commands[i], x, y, widths[i], 34);
        x += widths[i] + 8;
    }
    if (g_is_session_mode && !g_is_fullscreen) toolbar = y - header + 48;
    ShowWindow(g_video_hwnd, g_is_session_mode ? SW_SHOW : SW_HIDE);
    for (int i = 0; i < g_form_control_count; i++) {
        ShowWindow(g_form_controls[i], g_is_session_mode ? SW_HIDE : SW_SHOW);
    }
    if (g_is_session_mode) {
        place(g_video_hwnd, sidebar, header + toolbar, w - sidebar, h - header - toolbar - footer);
        SetRectEmpty(&g_connection_card);
    } else {
        int cardW = w - sidebar - 48;
        if (cardW > 568) cardW = 568;
        int cardH = 484, cx = sidebar + (w - sidebar - cardW) / 2;
        int cy = header + (h - header - footer - cardH) / 2;
        if (cy < header + 12) cy = header + 12;
        SetRect(&g_connection_card, ui_px(cx), ui_px(cy + (g_is_fullscreen ? 0 : 40)),
                ui_px(cx + cardW), ui_px(cy + cardH + (g_is_fullscreen ? 0 : 40)));
        int fx = cx + 28, fy = cy + 24, fw = cardW - 56, half = (fw - 16) / 2;
        place(g_form_controls[0], fx, fy, fw, 38);
        place(g_form_controls[1], fx, fy + 44, fw, 40);
        place(g_form_controls[2], fx, fy + 100, fw, 20);
        place(g_edit_address, fx, fy + 124, fw, 28);
        place(g_form_controls[4], fx, fy + 164, fw, 20);
        place(g_edit_name, fx, fy + 188, fw - 112, 28);
        place(g_btn_bookmark, fx + fw - 104, fy + 184, 104, 36);
        place(g_form_controls[7], fx, fy + 232, half, 20);
        place(g_edit_username, fx, fy + 256, half, 28);
        place(g_form_controls[9], fx + half + 16, fy + 232, half, 20);
        place(g_edit_password, fx + half + 16, fy + 256, half, 28);
        place(g_form_controls[11], fx, fy + 296, fw, 20);
        place(g_edit_otp, fx, fy + 320, fw, 28);
        place(g_chk_savepass, fx, fy + 360, fw, 24);
        place(g_btn_connect, fx, fy + 400, half, 36);
        place(g_btn_web, fx + half + 16, fy + 400, half, 36);
    }
    InvalidateRect(hwnd, NULL, FALSE);
}

static int g_caption_hover = 0;

static int caption_hit(HWND hwnd, LPARAM position) {
    POINT point = { GET_X_LPARAM(position), GET_Y_LPARAM(position) };
    ScreenToClient(hwnd, &point);
    RECT rc;
    GetClientRect(hwnd, &rc);
    int x = point.x, y = point.y, edge = ui_px(6);
    if (!IsZoomed(hwnd)) {
        BOOL left = x < edge, right = x >= rc.right - edge, top = y < edge, bottom = y >= rc.bottom - edge;
        if (top && left) return HTTOPLEFT;
        if (top && right) return HTTOPRIGHT;
        if (bottom && left) return HTBOTTOMLEFT;
        if (bottom && right) return HTBOTTOMRIGHT;
        if (top) return HTTOP;
        if (bottom) return HTBOTTOM;
        if (left) return HTLEFT;
        if (right) return HTRIGHT;
    }
    if (y < ui_px(40)) {
        if (x >= rc.right - ui_px(46)) return HTCLOSE;
        if (x >= rc.right - ui_px(92)) return HTMAXBUTTON;
        if (x >= rc.right - ui_px(138)) return HTMINBUTTON;
        if (x < ui_px(40)) return HTSYSMENU;
        return HTCAPTION;
    }
    return HTCLIENT;
}

static void paint_caption(HWND hwnd, HDC dc, RECT client) {
    HICON icon = (HICON)SendMessageW(hwnd, WM_GETICON, ICON_SMALL, 0);
    if (!icon) icon = (HICON)GetClassLongPtrW(hwnd, GCLP_HICONSM);
    if (icon) {
        DrawIconEx(dc, ui_px(14), ui_px(10), icon, ui_px(20), ui_px(20), 0, NULL, DI_NORMAL);
    }
    RECT title = { ui_px(44), 0, client.right - ui_px(150), ui_px(40) };
    HGDIOBJ oldFont = SelectObject(dc, g_font_regular);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, g_text);
    DrawTextW(dc, L"Overlook", -1, &title, DT_SINGLELINE | DT_VCENTER | DT_END_ELLIPSIS);
    SelectObject(dc, oldFont);

    int hits[] = { HTMINBUTTON, HTMAXBUTTON, HTCLOSE };
    for (int i = 0; i < 3; i++) {
        RECT button = { client.right - ui_px((3 - i) * 46), 0, client.right - ui_px((2 - i) * 46), ui_px(40) };
        BOOL hot = g_caption_hover == hits[i];
        if (hot) {
            HBRUSH brush = CreateSolidBrush(i == 2 ? RGB(196, 43, 28) : g_border);
            FillRect(dc, &button, brush);
            DeleteObject(brush);
        }
        int cx = (button.left + button.right) / 2, cy = ui_px(20), r = ui_px(5);
        HPEN pen = CreatePen(PS_SOLID, ui_px(1), hot && i == 2 ? RGB(255, 255, 255) : g_text);
        HGDIOBJ oldPen = SelectObject(dc, pen);
        HGDIOBJ oldBrush = SelectObject(dc, GetStockObject(HOLLOW_BRUSH));
        if (i == 0) {
            MoveToEx(dc, cx - r, cy, NULL);
            LineTo(dc, cx + r, cy);
        }
        if (i == 1) {
            if (IsZoomed(hwnd)) {
                int off = ui_px(2);
                Rectangle(dc, cx - r + off, cy - r - off, cx + r + off, cy + r - off);
                RECT front = { cx - r, cy - r, cx + r, cy + r };
                FillRect(dc, &front, g_brush_bg);
            }
            Rectangle(dc, cx - r, cy - r, cx + r, cy + r);
        }
        if (i == 2) {
            MoveToEx(dc, cx - r, cy - r, NULL); LineTo(dc, cx + r, cy + r);
            MoveToEx(dc, cx + r, cy - r, NULL); LineTo(dc, cx - r, cy + r);
        }
        SelectObject(dc, oldPen);
        SelectObject(dc, oldBrush);
        DeleteObject(pen);
    }
}

static void paint_main_surface(HWND hwnd, HDC dc, RECT client) {
    FillRect(dc, &client, g_brush_bg);
    if (!g_is_fullscreen) paint_caption(hwnd, dc, client);
    if (!g_is_session_mode && !IsRectEmpty(&g_connection_card)) {
        rounded(dc, g_connection_card, g_card, g_border, 16);
    }
    int sidebar = sidebar_width(MulDiv(client.right, 96, (int)g_ui_dpi));
    if (sidebar > 0) {
        HPEN pen = CreatePen(PS_SOLID, 1, g_border);
        HGDIOBJ oldPen = SelectObject(dc, pen);
        MoveToEx(dc, ui_px(sidebar), ui_px(52), NULL);
        LineTo(dc, ui_px(sidebar), client.bottom - ui_px(48));
        SelectObject(dc, oldPen);
        DeleteObject(pen);
    }
    if (!g_is_session_mode) {
        HWND edits[] = { g_edit_address, g_edit_name, g_edit_username, g_edit_password, g_edit_otp };
        for (int i = 0; i < 5; i++) {
            if (!edits[i]) continue;
            RECT r;
            GetWindowRect(edits[i], &r);
            MapWindowPoints(NULL, hwnd, (POINT *)&r, 2);
            InflateRect(&r, ui_px(1), ui_px(4));
            rounded(dc, r, g_input, GetFocus() == edits[i] ? g_accent : g_border, 6);
        }
    }
}

static LRESULT CALLBACK main_wnd_proc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
    switch (msg) {
    case WM_NCCALCSIZE:
        if (wParam && !g_is_fullscreen) {
            if (IsZoomed(hwnd)) {
                RECT *r = &((NCCALCSIZE_PARAMS *)lParam)->rgrc[0];
                MONITORINFO mi = { sizeof(mi) };
                GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mi);
                *r = mi.rcWork;
            }
            return 0;
        }
        break;
    case WM_NCHITTEST:
        if (!g_is_fullscreen) return caption_hit(hwnd, lParam);
        break;
    case WM_NCMOUSEMOVE:
        if (!g_is_fullscreen) {
            int hit = (int)wParam;
            if (g_caption_hover != hit) {
                g_caption_hover = hit;
                InvalidateRect(hwnd, NULL, FALSE);
            }
            TRACKMOUSEEVENT track = { sizeof(track), TME_LEAVE | TME_NONCLIENT, hwnd, 0 };
            TrackMouseEvent(&track);
        }
        break;
    case WM_NCMOUSELEAVE:
        g_caption_hover = 0;
        InvalidateRect(hwnd, NULL, FALSE);
        break;
    case WM_NCLBUTTONDOWN:
        if (wParam == HTCLOSE || wParam == HTMAXBUTTON || wParam == HTMINBUTTON) return 0;
        break;
    case WM_NCLBUTTONUP:
        if (wParam == HTCLOSE || wParam == HTMAXBUTTON || wParam == HTMINBUTTON) {
            UINT command = wParam == HTCLOSE ? SC_CLOSE
                         : wParam == HTMINBUTTON ? SC_MINIMIZE
                         : IsZoomed(hwnd) ? SC_RESTORE : SC_MAXIMIZE;
            SendMessageW(hwnd, WM_SYSCOMMAND, command, 0);
            return 0;
        }
        break;
    case WM_SIZE:
        layout_main_window(hwnd);
        return 0;
    case WM_GETMINMAXINFO: {
        MINMAXINFO *info = (MINMAXINFO *)lParam;
        info->ptMinTrackSize.x = ui_px(800);
        info->ptMinTrackSize.y = ui_px(720);
        return 0;
    }
    case WM_DPICHANGED: {
        g_ui_dpi = HIWORD(wParam);
        refresh_fonts();
        HWND edits[] = { g_edit_address, g_edit_name, g_edit_username, g_edit_password, g_edit_otp };
        for (int i = 0; i < 5; i++) {
            if (edits[i]) {
                SendMessageW(edits[i], EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN,
                             MAKELPARAM(ui_px(10), ui_px(10)));
            }
        }
        RECT *r = (RECT *)lParam;
        SetWindowPos(hwnd, NULL, r->left, r->top, r->right - r->left, r->bottom - r->top,
                     SWP_NOZORDER | SWP_NOACTIVATE);
        layout_main_window(hwnd);
        return 0;
    }
    case WM_SETTINGCHANGE:
    case WM_THEMECHANGED:
        refresh_theme();
        return 0;
    case WM_DRAWITEM:
        draw_control((const DRAWITEMSTRUCT *)lParam);
        return TRUE;
    case WM_MEASUREITEM:
        ((MEASUREITEMSTRUCT *)lParam)->itemHeight = ui_px(60);
        return TRUE;
    case WM_ERASEBKGND:
        return 1;
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(hwnd, &ps);
        RECT client;
        GetClientRect(hwnd, &client);
        int cw = client.right - client.left;
        int ch = client.bottom - client.top;
        if (cw > 0 && ch > 0) {
            HDC memDC = CreateCompatibleDC(dc);
            HBITMAP memBmp = memDC ? CreateCompatibleBitmap(dc, cw, ch) : NULL;
            if (memDC && memBmp) {
                HGDIOBJ oldBmp = SelectObject(memDC, memBmp);
                paint_main_surface(hwnd, memDC, client);
                BitBlt(dc, 0, 0, cw, ch, memDC, 0, 0, SRCCOPY);
                SelectObject(memDC, oldBmp);
                DeleteObject(memBmp);
                DeleteDC(memDC);
            } else {
                if (memBmp) DeleteObject(memBmp);
                if (memDC) DeleteDC(memDC);
                paint_main_surface(hwnd, dc, client);
            }
        }
        EndPaint(hwnd, &ps);
        return 0;
    }
    case WM_CTLCOLORSTATIC:
    case WM_CTLCOLORBTN: {
        HWND control = (HWND)lParam;
        BOOL card = FALSE;
        for (int i = 0; i < g_form_control_count; i++) {
            if (g_form_controls[i] == control) card = TRUE;
        }
        BOOL secondary = control == g_lbl_header_sub || control == g_lbl_status_toast ||
                         control == g_empty_devices || control == g_form_controls[1];
        SetTextColor((HDC)wParam, secondary ? g_muted : g_text);
        SetBkColor((HDC)wParam, card ? g_card : g_bg);
        return (LRESULT)(card ? g_brush_card : g_brush_bg);
    }
    case WM_CTLCOLOREDIT:
    case WM_CTLCOLORLISTBOX: {
        BOOL list = (HWND)lParam == g_list_devices;
        SetTextColor((HDC)wParam, g_text);
        SetBkColor((HDC)wParam, list ? g_bg : g_input);
        return (LRESULT)(list ? g_brush_bg : g_brush_input);
    }
    case WM_COMMAND: {
        int id = LOWORD(wParam);
        int code = HIWORD(wParam);
        if (!g_gui_cb) break;
        if (id == ID_LIST_DEVICES && (code == LBN_SELCHANGE || code == LBN_DBLCLK)) {
            int sel = (int)SendMessageW(g_list_devices, LB_GETCURSEL, 0, 0);
            if (sel != LB_ERR) {
                ULONGLONG now = GetTickCount64();
                if (code == LBN_DBLCLK && sel == g_last_list_sel &&
                    (now - g_last_sel_ms) <= (ULONGLONG)GetDoubleClickTime() + 100) {
                    return 0;
                }
                g_last_list_sel = sel;
                g_last_sel_ms = now;
                EnableWindow(g_btn_remove_dev, TRUE);
                g_gui_cb("device-activated", sel, g_gui_ctx);
            }
            return 0;
        }
        switch (id) {
        case ID_BTN_NEW_CONN:   g_gui_cb("new-connection", 0, g_gui_ctx); return 0;
        case ID_BTN_REMOVE_DEV: {
            int sel = (int)SendMessageW(g_list_devices, LB_GETCURSEL, 0, 0);
            if (sel != LB_ERR) g_gui_cb("device-delete", sel, g_gui_ctx);
            return 0;
        }
        case ID_BTN_CONNECT:    g_gui_cb("connect", 0, g_gui_ctx); return 0;
        case ID_BTN_WEB:        g_gui_cb("connect-web", 0, g_gui_ctx); return 0;
        case ID_BTN_BOOKMARK:   g_gui_cb("save-device", 0, g_gui_ctx); return 0;
        case ID_BTN_INFO:       g_gui_cb("connection-info", 0, g_gui_ctx); return 0;
        case ID_BTN_SETTINGS:   g_gui_cb("settings", 0, g_gui_ctx); return 0;
        case ID_BTN_SCREENSHOT: g_gui_cb("screenshot", 0, g_gui_ctx); return 0;
        case ID_BTN_RECORD:     g_gui_cb("record", 0, g_gui_ctx); return 0;
        case ID_BTN_OCR:        g_gui_cb("ocr", 0, g_gui_ctx); return 0;
        case ID_BTN_PASTE:      g_gui_cb("paste-remote", 0, g_gui_ctx); return 0;
        case ID_BTN_CAD:        g_gui_cb("send-ctrl-alt-delete", 0, g_gui_ctx); return 0;
        case ID_BTN_FULLSCREEN: g_gui_cb("fullscreen", 0, g_gui_ctx); return 0;
        case ID_BTN_DISCONNECT: g_gui_cb("disconnect", 0, g_gui_ctx); return 0;
        case ID_BTN_SIDEBAR:    g_gui_cb("toggle-sidebar", 0, g_gui_ctx); return 0;
        }
        break;
    }
    case WM_CLOSE:
        DestroyWindow(hwnd);
        return 0;
    case WM_DESTROY:
        update_kb_hook(NULL, 0);
        if (g_video_native) {
            release_native(g_video_native);
            g_video_native = NULL;
        }
        if (g_brush_bg) { DeleteObject(g_brush_bg); g_brush_bg = NULL; }
        if (g_brush_card) { DeleteObject(g_brush_card); g_brush_card = NULL; }
        if (g_brush_input) { DeleteObject(g_brush_input); g_brush_input = NULL; }
        if (g_font_regular) { DeleteObject(g_font_regular); g_font_regular = NULL; }
        if (g_font_bold) { DeleteObject(g_font_bold); g_font_bold = NULL; }
        if (g_font_title) { DeleteObject(g_font_title); g_font_title = NULL; }
        if (g_icon_small) { DestroyIcon(g_icon_small); g_icon_small = NULL; }
        if (g_icon_large) { DestroyIcon(g_icon_large); g_icon_large = NULL; }
        g_btn_sidebar = NULL;
        g_tooltip_hwnd = NULL;
        g_sidebar_heading = NULL;
        g_empty_devices = NULL;
        g_list_devices = NULL;
        g_btn_new_conn = NULL;
        g_btn_remove_dev = NULL;
        g_btn_connect = NULL;
        g_btn_record = NULL;
        g_lbl_header_title = NULL;
        g_lbl_header_sub = NULL;
        g_lbl_status_toast = NULL;
        g_form_control_count = 0;
        g_sidebar_visible = 1;
        g_is_fullscreen = 0;
        g_is_session_mode = 0;
        g_main_hwnd = NULL;
        g_video_hwnd = NULL;
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

static HWND add_form_ctrl(HWND ctrl, HFONT font) {
    if (ctrl && font) SendMessageW(ctrl, WM_SETFONT, (WPARAM)font, TRUE);
    if (g_form_control_count < 24) {
        g_form_controls[g_form_control_count++] = ctrl;
    }
    return ctrl;
}

void ol_win_gui_init(OLWinUICommandCallback callback, void *context) {
    g_gui_cb = callback;
    g_gui_ctx = context;
    ensure_msg_hwnd();
    if (g_main_hwnd) return;

    g_ui_dpi = GetDpiForSystem();

    INITCOMMONCONTROLSEX icc = { sizeof(icc), ICC_WIN95_CLASSES | ICC_STANDARD_CLASSES | ICC_BAR_CLASSES };
    InitCommonControlsEx(&icc);

    refresh_theme();
    refresh_fonts();

    HINSTANCE hInst = GetModuleHandleW(NULL);

    WNDCLASSEXW vwc = {0};
    vwc.cbSize = sizeof(vwc);
    vwc.style = CS_HREDRAW | CS_VREDRAW;
    vwc.lpfnWndProc = video_wnd_proc;
    vwc.hInstance = hInst;
    vwc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    vwc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    vwc.lpszClassName = L"OverlookVideoViewport";
    RegisterClassExW(&vwc);

    g_icon_large = LoadIconW(hInst, MAKEINTRESOURCEW(101));
    g_icon_small = (HICON)LoadImageW(hInst, MAKEINTRESOURCEW(101), IMAGE_ICON, ui_px(20), ui_px(20), LR_DEFAULTCOLOR);

    WNDCLASSEXW wc = {0};
    wc.cbSize = sizeof(wc);
    wc.style = CS_HREDRAW | CS_VREDRAW;
    wc.lpfnWndProc = main_wnd_proc;
    wc.hInstance = hInst;
    wc.hIcon = g_icon_large;
    wc.hIconSm = g_icon_small;
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = NULL;
    wc.lpszClassName = L"OverlookMainWindow";
    RegisterClassExW(&wc);

    g_main_hwnd = CreateWindowExW(
        0, wc.lpszClassName, L"Overlook",
        WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN,
        CW_USEDEFAULT, CW_USEDEFAULT, 1280, 820,
        NULL, NULL, hInst, NULL
    );
    if (!g_main_hwnd) return;

    g_ui_dpi = GetDpiForWindow(g_main_hwnd);
    refresh_theme();
    MARGINS frame = { 1, 1, 1, 1 };
    DwmExtendFrameIntoClientArea(g_main_hwnd, &frame);
    SetWindowPos(g_main_hwnd, NULL, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);

    g_btn_sidebar = CreateWindowExW(0, L"BUTTON", L"Hide sidebar", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_SIDEBAR, hInst, NULL);
    g_btn_new_conn = CreateWindowExW(0, L"BUTTON", L"+  New connection", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_NEW_CONN, hInst, NULL);
    g_btn_remove_dev = CreateWindowExW(0, L"BUTTON", L"Remove device", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_REMOVE_DEV, hInst, NULL);
    g_list_devices = CreateWindowExW(0, L"LISTBOX", L"", WS_CHILD | WS_VISIBLE | WS_VSCROLL | WS_TABSTOP | LBS_NOTIFY | LBS_OWNERDRAWFIXED | LBS_HASSTRINGS | LBS_NOINTEGRALHEIGHT, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_LIST_DEVICES, hInst, NULL);

    g_lbl_header_title = CreateWindowExW(0, L"STATIC", L"Overlook", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL);
    g_lbl_header_sub = CreateWindowExW(0, L"STATIC", L"Ready", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL);
    g_btn_info = CreateWindowExW(0, L"BUTTON", L"Info", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_INFO, hInst, NULL);
    g_btn_settings = CreateWindowExW(0, L"BUTTON", L"Settings", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_SETTINGS, hInst, NULL);
    g_btn_screenshot = CreateWindowExW(0, L"BUTTON", L"Snapshot", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_SCREENSHOT, hInst, NULL);
    g_btn_record = CreateWindowExW(0, L"BUTTON", L"Record", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_RECORD, hInst, NULL);
    g_btn_ocr = CreateWindowExW(0, L"BUTTON", L"OCR", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_OCR, hInst, NULL);
    g_btn_paste = CreateWindowExW(0, L"BUTTON", L"Paste", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_PASTE, hInst, NULL);
    g_btn_cad = CreateWindowExW(0, L"BUTTON", L"Ctrl+Alt+Del", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_CAD, hInst, NULL);
    g_btn_fullscreen = CreateWindowExW(0, L"BUTTON", L"Fullscreen", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_FULLSCREEN, hInst, NULL);
    g_btn_disconnect = CreateWindowExW(0, L"BUTTON", L"Disconnect", WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_DISCONNECT, hInst, NULL);

    HWND allTop[] = {
        g_btn_sidebar, g_btn_new_conn, g_btn_remove_dev, g_list_devices, g_lbl_header_sub,
        g_btn_info, g_btn_settings, g_btn_screenshot, g_btn_record,
        g_btn_ocr, g_btn_paste, g_btn_cad, g_btn_fullscreen, g_btn_disconnect
    };
    for (size_t i = 0; i < sizeof(allTop) / sizeof(allTop[0]); i++) {
        SendMessageW(allTop[i], WM_SETFONT, (WPARAM)g_font_regular, TRUE);
    }
    SendMessageW(g_lbl_header_title, WM_SETFONT, (WPARAM)g_font_bold, TRUE);

    g_form_control_count = 0;
    add_form_ctrl(CreateWindowExW(0, L"STATIC", L"Your next connection", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL), g_font_title);
    add_form_ctrl(CreateWindowExW(0, L"STATIC", L"Connect to your KVM for a fast, direct view of your remote computer.", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL), g_font_regular);

    add_form_ctrl(CreateWindowExW(0, L"STATIC", L"Device address", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL), g_font_regular);
    g_edit_address = add_form_ctrl(CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_EDIT_ADDRESS, hInst, NULL), g_font_regular);

    add_form_ctrl(CreateWindowExW(0, L"STATIC", L"Display name (optional)", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL), g_font_regular);
    g_edit_name = add_form_ctrl(CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_EDIT_NAME, hInst, NULL), g_font_regular);
    g_btn_bookmark = add_form_ctrl(CreateWindowExW(0, L"BUTTON", L"Save Device", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_BOOKMARK, hInst, NULL), g_font_regular);

    add_form_ctrl(CreateWindowExW(0, L"STATIC", L"Username", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL), g_font_regular);
    g_edit_username = add_form_ctrl(CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"admin", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_EDIT_USERNAME, hInst, NULL), g_font_regular);

    add_form_ctrl(CreateWindowExW(0, L"STATIC", L"Password", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL), g_font_regular);
    g_edit_password = add_form_ctrl(CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_PASSWORD | ES_AUTOHSCROLL, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_EDIT_PASSWORD, hInst, NULL), g_font_regular);

    add_form_ctrl(CreateWindowExW(0, L"STATIC", L"One-time code or TOTP secret (optional)", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL), g_font_regular);
    g_edit_otp = add_form_ctrl(CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"", WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_PASSWORD | ES_AUTOHSCROLL, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_EDIT_OTP, hInst, NULL), g_font_regular);

    g_chk_savepass = add_form_ctrl(CreateWindowExW(0, L"BUTTON", L"Remember this device and password", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_CHK_SAVEPASS, hInst, NULL), g_font_regular);

    g_btn_connect = add_form_ctrl(CreateWindowExW(0, L"BUTTON", L"Connect", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_CONNECT, hInst, NULL), g_font_bold);
    g_btn_web = add_form_ctrl(CreateWindowExW(0, L"BUTTON", L"Web console", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_PUSHBUTTON, 0, 0, 0, 0, g_main_hwnd, (HMENU)ID_BTN_WEB, hInst, NULL), g_font_regular);

    g_video_hwnd = CreateWindowExW(0, L"OverlookVideoViewport", L"", WS_CHILD, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL);
    g_lbl_status_toast = CreateWindowExW(0, L"STATIC", L"Ready \u2014 Select or enter a KVM device address to connect.", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL);
    SendMessageW(g_lbl_status_toast, WM_SETFONT, (WPARAM)g_font_regular, TRUE);

    g_sidebar_heading = CreateWindowExW(0, L"STATIC", L"Devices", WS_CHILD | WS_VISIBLE | SS_CENTERIMAGE, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL);
    g_empty_devices = CreateWindowExW(0, L"STATIC", L"No saved devices yet.\n\nSave a connection to find it here next time.", WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, g_main_hwnd, NULL, hInst, NULL);

    g_tooltip_hwnd = CreateWindowExW(
        WS_EX_TOPMOST, TOOLTIPS_CLASSW, NULL,
        WS_POPUP | TTS_NOPREFIX | TTS_ALWAYSTIP,
        CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
        g_main_hwnd, NULL, hInst, NULL
    );
    if (g_tooltip_hwnd) {
        TOOLINFOW ti = {0};
        ti.cbSize = sizeof(ti);
        ti.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
        ti.hwnd = g_main_hwnd;
        ti.uId = (UINT_PTR)g_btn_sidebar;
        ti.lpszText = L"Hide sidebar (Ctrl+B)";
        SendMessageW(g_tooltip_hwnd, TTM_ADDTOOLW, 0, (LPARAM)&ti);
    }

    SendMessageW(g_edit_address, EM_SETCUEBANNER, 0, (LPARAM)L"192.168.1.100 or kvm.local");
    SendMessageW(g_edit_name, EM_SETCUEBANNER, 0, (LPARAM)L"e.g. Home server");
    refresh_fonts();
    EnumChildWindows(g_main_hwnd, style_control, 0);
    update_sidebar_button_state();
    layout_main_window(g_main_hwnd);
}

void ol_win_gui_set_title(const char *title, const char *subtitle) {
    if (!g_main_hwnd) return;
    wchar_t *wt = utf8_to_wide(title ? title : "Overlook");
    wchar_t *ws = utf8_to_wide(subtitle ? subtitle : "");
    SetWindowTextW(g_lbl_header_title, wt);
    SetWindowTextW(g_lbl_header_sub, ws);
    if (subtitle && subtitle[0]) {
        size_t len = wcslen(wt) + wcslen(ws) + 16;
        wchar_t *full = (wchar_t *)calloc(len, sizeof(wchar_t));
        if (full) {
            swprintf_s(full, len, L"%ls \u2014 %ls", wt, ws);
            SetWindowTextW(g_main_hwnd, full);
            free(full);
        }
    } else {
        SetWindowTextW(g_main_hwnd, wt);
    }
    free(wt);
    free(ws);
}

void ol_win_gui_set_size(int width, int height) {
    if (!g_main_hwnd || width <= 0 || height <= 0) return;
    SetWindowPos(g_main_hwnd, NULL, 0, 0, ui_px(width), ui_px(height), SWP_NOMOVE | SWP_NOZORDER);
}

void ol_win_gui_set_fullscreen(int fullscreen) {
    if (!g_main_hwnd) return;
    if (fullscreen && !g_is_fullscreen) {
        DWORD style = (DWORD)GetWindowLongPtrW(g_main_hwnd, GWL_STYLE);
        MONITORINFO mi = { sizeof(mi) };
        if (GetWindowPlacement(g_main_hwnd, &g_prev_placement) &&
            GetMonitorInfoW(MonitorFromWindow(g_main_hwnd, MONITOR_DEFAULTTONEAREST), &mi)) {
            if (!IsWindowVisible(g_main_hwnd)) {
                g_prev_placement.showCmd = SW_HIDE;
            }
            g_is_fullscreen = 1;
            SetWindowLongPtrW(g_main_hwnd, GWL_STYLE, style & ~WS_OVERLAPPEDWINDOW);
            SetWindowPos(g_main_hwnd, HWND_TOP,
                         mi.rcMonitor.left, mi.rcMonitor.top,
                         mi.rcMonitor.right - mi.rcMonitor.left,
                         mi.rcMonitor.bottom - mi.rcMonitor.top,
                         SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
            layout_main_window(g_main_hwnd);
        }
    } else if (!fullscreen && g_is_fullscreen) {
        DWORD style = (DWORD)GetWindowLongPtrW(g_main_hwnd, GWL_STYLE);
        g_is_fullscreen = 0;
        SetWindowLongPtrW(g_main_hwnd, GWL_STYLE, style | WS_OVERLAPPEDWINDOW);
        SetWindowPlacement(g_main_hwnd, &g_prev_placement);
        SetWindowPos(g_main_hwnd, NULL, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED);
        layout_main_window(g_main_hwnd);
    }
}

int ol_win_gui_is_fullscreen(void) {
    return g_is_fullscreen;
}

void ol_win_gui_set_sidebar_visible(int visible) {
    g_sidebar_visible = visible ? 1 : 0;
    if (!g_sidebar_visible && g_main_hwnd) {
        HWND focused = GetFocus();
        if (focused && (focused == g_list_devices || focused == g_btn_new_conn || focused == g_btn_remove_dev)) {
            if (g_is_session_mode && g_video_hwnd && IsWindowVisible(g_video_hwnd)) {
                SetFocus(g_video_hwnd);
            } else if (g_btn_sidebar && IsWindowVisible(g_btn_sidebar)) {
                SetFocus(g_btn_sidebar);
            }
        }
    }
    update_sidebar_button_state();
    if (g_main_hwnd) {
        layout_main_window(g_main_hwnd);
    }
}

int ol_win_gui_is_sidebar_visible(void) {
    return g_sidebar_visible;
}

void ol_win_gui_present(void) {
    if (!g_main_hwnd) return;
    ShowWindow(g_main_hwnd, SW_SHOW);
    UpdateWindow(g_main_hwnd);
    SetForegroundWindow(g_main_hwnd);
}

void ol_win_gui_close(void) {
    if (g_main_hwnd) {
        DestroyWindow(g_main_hwnd);
    } else {
        PostQuitMessage(0);
    }
}

void ol_win_gui_toast(const char *message) {
    if (!g_lbl_status_toast) return;
    wchar_t *wm = utf8_to_wide(message ? message : "");
    SetWindowTextW(g_lbl_status_toast, wm);
    free(wm);
}

void ol_win_gui_set_mode(int is_session, OLNative *native) {
    g_is_session_mode = is_session;
    if (!is_session) {
        ol_win_gui_set_recording(0);
    }
    OLNative *old = g_video_native;
    if (old != native) {
        g_video_native = native ? retain_native(native) : NULL;
        if (old) {
            if (g_captured_native == old) update_kb_hook(old, 0);
            release_native(old);
        }
    }
    if (native) {
        ol_native_set_frame_callback(native, video_frame_render_cb, NULL);
    }
    if (g_main_hwnd) {
        layout_main_window(g_main_hwnd);
        if (is_session && g_video_hwnd) {
            RECT rc;
            GetClientRect(g_video_hwnd, &rc);
            if (native && rc.right > 0 && rc.bottom > 0) {
                ol_native_set_widget_size(native, (double)rc.right, (double)rc.bottom);
            }
            SetFocus(g_video_hwnd);
        }
    }
}

void ol_win_gui_set_form(const char *address, const char *name, const char *username,
                         const char *password, const char *otp, int save_password) {
    if (!g_main_hwnd) return;
    if (address) { wchar_t *w = utf8_to_wide(address); SetWindowTextW(g_edit_address, w); free(w); }
    if (name) { wchar_t *w = utf8_to_wide(name); SetWindowTextW(g_edit_name, w); free(w); }
    if (username) { wchar_t *w = utf8_to_wide(username); SetWindowTextW(g_edit_username, w); free(w); }
    if (password) { wchar_t *w = utf8_to_wide(password); SetWindowTextW(g_edit_password, w); free(w); }
    if (otp) { wchar_t *w = utf8_to_wide(otp); SetWindowTextW(g_edit_otp, w); free(w); }
    if (save_password >= 0) {
        SendMessageW(g_chk_savepass, BM_SETCHECK, save_password ? BST_CHECKED : BST_UNCHECKED, 0);
    }
}

static void read_hwnd_utf8(HWND h, char *buf, int len) {
    if (!buf || len <= 0) return;
    buf[0] = '\0';
    if (!h) return;
    wchar_t wbuf[512] = {0};
    GetWindowTextW(h, wbuf, 511);
    WideCharToMultiByte(CP_UTF8, 0, wbuf, -1, buf, len, NULL, NULL);
    SecureZeroMemory(wbuf, sizeof(wbuf));
    buf[len - 1] = '\0';
}

void ol_win_gui_get_form(char *address, int addr_len, char *name, int name_len,
                         char *username, int user_len, char *password, int pass_len,
                         char *otp, int otp_len, int *save_password) {
    read_hwnd_utf8(g_edit_address, address, addr_len);
    read_hwnd_utf8(g_edit_name, name, name_len);
    read_hwnd_utf8(g_edit_username, username, user_len);
    read_hwnd_utf8(g_edit_password, password, pass_len);
    read_hwnd_utf8(g_edit_otp, otp, otp_len);
    if (save_password && g_chk_savepass) {
        *save_password = (SendMessageW(g_chk_savepass, BM_GETCHECK, 0, 0) == BST_CHECKED) ? 1 : 0;
    }
}

void ol_win_gui_focus_field(int field) {
    HWND target = NULL;
    switch (field) {
    case 0: target = g_edit_address; break;
    case 1: target = g_edit_name; break;
    case 2: target = g_edit_username; break;
    case 3: target = g_edit_password; break;
    case 4: target = g_edit_otp; break;
    }
    if (target && IsWindow(target) && IsWindowVisible(target)) {
        SetFocus(target);
    }
}

void ol_win_gui_set_recording(int recording) {
    if (!g_btn_record) return;
    SetWindowTextW(g_btn_record, recording ? L"Stop Rec" : L"Record");
    InvalidateRect(g_btn_record, NULL, FALSE);
}

void ol_win_gui_clear_devices(void) {
    if (g_list_devices) {
        g_last_list_sel = LB_ERR;
        SendMessageW(g_list_devices, LB_RESETCONTENT, 0, 0);
        layout_main_window(g_main_hwnd);
    }
}

void ol_win_gui_add_device(const char *name, const char *host) {
    if (!g_list_devices) return;
    char *combined = NULL;
    if (name && name[0] && host && host[0] && strcmp(name, host) != 0) {
        combined = alloc_printf("%s\n%s", name, host);
    } else {
        combined = _strdup((name && name[0]) ? name : (host ? host : "KVM"));
    }
    wchar_t *w = utf8_to_wide(combined ? combined : "KVM");
    free(combined);
    SendMessageW(g_list_devices, LB_ADDSTRING, 0, (LPARAM)w);
    free(w);
    layout_main_window(g_main_hwnd);
}

int ol_win_gui_cert_prompt(const char *heading, const char *body, const char *fingerprint) {
    char *full = alloc_printf(
        "%s\n\nSHA-256 Fingerprint:\n%s\n\n"
        "Click [Yes] to Always Trust & Pin this certificate,\n"
        "[No] to Trust Once for this session, or\n"
        "[Cancel] to Reject.",
        body ? body : "", fingerprint ? fingerprint : "");
    wchar_t *wh = utf8_to_wide(heading ? heading : "Unverified Certificate");
    wchar_t *wb = utf8_to_wide(full ? full : "");
    free(full);
    int res = MessageBoxW(g_main_hwnd, wb, wh, MB_YESNOCANCEL | MB_ICONWARNING | MB_DEFBUTTON3);
    free(wh);
    free(wb);
    if (res == IDYES) return 2;
    if (res == IDNO) return 1;
    return 0;
}

typedef struct OLInfoDialog {
    const wchar_t *title;
    const wchar_t *body;
} OLInfoDialog;

static INT_PTR CALLBACK info_dialog_proc(HWND dialog, UINT message, WPARAM wp, LPARAM lp) {
    switch (message) {
    case WM_INITDIALOG: {
        OLInfoDialog *info = (OLInfoDialog *)lp;
        SetWindowTextW(dialog, info->title);
        HINSTANCE instance = GetModuleHandleW(NULL);
        HWND heading = CreateWindowExW(0, L"STATIC", info->title, WS_CHILD | WS_VISIBLE,
                                       0, 0, 0, 0, dialog, (HMENU)101, instance, NULL);
        HWND body = CreateWindowExW(0, L"EDIT", info->body,
                                    WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_VSCROLL | ES_MULTILINE | ES_READONLY | ES_AUTOVSCROLL,
                                    0, 0, 0, 0, dialog, (HMENU)102, instance, NULL);
        HWND closeBtn = CreateWindowExW(0, L"BUTTON", L"Close", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_OWNERDRAW,
                                        0, 0, 0, 0, dialog, (HMENU)IDOK, instance, NULL);
        SendMessageW(heading, WM_SETFONT, (WPARAM)g_font_title, TRUE);
        SendMessageW(body, WM_SETFONT, (WPARAM)g_font_regular, TRUE);
        SendMessageW(closeBtn, WM_SETFONT, (WPARAM)g_font_regular, TRUE);
        SetWindowSubclass(closeBtn, fluent_control_proc, 1, 0);
        SendMessageW(body, EM_SETMARGINS, EC_LEFTMARGIN | EC_RIGHTMARGIN, MAKELPARAM(ui_px(16), ui_px(16)));
        DwmSetWindowAttribute(dialog, 20, &g_dark, sizeof(g_dark));
        int corners = 2;
        DwmSetWindowAttribute(dialog, 33, &corners, sizeof(corners));

        MONITORINFO monitor = { sizeof(monitor) };
        HMONITOR hMon = g_main_hwnd
            ? MonitorFromWindow(g_main_hwnd, MONITOR_DEFAULTTONEAREST)
            : MonitorFromPoint((POINT){0, 0}, MONITOR_DEFAULTTOPRIMARY);
        GetMonitorInfoW(hMon, &monitor);
        RECT parent = monitor.rcWork;
        if (g_main_hwnd && IsWindowVisible(g_main_hwnd)) {
            GetWindowRect(g_main_hwnd, &parent);
        }
        int width = ui_px(720), height = ui_px(640);
        int workW = monitor.rcWork.right - monitor.rcWork.left;
        int workH = monitor.rcWork.bottom - monitor.rcWork.top;
        if (width > workW) width = workW;
        if (height > workH) height = workH;
        int x = parent.left + (parent.right - parent.left - width) / 2;
        int y = parent.top + (parent.bottom - parent.top - height) / 2;
        if (x < monitor.rcWork.left) x = monitor.rcWork.left;
        if (y < monitor.rcWork.top) y = monitor.rcWork.top;
        if (x + width > monitor.rcWork.right) x = monitor.rcWork.right - width;
        if (y + height > monitor.rcWork.bottom) y = monitor.rcWork.bottom - height;
        SetWindowPos(dialog, NULL, x, y, width, height, SWP_NOZORDER);
        SetFocus(closeBtn);
        return FALSE;
    }
    case WM_SIZE: {
        int w = LOWORD(lp), h = HIWORD(lp), pad = ui_px(24);
        MoveWindow(GetDlgItem(dialog, 101), pad, pad, w - pad * 2, ui_px(40), TRUE);
        MoveWindow(GetDlgItem(dialog, 102), pad, ui_px(80), w - pad * 2, h - ui_px(160), TRUE);
        MoveWindow(GetDlgItem(dialog, IDOK), w - pad - ui_px(96), h - pad - ui_px(36), ui_px(96), ui_px(36), TRUE);
        return TRUE;
    }
    case WM_GETMINMAXINFO:
        ((MINMAXINFO *)lp)->ptMinTrackSize.x = ui_px(400);
        ((MINMAXINFO *)lp)->ptMinTrackSize.y = ui_px(320);
        return TRUE;
    case WM_CTLCOLORDLG:
        return (INT_PTR)g_brush_bg;
    case WM_CTLCOLORSTATIC: {
        BOOL body = GetDlgCtrlID((HWND)lp) == 102;
        SetTextColor((HDC)wp, g_text);
        SetBkColor((HDC)wp, body ? g_card : g_bg);
        return (INT_PTR)(body ? g_brush_card : g_brush_bg);
    }
    case WM_DRAWITEM:
        draw_control((DRAWITEMSTRUCT *)lp);
        return TRUE;
    case WM_COMMAND:
        if (LOWORD(wp) == IDOK || LOWORD(wp) == IDCANCEL) {
            EndDialog(dialog, IDOK);
            return TRUE;
        }
        break;
    case WM_CLOSE:
        EndDialog(dialog, IDCANCEL);
        return TRUE;
    }
    return FALSE;
}

void ol_win_gui_show_dialog(const char *title, const char *content) {
    wchar_t *wt = utf8_to_wide(title ? title : "Overlook");
    wchar_t *wc = utf8_to_wide(content ? content : "");
    size_t length = wcslen(wc), used = 0;
    wchar_t *body = (wchar_t *)calloc(length * 2 + 1, sizeof(wchar_t));
    if (!body) {
        free(wt);
        free(wc);
        return;
    }
    for (size_t i = 0; i < length; i++) {
        if (wc[i] == L'\n' && (i == 0 || wc[i - 1] != L'\r')) body[used++] = L'\r';
        body[used++] = wc[i];
    }
    OLInfoDialog info = { wt, body };
    struct { DLGTEMPLATE dialog; WORD menu, windowClass, title; } resource = {0};
    resource.dialog.style = WS_POPUP | WS_CAPTION | WS_SYSMENU | WS_THICKFRAME | DS_MODALFRAME;
    resource.dialog.dwExtendedStyle = WS_EX_CONTROLPARENT;
    resource.dialog.cx = 360;
    resource.dialog.cy = 320;
    DialogBoxIndirectParamW(GetModuleHandleW(NULL), &resource.dialog, g_main_hwnd, info_dialog_proc, (LPARAM)&info);
    free(wt);
    free(wc);
    free(body);
}

void ol_win_gui_open_web(const char *url) {
    if (!url || !url[0]) return;
    if (_strnicmp(url, "http://", 7) != 0 && _strnicmp(url, "https://", 8) != 0) {
        return;
    }
    wchar_t *wurl = utf8_to_wide(url);
    ShellExecuteW(g_main_hwnd, L"open", wurl, NULL, NULL, SW_SHOWNORMAL);
    free(wurl);
}
#endif
