#pragma once
#include <adwaita.h>

// libadwaita adapters (API 1.5, as shipped by Ubuntu 24.04). Signal handlers
// take a retained Swift box; GLib releases it when the instance is destroyed.
typedef void (*OLHandler0)(void *instance, void *box);
typedef void (*OLHandler1)(void *instance, void *argument, void *box);
typedef void (*OLRelease)(void *box);
typedef struct { OLRelease release; void *box; } OLBox;
static inline void ol_box_free(gpointer data, GClosure *closure) { (void)closure; OLBox *b=data; b->release(b->box); g_free(b); }
static inline void ol_connect_box(void *o, const char *name, GCallback cb, void *box, OLRelease release) {
    OLBox *b=g_new0(OLBox,1); b->release=release; b->box=box;
    g_signal_connect_data(o,name,cb,b,ol_box_free,0);
}
static inline void *ol_box_value(void *data) { return ((OLBox *)data)->box; }
static inline void ol_connect0(void *o, const char *name, OLHandler0 cb, void *box, OLRelease release) { ol_connect_box(o,name,G_CALLBACK(cb),box,release); }
static inline void ol_connect1(void *o, const char *name, OLHandler1 cb, void *box, OLRelease release) { ol_connect_box(o,name,G_CALLBACK(cb),box,release); }

static inline void *ad_app(void) { return adw_application_new("io.github.overlook.Linux", G_APPLICATION_DEFAULT_FLAGS); }
static inline void *ad_window(void *app) { return adw_application_window_new(GTK_APPLICATION(app)); }
static inline void ad_window_content(void *w, void *c) { adw_application_window_set_content(ADW_APPLICATION_WINDOW(w), GTK_WIDGET(c)); }
static inline void ad_add_breakpoint(void *window, const char *condition, void *object, const char *property) {
    AdwBreakpoint *b=adw_breakpoint_new(adw_breakpoint_condition_parse(condition));
    GValue value=G_VALUE_INIT; g_value_init(&value,G_TYPE_BOOLEAN); g_value_set_boolean(&value,TRUE);
    adw_breakpoint_add_setter(b,G_OBJECT(object),property,&value); g_value_unset(&value);
    adw_application_window_add_breakpoint(ADW_APPLICATION_WINDOW(window),b);
}
static inline int ad_is_fullscreen(void *w) { return gtk_window_is_fullscreen(GTK_WINDOW(w)); }
static inline void ad_close(void *w) { gtk_window_close(GTK_WINDOW(w)); }

static inline void *ad_toolbar_view(void) { return adw_toolbar_view_new(); }
static inline void ad_toolbar_top(void *v, void *w) { adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(v), GTK_WIDGET(w)); }
static inline void ad_toolbar_content(void *v, void *w) { adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(v), GTK_WIDGET(w)); }
static inline void ad_toolbar_reveal(void *v, int reveal) { adw_toolbar_view_set_reveal_top_bars(ADW_TOOLBAR_VIEW(v), reveal); }
static inline void *ad_header(void) { return adw_header_bar_new(); }
static inline void ad_header_start(void *h, void *w) { adw_header_bar_pack_start(ADW_HEADER_BAR(h), GTK_WIDGET(w)); }
static inline void ad_header_end(void *h, void *w) { adw_header_bar_pack_end(ADW_HEADER_BAR(h), GTK_WIDGET(w)); }
static inline void ad_header_title(void *h, void *w) { adw_header_bar_set_title_widget(ADW_HEADER_BAR(h), GTK_WIDGET(w)); }
static inline void *ad_title(const char *title, const char *subtitle) { return adw_window_title_new(title, subtitle); }
static inline void ad_set_title(void *w, const char *title, const char *subtitle) {
    adw_window_title_set_title(ADW_WINDOW_TITLE(w), title); adw_window_title_set_subtitle(ADW_WINDOW_TITLE(w), subtitle);
}

