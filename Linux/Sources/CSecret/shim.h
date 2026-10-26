#pragma once
#include <libsecret/secret.h>

// Fixed-argument adapters for libsecret's variadic API (not callable from Swift).
static inline const SecretSchema *ol_secret_schema(void) {
    static const SecretSchema schema = {
        "io.github.overlook.Linux.Password", SECRET_SCHEMA_NONE,
        { {"address", SECRET_SCHEMA_ATTRIBUTE_STRING}, {NULL, 0} }
    };
    return &schema;
}

static inline void ol_secret_error(GError *error, char **message) {
    if (error) {
        *message = g_strdup(error->message);
        g_error_free(error);
    }
}

static inline char *ol_secret_lookup(const char *address, char **message) {
    GError *error = NULL;
    char *value = secret_password_lookup_sync(ol_secret_schema(), NULL, &error, "address", address, NULL);
    ol_secret_error(error, message);
    return value;
}

static inline int ol_secret_store(const char *address, const char *value, char **message) {
    GError *error = NULL;
    gboolean ok = secret_password_store_sync(ol_secret_schema(), SECRET_COLLECTION_DEFAULT,
        "Overlook KVM password", value, NULL, &error, "address", address, NULL);
    ol_secret_error(error, message);
    return ok;
}

static inline int ol_secret_clear(const char *address, char **message) {
    GError *error = NULL;
    gboolean ok = secret_password_clear_sync(ol_secret_schema(), NULL, &error, "address", address, NULL);
    ol_secret_error(error, message);
    return ok;
}

static inline void ol_secret_password_free(char *value) { secret_password_free(value); }
static inline void ol_secret_message_free(char *value) { g_free(value); }
