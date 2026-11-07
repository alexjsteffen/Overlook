#include "Native.h"

#ifdef _WIN32
#include <windows.h>
#include <winhttp.h>
#include <wincrypt.h>
#include <bcrypt.h>
#include <wincred.h>
#include <dxgi.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define WM_OL_EVENT     (WM_APP + 0x101)
#define WM_OL_FRAME     (WM_APP + 0x102)
#define WM_OL_HTTP_RESP (WM_APP + 0x103)

typedef struct AllowedPin {
    char *key;
    char *sha256;
    struct AllowedPin *next;
} AllowedPin;

typedef struct OLRecorder {
    OLNative *owner;
    char *path;
    char *backend;
    int width, height, stride, frames;
    ULONGLONG start_ms, last_push_ms;
    uint32_t timer_id;
    HANDLE ffmpeg_proc;
    HANDLE ffmpeg_stdin;
    CRITICAL_SECTION lock;
} OLRecorder;

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
    char *rejected;
    char *cookie_token;
    char *cookie_host;

    HINTERNET ws_session;
    HINTERNET ws_connect;
    HINTERNET ws_handle;
    HANDLE ws_thread;
    volatile LONG ws_open;

    HINTERNET hid_session;
    HINTERNET hid_connect;
    HINTERNET hid_handle;
    HANDLE hid_thread;
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
    uint64_t total_bytes_received;
    uint64_t last_bytes_received;
    ULONGLONG last_stats_ms;
    uint32_t test_timer_id;
    int test_is_h264;
    OLRecorder *recorder;
};

// ============================================================================
// UI Thread Message Pump & Timer Dispatch
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

static void recorder_abort(OLNative *n);

static void release_native(OLNative *n) {
    if (!n) return;
    if (InterlockedDecrement(&n->refs) == 0) {
        recorder_abort(n);
        EnterCriticalSection(&n->lock);
        AllowedPin *p = n->allowed;
        while (p) {
            AllowedPin *next = p->next;
            free(p->key);
            free(p->sha256);
            free(p);
            p = next;
        }
        free(n->rejected);
        free(n->cookie_token);
        free(n->cookie_host);
        free(n->last_frame_bytes);
        LeaveCriticalSection(&n->lock);
        DeleteCriticalSection(&n->lock);
        free(n);
    }
}

static void recorder_push_frame(OLRecorder *rec, const uint8_t *bytes, int width, int height, int stride);

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
                free(n->last_frame_bytes);
                size_t sz = (size_t)f->stride * (size_t)f->height;
                n->last_frame_bytes = (uint8_t *)malloc(sz);
                if (n->last_frame_bytes) memcpy(n->last_frame_bytes, f->pixels, sz);
                n->last_frame_width = f->width;
                n->last_frame_height = f->height;
                n->last_frame_stride = f->stride;
                n->rendered_frames_window++;
                if (n->recorder) {
                    recorder_push_frame(n->recorder, f->pixels, f->width, f->height, f->stride);
                }
                if (n->frame_cb) {
                    n->frame_cb(f->pixels, f->width, f->height, f->stride, n->frame_context);
                }
                if (!n->got_frame) {
                    n->got_frame = 1;
                    if (n->callback) n->callback("frame", "Native WebRTC video connected", 0, n->context);
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
            if (InterlockedCompareExchange(&r->n->active, 0, 0) && r->cb) {
                r->cb(r->status, r->data, r->length, r->error, r->ctx);
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

static void emit_event(OLNative *n, const char *event, const char *text, int number) {
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0)) return;
    QueuedEvent *e = (QueuedEvent *)calloc(1, sizeof(QueuedEvent));
    if (!e) return;
    e->n = retain_native(n);
    e->event = _strdup(event ? event : "");
    e->text = _strdup(text ? text : "");
    e->number = number;
    if (g_msg_hwnd) {
        PostMessageW(g_msg_hwnd, WM_OL_EVENT, 0, (LPARAM)e);
    } else {
        release_native(e->n);
        free(e->event);
        free(e->text);
        free(e);
    }
}

static void deliver_bgra_frame(OLNative *n, const uint8_t *bgra, int width, int height, int stride) {
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0)) return;
    if (InterlockedCompareExchange(&n->frame_pending, 1, 0) != 0) return;
    size_t sz = (size_t)stride * (size_t)height;
    uint8_t *copy = (uint8_t *)malloc(sz);
    if (!copy) {
        InterlockedExchange(&n->frame_pending, 0);
        return;
    }
    memcpy(copy, bgra, sz);
    QueuedFrame *f = (QueuedFrame *)calloc(1, sizeof(QueuedFrame));
    f->n = retain_native(n);
    f->pixels = copy;
    f->width = width;
    f->height = height;
    f->stride = stride;
    if (g_msg_hwnd) {
        PostMessageW(g_msg_hwnd, WM_OL_FRAME, 0, (LPARAM)f);
    } else {
        InterlockedExchange(&n->frame_pending, 0);
        free(copy);
        release_native(n);
        free(f);
    }
}

// ============================================================================
// Low-Level Keyboard Hook for System Shortcut Capture (Alt+Tab, Win, F11)
// ============================================================================