static inline void *ad_split(void *sidebar, void *content) {
    GtkWidget *s=adw_overlay_split_view_new();
    adw_overlay_split_view_set_sidebar(ADW_OVERLAY_SPLIT_VIEW(s), GTK_WIDGET(sidebar));
    adw_overlay_split_view_set_content(ADW_OVERLAY_SPLIT_VIEW(s), GTK_WIDGET(content));
    return s;
}
static inline void ad_split_show(void *s, int show) { adw_overlay_split_view_set_show_sidebar(ADW_OVERLAY_SPLIT_VIEW(s), show); }
static inline int ad_split_collapsed(void *s) { return adw_overlay_split_view_get_collapsed(ADW_OVERLAY_SPLIT_VIEW(s)); }
static inline void ad_bind(void *source, const char *sp, void *target, const char *tp) {
    g_object_bind_property(source, sp, target, tp, G_BINDING_BIDIRECTIONAL | G_BINDING_SYNC_CREATE);
}

static inline void *ad_toasts(void *child) { GtkWidget *t=adw_toast_overlay_new(); adw_toast_overlay_set_child(ADW_TOAST_OVERLAY(t), GTK_WIDGET(child)); return t; }
static inline void ad_toast(void *overlay, const char *text, int timeout) {
    AdwToast *t=adw_toast_new(text); adw_toast_set_use_markup(t, FALSE); adw_toast_set_timeout(t, timeout);
    adw_toast_overlay_add_toast(ADW_TOAST_OVERLAY(overlay), t);
}

static inline void *ad_status(const char *icon, const char *title, const char *description) {
    GtkWidget *s=adw_status_page_new();
    adw_status_page_set_icon_name(ADW_STATUS_PAGE(s), icon);
    adw_status_page_set_title(ADW_STATUS_PAGE(s), title);
    char *escaped=g_markup_escape_text(description, -1);
    adw_status_page_set_description(ADW_STATUS_PAGE(s), escaped); g_free(escaped);
    return s;
}
static inline void ad_status_child(void *s, void *c) { adw_status_page_set_child(ADW_STATUS_PAGE(s), GTK_WIDGET(c)); }
static inline void *ad_clamp(void *child, int size) { GtkWidget *c=adw_clamp_new(); adw_clamp_set_maximum_size(ADW_CLAMP(c), size); adw_clamp_set_child(ADW_CLAMP(c), GTK_WIDGET(child)); return c; }

static inline void *ad_group(const char *title) {
    GtkWidget *g=adw_preferences_group_new();
    if (title) {
        char *esc=g_markup_escape_text(title, -1);
        adw_preferences_group_set_title(ADW_PREFERENCES_GROUP(g), esc);
        g_free(esc);
    }
    return g;
}
static inline void ad_group_add(void *g, void *w) { adw_preferences_group_add(ADW_PREFERENCES_GROUP(g), GTK_WIDGET(w)); }
static inline void *ad_entry_row(const char *title) {
    GtkWidget *r=adw_entry_row_new();
    char *esc=g_markup_escape_text(title ? title : "", -1);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(r), esc);
    g_free(esc);
    return r;
}
static inline void *ad_password_row(const char *title) {
    GtkWidget *r=adw_password_entry_row_new();
    char *esc=g_markup_escape_text(title ? title : "", -1);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(r), esc);
    g_free(esc);
    return r;
}
static inline void ad_entry_suffix(void *r, void *w) { adw_entry_row_add_suffix(ADW_ENTRY_ROW(r), GTK_WIDGET(w)); }
static inline void ad_entry_purpose(void *r, int digits) { adw_entry_row_set_input_purpose(ADW_ENTRY_ROW(r), digits ? GTK_INPUT_PURPOSE_DIGITS : GTK_INPUT_PURPOSE_URL); }

