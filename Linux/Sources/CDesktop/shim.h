#pragma once
#include <gtk/gtk.h>
#include <webkit/webkit.h>
#include "adw.h"

// Swift imports the real GTK4/WebKitGTK C ABI. These small adapters handle C
// macros, GObject casts and varargs, which cannot be called directly from Swift.
typedef void (*OLAction)(void *, void *);
typedef void (*OLLoad)(void *, int, void *);
typedef int (*OLFailure)(void *, int, const char *, GError *, void *);
typedef int (*OLTLS)(void *, const char *, void *, unsigned int, void *);
typedef int (*OLPolicy)(void *, void *, int, void *);
static inline void *ol_app(void) { return gtk_application_new("io.github.overlook.Linux", G_APPLICATION_DEFAULT_FLAGS); }
static inline void ol_signal(void *o, const char *name, OLAction cb, void *ctx) { g_signal_connect(o, name, G_CALLBACK(cb), ctx); }
static inline int ol_run(void *app) { return g_application_run(G_APPLICATION(app), 0, NULL); }
static inline void ol_quit(void *app) { g_application_quit(G_APPLICATION(app)); }
static inline void ol_unref(void *o) { g_object_unref(o); }
static inline void *ol_ref(void *o) { return g_object_ref(o); }
static inline void *ol_window(void *app) { return gtk_application_window_new(GTK_APPLICATION(app)); }
static inline void ol_title(void *w, const char *s) { gtk_window_set_title(GTK_WINDOW(w), s); }
static inline void ol_size(void *w, int x, int y) { gtk_window_set_default_size(GTK_WINDOW(w), x, y); }
static inline void ol_child(void *w, void *c) { gtk_window_set_child(GTK_WINDOW(w), GTK_WIDGET(c)); }
static inline void ol_present(void *w) { gtk_window_present(GTK_WINDOW(w)); }
static inline void ol_fullscreen(void *w, int enabled) { if (enabled) gtk_window_fullscreen(GTK_WINDOW(w)); else gtk_window_unfullscreen(GTK_WINDOW(w)); }
static inline void *ol_box(int vertical, int spacing) { return gtk_box_new(vertical ? GTK_ORIENTATION_VERTICAL : GTK_ORIENTATION_HORIZONTAL, spacing); }
static inline void ol_append(void *b, void *w) { gtk_box_append(GTK_BOX(b), GTK_WIDGET(w)); }
static inline void ol_remove(void *b, void *w) { gtk_box_remove(GTK_BOX(b), GTK_WIDGET(w)); }
static inline void *ol_first(void *w) { return gtk_widget_get_first_child(GTK_WIDGET(w)); }
static inline void *ol_next(void *w) { return gtk_widget_get_next_sibling(GTK_WIDGET(w)); }
static inline void ol_expand(void *w, int horizontal, int vertical) { gtk_widget_set_hexpand(w, horizontal); gtk_widget_set_vexpand(w, vertical); }
static inline void ol_visible(void *w, int show) { gtk_widget_set_visible(w, show); }
static inline void ol_margin(void *w, int n) { gtk_widget_set_margin_start(w,n); gtk_widget_set_margin_end(w,n); gtk_widget_set_margin_top(w,n); gtk_widget_set_margin_bottom(w,n); }
static inline void *ol_label(const char *s) { GtkWidget *w=gtk_label_new(s); gtk_label_set_wrap(GTK_LABEL(w), TRUE); gtk_label_set_xalign(GTK_LABEL(w), 0); return w; }
static inline void ol_text(void *w, const char *s) { gtk_label_set_text(GTK_LABEL(w), s); }
static inline void *ol_button(const char *s) { return gtk_button_new_with_label(s); }
static inline void *ol_entry(const char *placeholder) { GtkWidget *e=gtk_entry_new(); gtk_entry_set_placeholder_text(GTK_ENTRY(e), placeholder); return e; }
static inline void *ol_password(const char *placeholder) { GtkWidget *e=ol_entry(placeholder); gtk_entry_set_visibility(GTK_ENTRY(e),FALSE); return e; }
static inline const char *ol_value(void *e) { return gtk_editable_get_text(GTK_EDITABLE(e)); }
static inline void ol_set_value(void *e, const char *s) { gtk_editable_set_text(GTK_EDITABLE(e), s); }
static inline void *ol_scroll(void *child) { GtkWidget *s=gtk_scrolled_window_new(); gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(s), child); return s; }
static inline void *ol_web(void) {
    WebKitNetworkSession *session=webkit_network_session_new_ephemeral();
    GtkWidget *web=g_object_new(WEBKIT_TYPE_WEB_VIEW, "network-session", session, NULL);
    g_object_unref(session);
    WebKitSettings *settings=webkit_web_view_get_settings(WEBKIT_WEB_VIEW(web));
    webkit_settings_set_enable_webrtc(settings, TRUE);
    webkit_settings_set_enable_fullscreen(settings, TRUE);
    return web;
}
static inline void ol_load(void *w, const char *uri) { webkit_web_view_load_uri(WEBKIT_WEB_VIEW(w), uri); }
static inline void ol_html(void *w, const char *html) { webkit_web_view_load_html(WEBKIT_WEB_VIEW(w), html, NULL); }
static inline void ol_reload(void *w) { webkit_web_view_reload(WEBKIT_WEB_VIEW(w)); }
static inline const char *ol_uri(void *w) { return webkit_web_view_get_uri(WEBKIT_WEB_VIEW(w)); }
static inline void ol_on_load(void *w, OLLoad cb, void *c) { g_signal_connect(w,"load-changed",G_CALLBACK(cb),c); }
static inline void ol_on_failure(void *w, OLFailure cb, void *c) { g_signal_connect(w,"load-failed",G_CALLBACK(cb),c); }
static inline void ol_on_tls(void *w, OLTLS cb, void *c) { g_signal_connect(w,"load-failed-with-tls-errors",G_CALLBACK(cb),c); }
static inline void ol_on_policy(void *w, OLPolicy cb, void *c) { g_signal_connect(w,"decide-policy",G_CALLBACK(cb),c); }
static inline const char *ol_policy_uri(void *decision) {
    WebKitNavigationAction *action=webkit_navigation_policy_decision_get_navigation_action(WEBKIT_NAVIGATION_POLICY_DECISION(decision));
    return webkit_uri_request_get_uri(webkit_navigation_action_get_request(action));
}
static inline void ol_ignore(void *decision) { webkit_policy_decision_ignore(WEBKIT_POLICY_DECISION(decision)); }
static inline void ol_trust(void *w, void *cert, const char *host) {
    webkit_network_session_allow_tls_certificate_for_host(webkit_web_view_get_network_session(WEBKIT_WEB_VIEW(w)), G_TLS_CERTIFICATE(cert), host);
}