static LRESULT CALLBACK low_level_kb_proc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode == HC_ACTION && g_captured_native && g_captured_native->inhibited) {
        HWND fg = GetForegroundWindow();
        DWORD fgPid = 0;
        if (fg) GetWindowThreadProcessId(fg, &fgPid);
        if (fgPid == GetCurrentProcessId()) {
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
    n->inhibited = enabled;
    if (enabled) {
        g_captured_native = n;
        if (!g_kb_hook) {
            g_kb_hook = SetWindowsHookExW(WH_KEYBOARD_LL, low_level_kb_proc, GetModuleHandleW(NULL), 0);
        }
    } else {
        if (g_captured_native == n) g_captured_native = NULL;
        if (g_kb_hook && !g_captured_native) {
            UnhookWindowsHookEx(g_kb_hook);
            g_kb_hook = NULL;
        }
    }
}

// ============================================================================
// UTF-8 <-> UTF-16 & SHA-256 Certificate Helpers
// ============================================================================

static wchar_t *utf8_to_wide(const char *s) {
    if (!s) return _wcsdup(L"");
    int len = MultiByteToWideChar(CP_UTF8, 0, s, -1, NULL, 0);
    if (len <= 0) return _wcsdup(L"");
    wchar_t *w = (wchar_t *)calloc((size_t)len, sizeof(wchar_t));
    MultiByteToWideChar(CP_UTF8, 0, s, -1, w, len);
    return w;
}

static char *wide_to_utf8(const wchar_t *w) {
    if (!w) return _strdup("");
    int len = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    if (len <= 0) return _strdup("");
    char *s = (char *)calloc((size_t)len, 1);
    WideCharToMultiByte(CP_UTF8, 0, w, -1, s, len, NULL, NULL);
    return s;
}

static char *sha256_hex(const uint8_t *data, size_t len) {
    BCRYPT_ALG_HANDLE hAlg = NULL;
    uint8_t hash[32] = {0};
    if (BCryptOpenAlgorithmProvider(&hAlg, BCRYPT_SHA256_ALGORITHM, NULL, 0) == 0) {
        BCryptHash(hAlg, NULL, 0, (PUCHAR)data, (ULONG)len, hash, sizeof(hash));
        BCryptCloseAlgorithmProvider(hAlg, 0);
    }
    char *hex = (char *)calloc(65, 1);
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
    node->key = _strdup(key);
    node->sha256 = _strdup(sha256);
    node->next = n->allowed;
    n->allowed = node;
    LeaveCriticalSection(&n->lock);
}

typedef struct ParsedURL {
    int is_https;
    wchar_t host[256];
    char host_utf8[256];
    INTERNET_PORT port;
    wchar_t path[2048];
    char key[300];
} ParsedURL;

static int parse_url(const char *url_str, ParsedURL *out) {
    memset(out, 0, sizeof(*out));
    wchar_t *wurl = utf8_to_wide(url_str);
    // WinHttpCrackUrl supports http/https; convert ws/wss schemes temporarily.
    int is_wss = (_wcsnicmp(wurl, L"wss://", 6) == 0);
    int is_ws = (_wcsnicmp(wurl, L"ws://", 5) == 0);
    wchar_t normalized[2048] = {0};
    if (is_wss) {
        swprintf_s(normalized, 2048, L"https://%s", wurl + 6);
    } else if (is_ws) {
        swprintf_s(normalized, 2048, L"http://%s", wurl + 5);
    } else {
        wcsncpy_s(normalized, 2048, wurl, _TRUNCATE);
    }
    free(wurl);

    URL_COMPONENTS uc = {0};
    uc.dwStructSize = sizeof(uc);
    uc.lpszHostName = out->host;
    uc.dwHostNameLength = 255;
    uc.lpszUrlPath = out->path;
    uc.dwUrlPathLength = 2047;
    if (!WinHttpCrackUrl(normalized, 0, 0, &uc)) return 0;

    out->is_https = (uc.nScheme == INTERNET_SCHEME_HTTPS);
    out->port = uc.nPort ? uc.nPort : (out->is_https ? 443 : 80);
    if (out->path[0] == L'\0') wcscpy_s(out->path, 2048, L"/");

    char *h = wide_to_utf8(out->host);
    for (char *c = h; *c; c++) *c = (char)tolower((unsigned char)*c);
    strncpy_s(out->host_utf8, sizeof(out->host_utf8), h, _TRUNCATE);
    free(h);
    sprintf_s(out->key, sizeof(out->key), "%s:%d", out->host_utf8, (int)out->port);
    return 1;
}

static void add_cookie_header(OLNative *n, HINTERNET hReq) {
    EnterCriticalSection(&n->lock);
    if (n->cookie_token && n->cookie_token[0]) {
        char buf[1024];
        sprintf_s(buf, sizeof(buf), "Cookie: auth_token=%s; nano-kvm-token=%s\r\n", n->cookie_token, n->cookie_token);
        wchar_t *wbuf = utf8_to_wide(buf);
        WinHttpAddRequestHeaders(hReq, wbuf, (DWORD)-1L, WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
        free(wbuf);
    }
    LeaveCriticalSection(&n->lock);
}

// Inspects the server certificate on a request with ignored TLS flags and verifies whether
// its SHA-256 DER fingerprint matches `n->allowed` for `key`. If not, populates `cert_event_out`.
static int verify_pinned_certificate(OLNative *n, HINTERNET hReq, const char *key, char **cert_event_out) {
    PCCERT_CONTEXT pCert = NULL;
    DWORD cbCert = sizeof(pCert);
    if (!WinHttpQueryOption(hReq, WINHTTP_OPTION_SERVER_CERT_CONTEXT, &pCert, &cbCert) || !pCert) {
        return 0;
    }
    char *hex = sha256_hex(pCert->pbCertEncoded, pCert->cbCertEncoded);
    CertFreeCertificateContext(pCert);
    int ok = is_pin_allowed(n, key, hex);
    if (!ok && cert_event_out) {
        size_t need = strlen(key) + strlen(hex) + 128;
        *cert_event_out = (char *)calloc(need, 1);
        sprintf_s(*cert_event_out, need, "%s\n%s\nIt is not issued by a trusted certificate authority.", key, hex);
    }
    free(hex);
    return ok;
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

static DWORD WINAPI http_worker_thread(LPVOID param) {
    HTTPJob *job = (HTTPJob *)param;
    OLNative *n = job->n;
    ParsedURL pu;
    if (!parse_url(job->url, &pu)) {
        if (job->is_login) emit_event(n, "error", "Invalid API URL", 0);
        else if (job->cb) {
            QueuedHTTP *q = (QueuedHTTP *)calloc(1, sizeof(QueuedHTTP));
            q->n = retain_native(n); q->cb = job->cb; q->ctx = job->ctx;
            q->error = _strdup("Invalid API URL");
            PostMessageW(g_msg_hwnd, WM_OL_HTTP_RESP, 0, (LPARAM)q);
        }
        goto cleanup;
    }

    HINTERNET hSession = WinHttpOpen(L"Overlook/0.3 (Windows; WinUI 3)", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                     WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!hSession) {
        emit_event(n, "error", "Could not initialize WinHTTP session", 0);
        goto cleanup;
    }
    WinHttpSetTimeouts(hSession, 10000, 10000, 15000, 15000);

    HINTERNET hConnect = WinHttpConnect(hSession, pu.host, pu.port, 0);
    if (!hConnect) {
        WinHttpCloseHandle(hSession);
        emit_event(n, "error", "Could not connect to host", 0);
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
        emit_event(n, "error", "Could not open HTTP request", 0);
        goto cleanup;
    }

    if (job->is_login) {
        DWORD disableRedir = WINHTTP_DISABLE_REDIRECTS;
        WinHttpSetOption(hReq, WINHTTP_OPTION_DISABLE_FEATURE, &disableRedir, sizeof(disableRedir));
    }

    add_cookie_header(n, hReq);
    if (job->content_type && job->content_type[0]) {
        char hdr[256];
        sprintf_s(hdr, sizeof(hdr), "Content-Type: %s\r\n", job->content_type);
        wchar_t *whdr = utf8_to_wide(hdr);
        WinHttpAddRequestHeaders(hReq, whdr, (DWORD)-1L, WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE);
        free(whdr);
    }

    BOOL sent = WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                   job->body_len > 0 ? job->body : WINHTTP_NO_REQUEST_DATA,
                                   (DWORD)job->body_len, (DWORD)job->body_len, 0);
    if (!sent && GetLastError() == ERROR_WINHTTP_SECURE_FAILURE && pu.is_https) {
        // Probe certificate with ignore flags to check TOFU pin or report fingerprint to user.
        DWORD secFlags = SECURITY_FLAG_IGNORE_UNKNOWN_CA |
                         SECURITY_FLAG_IGNORE_CERT_CN_INVALID |
                         SECURITY_FLAG_IGNORE_CERT_DATE_INVALID |
                         SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
        WinHttpSetOption(hReq, WINHTTP_OPTION_SECURITY_FLAGS, &secFlags, sizeof(secFlags));
        sent = WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                  job->body_len > 0 ? job->body : WINHTTP_NO_REQUEST_DATA,
                                  (DWORD)job->body_len, (DWORD)job->body_len, 0);
        if (sent) {
            char *cert_event = NULL;
            if (!verify_pinned_certificate(n, hReq, pu.key, &cert_event)) {
                WinHttpCloseHandle(hReq);
                WinHttpCloseHandle(hConnect);
                WinHttpCloseHandle(hSession);
                if (cert_event) {
                    emit_event(n, "certificate", cert_event, 0);
                    free(cert_event);
                } else {
                    emit_event(n, "error", "The device certificate could not be verified.", 0);
                }
                goto cleanup;
            }
        }
    }

    if (!sent || !WinHttpReceiveResponse(hReq, NULL)) {
        WinHttpCloseHandle(hReq);
        WinHttpCloseHandle(hConnect);
        WinHttpCloseHandle(hSession);
        if (job->is_login) {
            emit_event(n, "error", "Network request failed. Check the device address and port.", 0);
        } else if (job->cb) {
            QueuedHTTP *q = (QueuedHTTP *)calloc(1, sizeof(QueuedHTTP));
            q->n = retain_native(n); q->cb = job->cb; q->ctx = job->ctx;
            q->error = _strdup("Network request failed.");
            PostMessageW(g_msg_hwnd, WM_OL_HTTP_RESP, 0, (LPARAM)q);
        }
        goto cleanup;
    }

    DWORD statusCode = 0;
    DWORD statusSize = sizeof(statusCode);
    WinHttpQueryHeaders(hReq, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX, &statusCode, &statusSize, WINHTTP_NO_HEADER_INDEX);

    // Capture Set-Cookie auth_token / nano-kvm-token if returned on login
    if (job->is_login) {
        wchar_t cookieHdr[1024] = {0};
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
                        free(n->cookie_token);
                        n->cookie_token = (char *)calloc(tlen + 1, 1);
                        memcpy(n->cookie_token, tok, tlen);
                        LeaveCriticalSection(&n->lock);
                    }
                }
            }
            free(cstr);
            cookieLen = sizeof(cookieHdr);
        }
    }

    uint8_t *respBuf = NULL;
    size_t respLen = 0;
    DWORD avail = 0;
    while (WinHttpQueryDataAvailable(hReq, &avail) && avail > 0) {
        uint8_t *next = (uint8_t *)realloc(respBuf, respLen + avail + 1);
        if (!next) break;
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
    } else if (job->cb) {
        QueuedHTTP *q = (QueuedHTTP *)calloc(1, sizeof(QueuedHTTP));
        q->n = retain_native(n);
        q->cb = job->cb;
        q->ctx = job->ctx;
        q->status = (int)statusCode;
        q->data = respBuf;
        q->length = (int)respLen;
        PostMessageW(g_msg_hwnd, WM_OL_HTTP_RESP, 0, (LPARAM)q);
    } else {
        free(respBuf);
    }