static inline void *ad_icon_button(const char *icon, const char *tooltip) {
    GtkWidget *b=gtk_button_new_from_icon_name(icon); gtk_widget_set_tooltip_text(b, tooltip); return b;
}
static inline void *ad_toggle_button(const char *icon, const char *tooltip) {
    GtkWidget *b=gtk_toggle_button_new(); gtk_button_set_icon_name(GTK_BUTTON(b), icon); gtk_widget_set_tooltip_text(b, tooltip); return b;
}
static inline void ad_action_name(void *w, const char *action) { gtk_actionable_set_action_name(GTK_ACTIONABLE(w), action); }
static inline void *ad_menu_button(const char *icon, const char *tooltip, void *menu, int primary) {
    GtkWidget *b=gtk_menu_button_new();
    gtk_menu_button_set_icon_name(GTK_MENU_BUTTON(b), icon);
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(b), G_MENU_MODEL(menu));
    gtk_menu_button_set_primary(GTK_MENU_BUTTON(b), primary);
    gtk_widget_set_tooltip_text(b, tooltip);
    g_object_unref(menu);
    return b;
}
static inline void *ad_menu(void) { return g_menu_new(); }
static inline void ad_menu_item(void *m, const char *label, const char *action) { g_menu_append(G_MENU(m), label, action); }
static inline void ad_menu_section(void *m, void *section) { g_menu_append_section(G_MENU(m), NULL, G_MENU_MODEL(section)); g_object_unref(section); }

static inline void *ad_action(void *map, const char *name) {
    GSimpleAction *a=g_simple_action_new(name, NULL); g_action_map_add_action(G_ACTION_MAP(map), G_ACTION(a)); g_object_unref(a); return a;
}
static inline void ad_action_enabled(void *a, int enabled) { g_simple_action_set_enabled(G_SIMPLE_ACTION(a), enabled); }
static inline void ad_accel(void *app, const char *action, const char *accel) {
    const char *accels[]={accel, NULL}; gtk_application_set_accels_for_action(GTK_APPLICATION(app), action, accels);
}

static inline void *ad_list(void) {
    GtkWidget *l=gtk_list_box_new(); gtk_widget_add_css_class(l, "navigation-sidebar");
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(l), GTK_SELECTION_SINGLE); return l;
}
static inline void ad_list_placeholder(void *l, void *w) { gtk_list_box_set_placeholder(GTK_LIST_BOX(l), GTK_WIDGET(w)); }
static inline void ad_list_append(void *l, void *row) { gtk_list_box_append(GTK_LIST_BOX(l), GTK_WIDGET(row)); }
static inline void ad_list_clear(void *l) { gtk_list_box_remove_all(GTK_LIST_BOX(l)); }
static inline void ad_list_select(void *l, void *row) { if (row) gtk_list_box_select_row(GTK_LIST_BOX(l), GTK_LIST_BOX_ROW(row)); else gtk_list_box_unselect_all(GTK_LIST_BOX(l)); }
static inline void *ad_list_row(void *child) { GtkWidget *r=gtk_list_box_row_new(); gtk_list_box_row_set_child(GTK_LIST_BOX_ROW(r), GTK_WIDGET(child)); return r; }

static inline void *ad_label(const char *text, const char *css) {
    GtkWidget *l=gtk_label_new(text); gtk_label_set_xalign(GTK_LABEL(l), 0);
    gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
    if (css) gtk_widget_add_css_class(l, css); return l;
}
static inline void *ad_wrap_label(const char *text, const char *css) {
    GtkWidget *l=gtk_label_new(text); gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    gtk_label_set_justify(GTK_LABEL(l), GTK_JUSTIFY_CENTER);
    if (css) gtk_widget_add_css_class(l, css); return l;
}
static inline void *ad_fingerprint(const char *text) {
    GtkWidget *l=gtk_label_new(text); gtk_label_set_selectable(GTK_LABEL(l), TRUE);
    gtk_label_set_wrap(GTK_LABEL(l), TRUE); gtk_label_set_wrap_mode(GTK_LABEL(l), PANGO_WRAP_CHAR);
    gtk_label_set_justify(GTK_LABEL(l), GTK_JUSTIFY_CENTER);
    gtk_widget_add_css_class(l, "monospace"); gtk_widget_add_css_class(l, "caption"); return l;
}
static inline void ad_min_size(void *w, int width, int height) { gtk_widget_set_size_request(GTK_WIDGET(w), width, height); }
static inline void *ad_mnemonic_button(const char *label) { return gtk_button_new_with_mnemonic(label); }
static inline void ad_css(void *w, const char *css) { gtk_widget_add_css_class(GTK_WIDGET(w), css); }
static inline void ad_align(void *w, int halign, int valign) { gtk_widget_set_halign(GTK_WIDGET(w), (GtkAlign)halign); gtk_widget_set_valign(GTK_WIDGET(w), (GtkAlign)valign); }
static inline void ad_focus(void *w) { gtk_widget_grab_focus(GTK_WIDGET(w)); }
static inline void ad_sensitive(void *w, int enabled) { gtk_widget_set_sensitive(GTK_WIDGET(w), enabled); }

