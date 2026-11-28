// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// SPDX-FileCopyrightText: 2026 Zachary Gorak
#include "CompilerIndex.h"
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>

// The compiler that wrote the index supplies this stable libIndexStore C API.
// Load it on demand so running the selector never requires a particular Xcode.
typedef struct { const char *data; size_t length; } StringRef;
typedef struct {
    void *(*store_create)(const char *, void **);
    void (*store_dispose)(void *);
    size_t (*store_get_unit_name_from_output_path)(void *, const char *, char *, size_t);
    void *(*unit_reader_create)(void *, const char *, void **);
    void (*unit_reader_dispose)(void *);
    StringRef (*unit_reader_get_module_name)(void *);
    StringRef (*unit_reader_get_main_file)(void *);
    StringRef (*unit_reader_get_output_file)(void *);
    bool (*unit_reader_dependencies_apply_f)(void *, void *, bool (*)(void *, void *));
    int (*unit_dependency_get_kind)(void *);
    StringRef (*unit_dependency_get_filepath)(void *);
    StringRef (*unit_dependency_get_name)(void *);
    void *(*record_reader_create)(void *, const char *, void **);
    void (*record_reader_dispose)(void *);
    bool (*record_reader_occurrences_apply_f)(void *, void *, bool (*)(void *, void *));
    void (*occurrence_get_line_col)(void *, unsigned *, unsigned *);
    uint64_t (*occurrence_get_roles)(void *);
    void *(*occurrence_get_symbol)(void *);
    StringRef (*symbol_get_usr)(void *);
} IndexAPI;

static bool equals(StringRef str, const char *s) {
    return str.data && str.length == strlen(s) && memcmp(str.data, s, str.length) == 0;
}

typedef struct {
    IndexAPI api;
    const char *source;
    void *store;
    unsigned matches;
    bool complete;
    void *context;
    STSIndexReference visit;
} Reader;

static bool occurrence(void *context, void *item) {
    Reader *r = context;
    unsigned line = 0, column = 0;
    r->api.occurrence_get_line_col(item, &line, &column);
    StringRef usr = r->api.symbol_get_usr(r->api.occurrence_get_symbol(item));
    r->visit(r->context, line, column, usr.data, usr.length, r->api.occurrence_get_roles(item));
    return true;
}

static bool dependency(void *context, void *dep) {
    Reader *r = context;
    if (r->api.unit_dependency_get_kind(dep) != 2 ||
        !equals(r->api.unit_dependency_get_filepath(dep), r->source)) return true;
    ++r->matches;
    StringRef name = r->api.unit_dependency_get_name(dep);
    char *key = name.data ? strndup(name.data, name.length) : NULL;
    void *record = key ? r->api.record_reader_create(r->store, key, NULL) : NULL;
    free(key);
    if (record) {
        r->complete = r->api.record_reader_occurrences_apply_f(record, r, occurrence);
        r->api.record_reader_dispose(record);
    }
    return true;
}

bool sts_read_index(const char *library, const char *store, const char *output,
                    const char *module, const char *source, void *context, STSIndexReference visit) {
    void *lib = dlopen(library, RTLD_LOCAL | RTLD_LAZY);
    if (!lib) return false;
    Reader r = {.source = source, .context = context, .visit = visit};
    bool ok = false;
    void *unit = NULL;
#define LOAD(field) if (!(r.api.field = dlsym(lib, "indexstore_" #field))) goto done
    LOAD(store_create); LOAD(store_dispose); LOAD(store_get_unit_name_from_output_path);
    LOAD(unit_reader_create); LOAD(unit_reader_dispose); LOAD(unit_reader_get_module_name);
    LOAD(unit_reader_get_main_file); LOAD(unit_reader_get_output_file); LOAD(unit_reader_dependencies_apply_f);
    LOAD(unit_dependency_get_kind); LOAD(unit_dependency_get_filepath); LOAD(unit_dependency_get_name);
    LOAD(record_reader_create); LOAD(record_reader_dispose); LOAD(record_reader_occurrences_apply_f);
    LOAD(occurrence_get_line_col); LOAD(occurrence_get_roles); LOAD(occurrence_get_symbol); LOAD(symbol_get_usr);
#undef LOAD
    r.store = r.api.store_create(store, NULL);
    if (!r.store) goto done;
    char name[1024] = {0};
    size_t length = r.api.store_get_unit_name_from_output_path(r.store, output, name, sizeof(name));
    if (!length || length >= sizeof(name)) goto done;
    unit = r.api.unit_reader_create(r.store, name, NULL);
    if (!unit || !equals(r.api.unit_reader_get_module_name(unit), module) ||
        !equals(r.api.unit_reader_get_main_file(unit), source) ||
        !equals(r.api.unit_reader_get_output_file(unit), output)) goto done;
    ok = r.api.unit_reader_dependencies_apply_f(unit, &r, dependency) && r.matches == 1 && r.complete;
done:
    if (unit) r.api.unit_reader_dispose(unit);
    if (r.store) r.api.store_dispose(r.store);
    dlclose(lib);
    return ok;
}