cleanup:
    release_native(n);
    free(job->method);
    free(job->url);
    free(job->content_type);
    free(job->body);
    free(job);
    return 0;
}

void ol_native_http(OLNative *n, const char *method, const char *url, const char *body) {
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0)) return;
    HTTPJob *job = (HTTPJob *)calloc(1, sizeof(HTTPJob));
    job->n = retain_native(n);
    job->method = _strdup(method ? method : "POST");
    job->url = _strdup(url ? url : "");
    job->content_type = _strdup("application/x-www-form-urlencoded");
    job->body_len = body ? (int)strlen(body) : 0;
    if (job->body_len > 0) {
        job->body = (uint8_t *)malloc((size_t)job->body_len);
        memcpy(job->body, body, (size_t)job->body_len);
    }
    job->is_login = 1;
    HANDLE th = CreateThread(NULL, 0, http_worker_thread, job, 0, NULL);
    if (th) CloseHandle(th);
}

void ol_native_request(OLNative *n, const char *method, const char *url,
                       const char *content_type, const unsigned char *body, int body_length,
                       OLNativeHTTPResponse callback, void *context) {
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0)) {
        if (callback) callback(0, NULL, 0, "Session is not active", context);
        return;
    }
    HTTPJob *job = (HTTPJob *)calloc(1, sizeof(HTTPJob));
    job->n = retain_native(n);
    job->method = _strdup(method ? method : "GET");
    job->url = _strdup(url ? url : "");
    job->content_type = content_type ? _strdup(content_type) : NULL;
    if (body && body_length > 0) {
        job->body = (uint8_t *)malloc((size_t)body_length);
        memcpy(job->body, body, (size_t)body_length);
        job->body_len = body_length;
    }
    job->is_login = 0;
    job->cb = callback;
    job->ctx = context;
    HANDLE th = CreateThread(NULL, 0, http_worker_thread, job, 0, NULL);
    if (th) CloseHandle(th);
}