static inline void *ad_stack(void) { GtkWidget *s=gtk_stack_new(); gtk_stack_set_transition_type(GTK_STACK(s), GTK_STACK_TRANSITION_TYPE_CROSSFADE); return s; }
static inline void ad_stack_add(void *s, void *w, const char *name) { gtk_stack_add_named(GTK_STACK(s), GTK_WIDGET(w), name); }
static inline void ad_stack_show(void *s, const char *name) { gtk_stack_set_visible_child_name(GTK_STACK(s), name); }
static inline void *ad_overlay(void *child) { GtkWidget *o=gtk_overlay_new(); gtk_overlay_set_child(GTK_OVERLAY(o), GTK_WIDGET(child)); return o; }
static inline void ad_overlay_add(void *o, void *w) { gtk_overlay_add_overlay(GTK_OVERLAY(o), GTK_WIDGET(w)); }
static inline void *ad_spinner(void) { GtkWidget *s=gtk_spinner_new(); gtk_widget_set_size_request(s, 32, 32); gtk_widget_set_halign(s, GTK_ALIGN_CENTER); gtk_widget_set_valign(s, GTK_ALIGN_CENTER); gtk_widget_set_can_target(s, FALSE); return s; }
static inline void ad_spin(void *s, int spinning) { gtk_spinner_set_spinning(GTK_SPINNER(s), spinning); gtk_widget_set_visible(GTK_WIDGET(s), spinning); }

static inline void *ad_alert(const char *heading, const char *body) { return adw_alert_dialog_new(heading, body); }
static inline void ad_alert_response(void *d, const char *id, const char *label, int appearance) {
    adw_alert_dialog_add_response(ADW_ALERT_DIALOG(d), id, label);
    adw_alert_dialog_set_response_appearance(ADW_ALERT_DIALOG(d), id, (AdwResponseAppearance)appearance);
}
static inline void ad_alert_defaults(void *d, const char *default_response, const char *close_response) {
    adw_alert_dialog_set_default_response(ADW_ALERT_DIALOG(d), default_response);
    adw_alert_dialog_set_close_response(ADW_ALERT_DIALOG(d), close_response);
}
static inline void ad_alert_extra(void *d, void *w) { adw_alert_dialog_set_extra_child(ADW_ALERT_DIALOG(d), GTK_WIDGET(w)); }
static inline void ad_present(void *d, void *parent) { adw_dialog_present(ADW_DIALOG(d), GTK_WIDGET(parent)); }
static inline void ad_about(void *parent, const char *version) {
    AdwDialog *a=adw_about_dialog_new();
    adw_about_dialog_set_application_name(ADW_ABOUT_DIALOG(a), "Overlook");
    adw_about_dialog_set_application_icon(ADW_ABOUT_DIALOG(a), "video-display");
    adw_about_dialog_set_developer_name(ADW_ABOUT_DIALOG(a), "Ross Cawston");
    adw_about_dialog_set_version(ADW_ABOUT_DIALOG(a), version);
    adw_about_dialog_set_comments(ADW_ABOUT_DIALOG(a), "Remote console for PiKVM and GL.iNet Comet / GLKVM devices.");
    adw_about_dialog_set_license_type(ADW_ABOUT_DIALOG(a), GTK_LICENSE_GPL_3_0);
    adw_dialog_present(a, GTK_WIDGET(parent));
}

static inline char *ad_certificate_sha256(void *certificate) {
    GByteArray *der=NULL; g_object_get(certificate, "certificate", &der, NULL);
    if (!der) return NULL;
    char *hex=g_compute_checksum_for_data(G_CHECKSUM_SHA256, der->data, der->len);
    g_byte_array_unref(der); return hex;
}

static inline void ad_remove_css(void *w, const char *css) { gtk_widget_remove_css_class(GTK_WIDGET(w), css); }
static inline void ad_button_icon(void *b, const char *icon) { gtk_button_set_icon_name(GTK_BUTTON(b), icon); }
static inline void ad_tooltip(void *w, const char *tooltip) { gtk_widget_set_tooltip_text(GTK_WIDGET(w), tooltip); }

static inline void ad_style_color_scheme(int scheme) {
    AdwColorScheme cs = ADW_COLOR_SCHEME_DEFAULT;
    if (scheme == 1) cs = ADW_COLOR_SCHEME_FORCE_LIGHT;
    else if (scheme == 2) cs = ADW_COLOR_SCHEME_FORCE_DARK;
    adw_style_manager_set_color_scheme(adw_style_manager_get_default(), cs);
}

static inline void *ad_prefs_dialog(const char *title, int width, int height) {
    AdwDialog *d = adw_preferences_dialog_new();
    if (title) adw_dialog_set_title(d, title);
    adw_dialog_set_content_width(d, width);
    adw_dialog_set_content_height(d, height);
    adw_preferences_dialog_set_search_enabled(ADW_PREFERENCES_DIALOG(d), TRUE);
    return d;
}
static inline void ad_prefs_dialog_add(void *d, void *page) {
    adw_preferences_dialog_add(ADW_PREFERENCES_DIALOG(d), ADW_PREFERENCES_PAGE(page));
}
static inline void ad_prefs_dialog_toast(void *d, const char *text) {
    AdwToast *t = adw_toast_new(text);
    adw_toast_set_use_markup(t, FALSE);
    adw_toast_set_timeout(t, 4);
    adw_preferences_dialog_add_toast(ADW_PREFERENCES_DIALOG(d), t);
}
static inline void *ad_prefs_page(const char *title, const char *icon) {
    GtkWidget *p = adw_preferences_page_new();
    if (title) adw_preferences_page_set_title(ADW_PREFERENCES_PAGE(p), title);
    if (icon) adw_preferences_page_set_icon_name(ADW_PREFERENCES_PAGE(p), icon);
    return p;
}
static inline void ad_prefs_page_add(void *page, void *group) {
    adw_preferences_page_add(ADW_PREFERENCES_PAGE(page), ADW_PREFERENCES_GROUP(group));
}
static inline void *ad_group_desc(const char *title, const char *description) {
    GtkWidget *g = adw_preferences_group_new();
    if (title) {
        char *et = g_markup_escape_text(title, -1);
        adw_preferences_group_set_title(ADW_PREFERENCES_GROUP(g), et);
        g_free(et);
    }
    if (description) {
        char *esc = g_markup_escape_text(description, -1);
        adw_preferences_group_set_description(ADW_PREFERENCES_GROUP(g), esc);
        g_free(esc);
    }
    return g;
}

static inline void *ad_action_row(const char *title, const char *subtitle) {
    GtkWidget *r = adw_action_row_new();
    char *et = g_markup_escape_text(title ? title : "", -1);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(r), et);
    g_free(et);
    if (subtitle) {
        char *es = g_markup_escape_text(subtitle, -1);
        adw_action_row_set_subtitle(ADW_ACTION_ROW(r), es);
        g_free(es);
    }
    adw_action_row_set_subtitle_selectable(ADW_ACTION_ROW(r), TRUE);
    return r;
}
static inline void ad_action_row_subtitle(void *r, const char *subtitle) {
    char *es = g_markup_escape_text(subtitle ? subtitle : "", -1);
    adw_action_row_set_subtitle(ADW_ACTION_ROW(r), es);
    g_free(es);
}
static inline void ad_action_row_suffix(void *r, void *w) {
    adw_action_row_add_suffix(ADW_ACTION_ROW(r), GTK_WIDGET(w));
}
static inline void ad_action_row_prefix(void *r, void *w) {
    adw_action_row_add_prefix(ADW_ACTION_ROW(r), GTK_WIDGET(w));
}