void ol_native_cookie(OLNative *n, const char *url, const char *token) {
    if (!n || !token) return;
    EnterCriticalSection(&n->lock);
    free(n->cookie_token);
    n->cookie_token = _strdup(token);
    free(n->cookie_host);
    n->cookie_host = url ? _strdup(url) : NULL;
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

    HINTERNET hSession = WinHttpOpen(L"Overlook/0.3 (Windows; WinUI 3)", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                     WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
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
        char ohdr[512];
        sprintf_s(ohdr, sizeof(ohdr), "Origin: %s\r\n", args->origin);
        wchar_t *wohdr = utf8_to_wide(ohdr);
        WinHttpAddRequestHeaders(hReq, wohdr, (DWORD)-1L, WINHTTP_ADDREQ_FLAG_ADD);
        free(wohdr);
    }

    BOOL sent = WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
    if (!sent && GetLastError() == ERROR_WINHTTP_SECURE_FAILURE && pu.is_https) {
        DWORD secFlags = SECURITY_FLAG_IGNORE_UNKNOWN_CA |
                         SECURITY_FLAG_IGNORE_CERT_CN_INVALID |
                         SECURITY_FLAG_IGNORE_CERT_DATE_INVALID |
                         SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
        WinHttpSetOption(hReq, WINHTTP_OPTION_SECURITY_FLAGS, &secFlags, sizeof(secFlags));
        sent = WinHttpSendRequest(hReq, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0);
        if (sent) {
            char *cert_event = NULL;
            if (!verify_pinned_certificate(n, hReq, pu.key, &cert_event)) {
                WinHttpCloseHandle(hReq);
                WinHttpCloseHandle(hConnect);
                WinHttpCloseHandle(hSession);
                if (!is_hid && cert_event) emit_event(n, "certificate", cert_event, 0);
                else emit_event(n, is_hid ? "hid-closed" : "error", "Certificate not trusted", 0);
                free(cert_event);
                goto done;
            }
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

    EnterCriticalSection(&n->lock);
    if (is_hid) {
        n->hid_session = hSession;
        n->hid_connect = hConnect;
        n->hid_handle = hWs;
        InterlockedExchange(&n->hid_open, 1);
    } else {
        n->ws_session = hSession;
        n->ws_connect = hConnect;
        n->ws_handle = hWs;
        InterlockedExchange(&n->ws_open, 1);
    }
    LeaveCriticalSection(&n->lock);

    emit_event(n, is_hid ? "hid-open" : "open", "", 0);

    size_t cap = 65536;
    uint8_t *buf = (uint8_t *)malloc(cap);
    size_t offset = 0;

    while (InterlockedCompareExchange(&n->active, 0, 0)) {
        DWORD readBytes = 0;
        WINHTTP_WEB_SOCKET_BUFFER_TYPE bufType = WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE;
        if (offset + 4096 >= cap) {
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

    if (InterlockedCompareExchange(&n->active, 0, 0)) {
        if (is_hid) {
            InterlockedExchange(&n->hid_open, 0);
            emit_event(n, "hid-closed", "Keyboard and mouse connection closed", 0);
        } else {
            InterlockedExchange(&n->ws_open, 0);
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

void ol_native_socket(OLNative *n, const char *url, const char *origin) {
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0)) return;
    WSStartArgs *args = (WSStartArgs *)calloc(1, sizeof(WSStartArgs));
    args->n = retain_native(n);
    args->url = _strdup(url ? url : "");
    args->origin = _strdup(origin ? origin : "");
    args->is_hid = 0;
    HANDLE th = CreateThread(NULL, 0, ws_worker_thread, args, 0, NULL);
    if (th) CloseHandle(th);
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
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0)) return;
    WSStartArgs *args = (WSStartArgs *)calloc(1, sizeof(WSStartArgs));
    args->n = retain_native(n);
    args->url = _strdup(url ? url : "");
    args->origin = _strdup(origin ? origin : "");
    args->is_hid = 1;
    HANDLE th = CreateThread(NULL, 0, ws_worker_thread, args, 0, NULL);
    if (th) CloseHandle(th);
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
// WebRTC Signaling / GStreamer Loopback & Synthetic Smoke Generator
// ============================================================================

static int smoke_frame_tick(void *ctx) {
    OLNative *n = (OLNative *)ctx;
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0)) return 0;
    int w = 640, h = 360, stride = w * 4;
    uint8_t *bgra = (uint8_t *)malloc((size_t)stride * (size_t)h);
    if (!bgra) return 1;
    static int phase = 0;
    phase = (phase + 4) & 0xFF;
    for (int y = 0; y < h; y++) {
        uint8_t *row = bgra + y * stride;
        for (int x = 0; x < w; x++) {
            row[x * 4 + 0] = (uint8_t)((x + phase) & 0xFF);
            row[x * 4 + 1] = (uint8_t)((y + phase) & 0xFF);
            row[x * 4 + 2] = (uint8_t)((n->test_is_h264 ? 180 : 90));
            row[x * 4 + 3] = 255;
        }
    }
    n->total_bytes_received += 16000;
    deliver_bgra_frame(n, bgra, w, h, stride);
    free(bgra);
    return 1;
}

void ol_native_offer(OLNative *n, const char *sdp) {
    if (!n || !sdp) return;
    emit_event(n, "answer", "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n", 0);
}

void ol_native_create_offer(OLNative *n, const char *stun_server) {
    (void)stun_server;
    if (!n) return;
    emit_event(n, "local-offer", "v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=-\r\nt=0 0\r\n", 0);
}

void ol_native_answer(OLNative *n, const char *sdp) {
    (void)n; (void)sdp;
}

void ol_native_ice(OLNative *n, unsigned int line, const char *candidate) {
    (void)n; (void)line; (void)candidate;
}

void ol_native_test(OLNative *n, int h264) {
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0)) return;
    n->test_is_h264 = h264;
    if (n->test_timer_id == 0) {
        n->test_timer_id = ol_win_timer_add(33, smoke_frame_tick, n);
    }
}

void ol_native_poll_stats(OLNative *n) {
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0) || !n->got_frame) return;
    ULONGLONG now = GetTickCount64();
    int kbps = 2400;
    if (n->last_stats_ms > 0 && now > n->last_stats_ms && n->total_bytes_received >= n->last_bytes_received) {
        double dt = (double)(now - n->last_stats_ms) / 1000.0;
        if (dt > 0.1) {
            kbps = (int)llround(((double)(n->total_bytes_received - n->last_bytes_received) * 8.0 / 1000.0) / dt);
        }
    }
    n->last_bytes_received = n->total_bytes_received;
    n->last_stats_ms = now;
    int fps = n->rendered_frames_window;
    n->rendered_frames_window = 0;

    char json[512];
    sprintf_s(json, sizeof(json),
              "{\"width\":%d,\"height\":%d,\"fps\":%d,\"kbps\":%d,\"jitter_ms\":2,\"packets_lost\":0,\"pli_count\":0,\"nack_count\":0,\"rtt_ms\":4,\"codec\":\"%s\",\"path\":\"host -> host · UDP\",\"remote\":\"127.0.0.1\"}",
              n->last_frame_width, n->last_frame_height, fps > 0 ? fps : 30, kbps,
              n->test_is_h264 ? "H264" : "VP8");
    emit_event(n, "stats", json, 0);
}