static inline void *ad_switch_row(const char *title, const char *subtitle, int active) {
    GtkWidget *r = adw_switch_row_new();
    char *et = g_markup_escape_text(title ? title : "", -1);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(r), et);
    g_free(et);
    if (subtitle) {
        char *es = g_markup_escape_text(subtitle, -1);
        adw_action_row_set_subtitle(ADW_ACTION_ROW(r), es);
        g_free(es);
    }
    adw_switch_row_set_active(ADW_SWITCH_ROW(r), active ? TRUE : FALSE);
    return r;
}
static inline int ad_switch_get(void *r) {
    return adw_switch_row_get_active(ADW_SWITCH_ROW(r)) ? 1 : 0;
}
static inline void ad_switch_set(void *r, int active) {
    adw_switch_row_set_active(ADW_SWITCH_ROW(r), active ? TRUE : FALSE);
}

static inline void *ad_spin_row(const char *title, const char *subtitle, double min, double max, double step, int digits, double value) {
    GtkWidget *r = adw_spin_row_new_with_range(min, max, step);
    char *et = g_markup_escape_text(title ? title : "", -1);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(r), et);
    g_free(et);
    if (subtitle) {
        char *es = g_markup_escape_text(subtitle, -1);
        adw_action_row_set_subtitle(ADW_ACTION_ROW(r), es);
        g_free(es);
    }
    adw_spin_row_set_digits(ADW_SPIN_ROW(r), (guint)digits);
    adw_spin_row_set_value(ADW_SPIN_ROW(r), value);
    return r;
}
static inline double ad_spin_get(void *r) {
    return adw_spin_row_get_value(ADW_SPIN_ROW(r));
}
static inline void ad_spin_set(void *r, double value) {
    adw_spin_row_set_value(ADW_SPIN_ROW(r), value);
}
static inline void ad_spin_range(void *r, double min, double max) {
    adw_spin_row_set_range(ADW_SPIN_ROW(r), min, max);
}

static inline void *ad_combo_row(const char *title, const char *subtitle) {
    GtkWidget *r = adw_combo_row_new();
    char *et = g_markup_escape_text(title ? title : "", -1);
    adw_preferences_row_set_title(ADW_PREFERENCES_ROW(r), et);
    g_free(et);
    if (subtitle) {
        char *es = g_markup_escape_text(subtitle, -1);
        adw_action_row_set_subtitle(ADW_ACTION_ROW(r), es);
        g_free(es);
    }
    GtkStringList *list = gtk_string_list_new(NULL);
    adw_combo_row_set_model(ADW_COMBO_ROW(r), G_LIST_MODEL(list));
    g_object_unref(list);
    return r;
}
static inline void ad_combo_clear(void *r) {
    GtkStringList *list = gtk_string_list_new(NULL);
    adw_combo_row_set_model(ADW_COMBO_ROW(r), G_LIST_MODEL(list));
    g_object_unref(list);
}
static inline void ad_combo_append(void *r, const char *item) {
    GListModel *m = adw_combo_row_get_model(ADW_COMBO_ROW(r));
    if (m && GTK_IS_STRING_LIST(m)) gtk_string_list_append(GTK_STRING_LIST(m), item);
}
static inline int ad_combo_get(void *r) {
    guint sel = adw_combo_row_get_selected(ADW_COMBO_ROW(r));
    return sel == GTK_INVALID_LIST_POSITION ? -1 : (int)sel;
}
static inline void ad_combo_set(void *r, int index) {
    if (index >= 0) adw_combo_row_set_selected(ADW_COMBO_ROW(r), (guint)index);
}

static inline void *ad_dialog(const char *title, void *content, int width, int height) {
    AdwDialog *d = adw_dialog_new();
    if (title) adw_dialog_set_title(d, title);
    adw_dialog_set_content_width(d, width);
    adw_dialog_set_content_height(d, height);
    GtkWidget *tb = adw_toolbar_view_new();
    GtkWidget *hb = adw_header_bar_new();
    adw_toolbar_view_add_top_bar(ADW_TOOLBAR_VIEW(tb), hb);
    adw_toolbar_view_set_content(ADW_TOOLBAR_VIEW(tb), GTK_WIDGET(content));
    adw_dialog_set_child(d, tb);
    return d;
}
static inline void ad_dialog_close(void *d) { adw_dialog_close(ADW_DIALOG(d)); }