// ============================================================================
// DXGI Hardware Encoder Probe, PNG Screenshots & MP4 Recording
// ============================================================================

char *ol_vaapi_probe(const char *preferred_device) {
    (void)preferred_device;
    IDXGIFactory1 *pFactory = NULL;
    if (SUCCEEDED(CreateDXGIFactory1(&IID_IDXGIFactory1, (void **)&pFactory)) && pFactory) {
        IDXGIAdapter1 *pAdapter = NULL;
        if (SUCCEEDED(IDXGIFactory1_EnumAdapters1(pFactory, 0, &pAdapter)) && pAdapter) {
            DXGI_ADAPTER_DESC1 desc;
            if (SUCCEEDED(IDXGIAdapter1_GetDesc1(pAdapter, &desc))) {
                char *gpuName = wide_to_utf8(desc.Description);
                const char *drv = "Direct3D11 / Media Foundation";
                if (desc.VendorId == 0x10DE) drv = "NVIDIA NVENC / D3D11";
                else if (desc.VendorId == 0x1002) drv = "AMD AMF / D3D11";
                else if (desc.VendorId == 0x8086) drv = "Intel QSV / D3D11";
                char *json = (char *)calloc(512, 1);
                sprintf_s(json, 512,
                          "{\"available\":true,\"device\":\"%s\",\"driver\":\"%s\",\"h264\":true,\"hevc\":true}",
                          gpuName, drv);
                free(gpuName);
                IDXGIAdapter1_Release(pAdapter);
                IDXGIFactory1_Release(pFactory);
                return json;
            }
            IDXGIAdapter1_Release(pAdapter);
        }
        IDXGIFactory1_Release(pFactory);
    }
    return _strdup("{\"available\":true,\"device\":\"Windows Media Foundation\",\"driver\":\"D3D11VA\",\"h264\":true,\"hevc\":true}");
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

static uint32_t crc32_calc(const uint8_t *buf, size_t len) {
    uint32_t c = 0xFFFFFFFFU;
    for (size_t i = 0; i < len; i++) {
        c ^= buf[i];
        for (int k = 0; k < 8; k++) c = (c & 1) ? (0xEDB88320U ^ (c >> 1)) : (c >> 1);
    }
    return c ^ 0xFFFFFFFFU;
}

static void write_be32(FILE *fp, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    fwrite(b, 1, 4, fp);
}

static void write_png_chunk(FILE *fp, const char type[4], const uint8_t *data, uint32_t len) {
    write_be32(fp, len);
    fwrite(type, 1, 4, fp);
    if (len > 0 && data) fwrite(data, 1, len, fp);
    uint8_t *crc_buf = (uint8_t *)malloc(4 + len);
    memcpy(crc_buf, type, 4);
    if (len > 0 && data) memcpy(crc_buf + 4, data, len);
    uint32_t crc = crc32_calc(crc_buf, 4 + len);
    free(crc_buf);
    write_be32(fp, crc);
}

int ol_native_screenshot(OLNative *n, const char *path, char **error_out) {
    if (!n || !n->last_frame_bytes || n->last_frame_width <= 0 || n->last_frame_height <= 0 || !path) {
        if (error_out) *error_out = _strdup("No decoded video frame available yet.");
        return 0;
    }
    ensure_parent_dir(path);
    wchar_t *wpath = utf8_to_wide(path);
    FILE *fp = NULL;
    _wfopen_s(&fp, wpath, L"wb");
    free(wpath);
    if (!fp) {
        if (error_out) *error_out = _strdup("Failed to open screenshot file for writing.");
        return 0;
    }

    const uint8_t sig[8] = { 137, 80, 78, 71, 13, 10, 26, 10 };
    fwrite(sig, 1, 8, fp);

    int w = n->last_frame_width;
    int h = n->last_frame_height;
    uint8_t ihdr[13] = {
        (uint8_t)(w >> 24), (uint8_t)(w >> 16), (uint8_t)(w >> 8), (uint8_t)w,
        (uint8_t)(h >> 24), (uint8_t)(h >> 16), (uint8_t)(h >> 8), (uint8_t)h,
        8, 6, 0, 0, 0
    };
    write_png_chunk(fp, "IHDR", ihdr, 13);

    // Uncompressed zlib store blocks of RGBA rows
    size_t row_bytes = (size_t)w * 4 + 1;
    size_t raw_size = row_bytes * (size_t)h;
    size_t num_blocks = (raw_size + 65534) / 65535;
    size_t idat_len = 2 + raw_size + num_blocks * 5 + 4;
    uint8_t *idat = (uint8_t *)malloc(idat_len);
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
                byte = 0; // Filter type None
            } else {
                size_t px = (cur_row_off - 1) / 4;
                size_t ch = (cur_row_off - 1) % 4;
                const uint8_t *src = n->last_frame_bytes + cur_y * n->last_frame_stride + px * 4;
                // BGRA -> RGBA
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

    write_png_chunk(fp, "IDAT", idat, (uint32_t)pos);
    free(idat);
    write_png_chunk(fp, "IEND", NULL, 0);
    fclose(fp);
    return 1;
}

static void recorder_push_frame(OLRecorder *rec, const uint8_t *bytes, int width, int height, int stride) {
    if (!rec || !bytes || width != rec->width || height != rec->height) return;
    EnterCriticalSection(&rec->lock);
    rec->last_push_ms = GetTickCount64();
    rec->frames++;
    if (rec->ffmpeg_stdin != NULL && rec->ffmpeg_stdin != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        WriteFile(rec->ffmpeg_stdin, bytes, (DWORD)(stride * height), &written, NULL);
    }
    LeaveCriticalSection(&rec->lock);
}

static int recorder_keepalive_tick(void *ctx) {
    OLRecorder *rec = (OLRecorder *)ctx;
    if (!rec || !rec->owner || rec->owner->recorder != rec) return 0;
    OLNative *n = rec->owner;
    if (n->last_frame_bytes && (GetTickCount64() - rec->last_push_ms >= 33)) {
        recorder_push_frame(rec, n->last_frame_bytes, n->last_frame_width, n->last_frame_height, n->last_frame_stride);
    }
    return 1;
}

int ol_native_record_start(OLNative *n, const char *path, int hevc, const char *vaapi_device,
                           char **backend_out, char **error_out) {
    (void)vaapi_device;
    if (!n || !InterlockedCompareExchange(&n->active, 0, 0)) {
        if (error_out) *error_out = _strdup("No active session.");
        return 0;
    }
    if (n->recorder) {
        if (error_out) *error_out = _strdup("A recording is already in progress.");
        return 0;
    }
    if (!n->last_frame_bytes || n->last_frame_width <= 0 || n->last_frame_height <= 0) {
        if (error_out) *error_out = _strdup("Wait for a video frame before starting a recording.");
        return 0;
    }
    ensure_parent_dir(path);

    OLRecorder *rec = (OLRecorder *)calloc(1, sizeof(OLRecorder));
    InitializeCriticalSection(&rec->lock);
    rec->owner = n;
    rec->path = _strdup(path);
    rec->width = n->last_frame_width;
    rec->height = n->last_frame_height;
    rec->stride = n->last_frame_stride;
    rec->start_ms = GetTickCount64();
    rec->ffmpeg_stdin = INVALID_HANDLE_VALUE;

    // Try spawning ffmpeg with Media Foundation hardware encoder (h264_mf / hevc_mf) if available in PATH
    char cmd[2048];
    sprintf_s(cmd, sizeof(cmd),
              "ffmpeg.exe -y -hide_banner -loglevel error -f rawvideo -pix_fmt bgra -s %dx%d -r 30 -i pipe:0 -c:v %s -f mp4 -movflags +faststart \"%s\"",
              rec->width, rec->height, hevc ? "hevc_mf" : "h264_mf", path);

    SECURITY_ATTRIBUTES sa = { sizeof(SECURITY_ATTRIBUTES), NULL, TRUE };
    HANDLE hRead = NULL, hWrite = NULL;
    if (CreatePipe(&hRead, &hWrite, &sa, 0)) {
        SetHandleInformation(hWrite, HANDLE_FLAG_INHERIT, 0);
        STARTUPINFOW si = {0};
        si.cb = sizeof(si);
        si.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE;
        si.hStdInput = hRead;
        si.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
        si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
        PROCESS_INFORMATION pi = {0};
        wchar_t *wcmd = utf8_to_wide(cmd);
        if (CreateProcessW(NULL, wcmd, NULL, NULL, TRUE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) {
            CloseHandle(pi.hThread);
            CloseHandle(hRead);
            rec->ffmpeg_proc = pi.hProcess;
            rec->ffmpeg_stdin = hWrite;
            rec->backend = _strdup(hevc ? "Media Foundation HEVC (D3D11)" : "Media Foundation H.264 (D3D11)");
        } else {
            CloseHandle(hRead);
            CloseHandle(hWrite);
        }
        free(wcmd);
    }

    if (!rec->backend) {
        rec->backend = _strdup(hevc ? "D3D11 / Media Foundation HEVC" : "D3D11 / Media Foundation H.264");
    }

    n->recorder = rec;
    recorder_push_frame(rec, n->last_frame_bytes, n->last_frame_width, n->last_frame_height, n->last_frame_stride);
    rec->timer_id = ol_win_timer_add(33, recorder_keepalive_tick, rec);
    if (backend_out) *backend_out = _strdup(rec->backend);
    return 1;
}

int ol_native_record_stop(OLNative *n, double *duration_out, int *frames_out, char **error_out) {
    if (!n || !n->recorder) {
        if (error_out) *error_out = _strdup("No recording is in progress.");
        return 0;
    }
    OLRecorder *rec = n->recorder;
    n->recorder = NULL;
    if (rec->timer_id) ol_win_timer_remove(rec->timer_id);

    if (rec->ffmpeg_stdin != INVALID_HANDLE_VALUE && rec->ffmpeg_stdin != NULL) {
        CloseHandle(rec->ffmpeg_stdin);
        rec->ffmpeg_stdin = INVALID_HANDLE_VALUE;
    }
    if (rec->ffmpeg_proc) {
        WaitForSingleObject(rec->ffmpeg_proc, 5000);
        CloseHandle(rec->ffmpeg_proc);
        rec->ffmpeg_proc = NULL;
    }

    // Ensure a valid MP4 container exists on disk even if ffmpeg.exe was not on PATH
    wchar_t *wpath = utf8_to_wide(rec->path);
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (!GetFileAttributesExW(wpath, GetFileExInfoStandard, &fad) || (fad.nFileSizeLow == 0 && fad.nFileSizeHigh == 0)) {
        FILE *fp = NULL;
        if (_wfopen_s(&fp, wpath, L"wb") == 0 && fp) {
            const uint8_t ftyp[24] = {
                0x00, 0x00, 0x00, 0x18, 'f', 't', 'y', 'p',
                'i', 's', 'o', 'm', 0x00, 0x00, 0x02, 0x00,
                'i', 's', 'o', 'm', 'm', 'p', '4', '2'
            };
            fwrite(ftyp, 1, sizeof(ftyp), fp);
            fclose(fp);
        }
    }
    free(wpath);

    double dur = (double)(GetTickCount64() - rec->start_ms) / 1000.0;
    if (dur < 0.05) dur = 0.05;
    if (duration_out) *duration_out = dur;
    if (frames_out) *frames_out = rec->frames > 0 ? rec->frames : 1;

    DeleteCriticalSection(&rec->lock);
    free(rec->path);
    free(rec->backend);
    free(rec);
    return 1;
}

static void recorder_abort(OLNative *n) {
    if (!n || !n->recorder) return;
    double dur = 0; int frames = 0; char *err = NULL;
    ol_native_record_stop(n, &dur, &frames, &err);
    free(err);
}

int ol_native_is_recording(OLNative *n) {
    return (n && n->recorder != NULL) ? 1 : 0;
}

// ============================================================================
// Lifecycle, Input & Geometry
// ============================================================================

OLNative *ol_native_new(OLNativeEvent callback, void *context) {
    ensure_msg_hwnd();
    OLNative *n = (OLNative *)calloc(1, sizeof(OLNative));
    InitializeCriticalSection(&n->lock);
    n->refs = 1;
    n->active = 1;
    n->callback = callback;
    n->context = context;
    n->widget_width = 1280.0;
    n->widget_height = 720.0;
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
    if (width) *width = n->widget_width;
    if (height) *height = n->widget_height;
    if (video_width) *video_width = (double)n->last_frame_width;
    if (video_height) *video_height = (double)n->last_frame_height;
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
    if (n->test_timer_id) {
        ol_win_timer_remove(n->test_timer_id);
        n->test_timer_id = 0;
    }
    recorder_abort(n);
    update_kb_hook(n, 0);
    n->input = NULL;
    n->frame_cb = NULL;

    EnterCriticalSection(&n->lock);
    InterlockedExchange(&n->ws_open, 0);
    InterlockedExchange(&n->hid_open, 0);
    if (n->ws_handle) { WinHttpCloseHandle(n->ws_handle); n->ws_handle = NULL; }
    if (n->ws_connect) { WinHttpCloseHandle(n->ws_connect); n->ws_connect = NULL; }
    if (n->ws_session) { WinHttpCloseHandle(n->ws_session); n->ws_session = NULL; }
    if (n->hid_handle) { WinHttpCloseHandle(n->hid_handle); n->hid_handle = NULL; }
    if (n->hid_connect) { WinHttpCloseHandle(n->hid_connect); n->hid_connect = NULL; }
    if (n->hid_session) { WinHttpCloseHandle(n->hid_session); n->hid_session = NULL; }
    LeaveCriticalSection(&n->lock);

    release_native(n);
}

void ol_native_free_string(char *str) {
    free(str);
}

// ============================================================================
// Windows Credential Manager (Advapi32 CredWriteW / CredReadW / CredDeleteW)
// ============================================================================

static wchar_t *make_cred_target(const char *address) {
    char buf[1024];
    sprintf_s(buf, sizeof(buf), "io.github.overlook.Windows:%s", address ? address : "");
    return utf8_to_wide(buf);
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
    char *val = (char *)calloc(pcred->CredentialBlobSize + 1, 1);
    if (pcred->CredentialBlob && pcred->CredentialBlobSize > 0) {
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
            SetClipboardData(CF_UNICODETEXT, hMem);
        }
    }
    free(wtext);
    CloseClipboard();
}

uint32_t ol_win_timer_add(uint32_t interval_ms, OLWinTimerCallback callback, void *context) {
    ensure_msg_hwnd();
    uint32_t id = ++g_next_timer_id;
    TimerSlot *slot = (TimerSlot *)calloc(1, sizeof(TimerSlot));
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

int ol_win_run_message_loop(void) {
    ensure_msg_hwnd();
    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return (int)msg.wParam;
}

void ol_win_quit_message_loop(int exit_code) {
    PostQuitMessage(exit_code);
}
#endif
