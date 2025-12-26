/*
 * MquickjsEx NIF Implementation
 *
 * Embeds MQuickJS JavaScript engine into Elixir via NIFs.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/mman.h>

#include "erl_nif.h"
#include "vendor/mquickjs.h"
#include "vendor/mquickjs_priv.h"

/* ============================================================================
 * C functions required by the stdlib (print, Date.now, performance.now)
 * These MUST be defined before including mquickjs_ex_stdlib.h
 * ============================================================================ */

static JSValue js_print(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    int i;
    JSValue v;

    for (i = 0; i < argc; i++) {
        if (i != 0)
            putchar(' ');
        v = argv[i];
        if (JS_IsString(ctx, v)) {
            JSCStringBuf buf;
            const char *str;
            size_t len;
            str = JS_ToCStringLen(ctx, &len, v, &buf);
            fwrite(str, 1, len, stdout);
        } else {
            JS_PrintValueF(ctx, argv[i], JS_DUMP_LONG);
        }
    }
    putchar('\n');
    return JS_UNDEFINED;
}

static JSValue js_date_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return JS_NewInt64(ctx, (int64_t)tv.tv_sec * 1000 + (tv.tv_usec / 1000));
}

static JSValue js_performance_now(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return JS_NewInt64(ctx, (int64_t)tv.tv_sec * 1000 + (tv.tv_usec / 1000));
}

/* Now include the generated stdlib header */
#include "mquickjs_ex_stdlib.h"

/* ============================================================================
 * NIF Functions
 * ============================================================================ */

/* NIF resource type for JS context */
static ErlNifResourceType *JS_CONTEXT_TYPE;

/* Maximum recursion depth for nested structures */
#define MAX_SERIALIZE_DEPTH 100

typedef struct {
    uint8_t *mem_buf;
    size_t mem_size;
    JSContext *ctx;
} JsContext;

static void js_log_func(void *opaque, const void *buf, size_t buf_len)
{
    fwrite(buf, 1, buf_len, stdout);
}

/* ============================================================================
 * JS → Elixir Type Conversion
 * ============================================================================ */

/* Forward declaration for recursion */
static ERL_NIF_TERM js_to_erl(ErlNifEnv *env, JSContext *ctx, JSValue val, int depth);

/* Convert JS array to Elixir list */
static ERL_NIF_TERM js_array_to_erl(ErlNifEnv *env, JSContext *ctx, JSValue arr, int depth)
{
    JSGCRef arr_ref, len_ref;
    JSValue *arr_val, *len_val;

    if (depth > MAX_SERIALIZE_DEPTH) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "max_depth_exceeded"));
    }

    /* Protect the array value from GC */
    arr_val = JS_PushGCRef(ctx, &arr_ref);
    *arr_val = arr;

    len_val = JS_PushGCRef(ctx, &len_ref);
    *len_val = js_array_get_length(ctx, arr_val, 0, NULL);

    if (JS_IsException(*len_val)) {
        JS_PopGCRef(ctx, &len_ref);
        JS_PopGCRef(ctx, &arr_ref);
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "array_length_failed"));
    }

    int len;
    if (JS_ToInt32(ctx, &len, *len_val) < 0 || len < 0) {
        JS_PopGCRef(ctx, &len_ref);
        JS_PopGCRef(ctx, &arr_ref);
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "invalid_array_length"));
    }

    JS_PopGCRef(ctx, &len_ref);

    /* Build list in reverse, then reverse at end (standard pattern) */
    ERL_NIF_TERM list = enif_make_list(env, 0);

    for (int i = len - 1; i >= 0; i--) {
        JSGCRef elem_ref;
        JSValue *elem_val = JS_PushGCRef(ctx, &elem_ref);
        *elem_val = JS_GetPropertyUint32(ctx, *arr_val, (uint32_t)i);

        if (JS_IsException(*elem_val)) {
            JS_PopGCRef(ctx, &elem_ref);
            JS_PopGCRef(ctx, &arr_ref);
            return enif_make_tuple2(env,
                enif_make_atom(env, "error"),
                enif_make_atom(env, "array_element_failed"));
        }

        ERL_NIF_TERM elem_term = js_to_erl(env, ctx, *elem_val, depth + 1);
        JS_PopGCRef(ctx, &elem_ref);

        /* Check if nested conversion failed */
        if (enif_is_tuple(env, elem_term)) {
            int arity;
            const ERL_NIF_TERM *tuple;
            if (enif_get_tuple(env, elem_term, &arity, &tuple) && arity == 2) {
                if (enif_is_identical(tuple[0], enif_make_atom(env, "error"))) {
                    JS_PopGCRef(ctx, &arr_ref);
                    return elem_term;
                }
            }
        }

        list = enif_make_list_cell(env, elem_term, list);
    }

    JS_PopGCRef(ctx, &arr_ref);
    return list;
}

/* Convert JS object to Elixir map */
static ERL_NIF_TERM js_object_to_erl(ErlNifEnv *env, JSContext *ctx, JSValue obj, int depth)
{
    JSGCRef obj_ref, keys_ref;
    JSValue *obj_val, *keys_val;

    if (depth > MAX_SERIALIZE_DEPTH) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "max_depth_exceeded"));
    }

    /* Protect the object value from GC */
    obj_val = JS_PushGCRef(ctx, &obj_ref);
    *obj_val = obj;

    /* Get object keys using Object.keys() */
    keys_val = JS_PushGCRef(ctx, &keys_ref);
    *keys_val = js_object_keys(ctx, NULL, 1, obj_val);

    if (JS_IsException(*keys_val)) {
        JS_PopGCRef(ctx, &keys_ref);
        JS_PopGCRef(ctx, &obj_ref);
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "object_keys_failed"));
    }

    /* Get keys array length */
    JSGCRef len_ref;
    JSValue *len_val = JS_PushGCRef(ctx, &len_ref);
    *len_val = js_array_get_length(ctx, keys_val, 0, NULL);

    if (JS_IsException(*len_val)) {
        JS_PopGCRef(ctx, &len_ref);
        JS_PopGCRef(ctx, &keys_ref);
        JS_PopGCRef(ctx, &obj_ref);
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "keys_length_failed"));
    }

    int len;
    if (JS_ToInt32(ctx, &len, *len_val) < 0 || len < 0) {
        JS_PopGCRef(ctx, &len_ref);
        JS_PopGCRef(ctx, &keys_ref);
        JS_PopGCRef(ctx, &obj_ref);
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "invalid_keys_length"));
    }

    JS_PopGCRef(ctx, &len_ref);

    /* Build map from keys */
    ERL_NIF_TERM map = enif_make_new_map(env);

    for (int i = 0; i < len; i++) {
        JSGCRef key_ref, val_ref;
        JSValue *key_val = JS_PushGCRef(ctx, &key_ref);
        JSValue *prop_val = JS_PushGCRef(ctx, &val_ref);

        *key_val = JS_GetPropertyUint32(ctx, *keys_val, (uint32_t)i);

        if (JS_IsException(*key_val)) {
            JS_PopGCRef(ctx, &val_ref);
            JS_PopGCRef(ctx, &key_ref);
            JS_PopGCRef(ctx, &keys_ref);
            JS_PopGCRef(ctx, &obj_ref);
            return enif_make_tuple2(env,
                enif_make_atom(env, "error"),
                enif_make_atom(env, "key_get_failed"));
        }

        /* Get string value of key */
        JSCStringBuf key_buf;
        size_t key_len;
        const char *key_str = JS_ToCStringLen(ctx, &key_len, *key_val, &key_buf);

        /* Get property value */
        *prop_val = JS_GetPropertyStr(ctx, *obj_val, key_str);

        if (JS_IsException(*prop_val)) {
            JS_PopGCRef(ctx, &val_ref);
            JS_PopGCRef(ctx, &key_ref);
            JS_PopGCRef(ctx, &keys_ref);
            JS_PopGCRef(ctx, &obj_ref);
            return enif_make_tuple2(env,
                enif_make_atom(env, "error"),
                enif_make_atom(env, "property_get_failed"));
        }

        /* Convert key to Elixir binary */
        ERL_NIF_TERM key_term;
        unsigned char *key_data = enif_make_new_binary(env, key_len, &key_term);
        memcpy(key_data, key_str, key_len);

        /* Recursively convert value */
        ERL_NIF_TERM val_term = js_to_erl(env, ctx, *prop_val, depth + 1);

        JS_PopGCRef(ctx, &val_ref);
        JS_PopGCRef(ctx, &key_ref);

        /* Check if nested conversion failed */
        if (enif_is_tuple(env, val_term)) {
            int arity;
            const ERL_NIF_TERM *tuple;
            if (enif_get_tuple(env, val_term, &arity, &tuple) && arity == 2) {
                if (enif_is_identical(tuple[0], enif_make_atom(env, "error"))) {
                    JS_PopGCRef(ctx, &keys_ref);
                    JS_PopGCRef(ctx, &obj_ref);
                    return val_term;
                }
            }
        }

        enif_make_map_put(env, map, key_term, val_term, &map);
    }

    JS_PopGCRef(ctx, &keys_ref);
    JS_PopGCRef(ctx, &obj_ref);
    return map;
}

/* Main JS → Elixir conversion function */
static ERL_NIF_TERM js_to_erl(ErlNifEnv *env, JSContext *ctx, JSValue val, int depth)
{
    /* Check null and undefined first */
    if (JS_IsNull(val) || JS_IsUndefined(val)) {
        return enif_make_atom(env, "nil");
    }

    /* Check booleans */
    if (JS_IsBool(val)) {
        return JS_VALUE_GET_SPECIAL_VALUE(val) ?
            enif_make_atom(env, "true") :
            enif_make_atom(env, "false");
    }

    /* Check integers (31-bit signed in MQuickJS) */
    if (JS_IsInt(val)) {
        int32_t i = JS_VALUE_GET_INT(val);
        return enif_make_int(env, i);
    }

#ifdef JS_USE_SHORT_FLOAT
    /* Check short floats (64-bit platforms) */
    if (JS_IsShortFloat(val)) {
        /* Short floats are encoded in the value itself */
        /* Need to decode - this is platform specific */
        /* For now, convert via JS_ToNumber */
        double d;
        if (JS_ToNumber(ctx, &d, val) == 0) {
            /* Check if it's actually an integer */
            if (d == (int64_t)d && d >= INT32_MIN && d <= INT32_MAX) {
                return enif_make_int(env, (int)d);
            }
            return enif_make_double(env, d);
        }
        return enif_make_atom(env, "nil");
    }
#endif

    /* Check if it's a pointer type (object, string, float64, etc.) */
    if (JS_IsPtr(val)) {
        /* Check for float64 */
        if (JS_IsNumber(ctx, val) && !JS_IsInt(val)) {
            double d;
            if (JS_ToNumber(ctx, &d, val) == 0) {
                /* Check if it's actually an integer */
                if (d == (int64_t)d && d >= INT32_MIN && d <= INT32_MAX) {
                    return enif_make_int(env, (int)d);
                }
                return enif_make_double(env, d);
            }
        }

        /* Check strings */
        if (JS_IsString(ctx, val)) {
            JSCStringBuf buf;
            size_t len;
            const char *str = JS_ToCStringLen(ctx, &len, val, &buf);
            ERL_NIF_TERM binary;
            unsigned char *data = enif_make_new_binary(env, len, &binary);
            memcpy(data, str, len);
            return binary;
        }

        /* Check for array (must be before generic object check) */
        int class_id = JS_GetClassID(ctx, val);
        if (class_id == JS_CLASS_ARRAY) {
            return js_array_to_erl(env, ctx, val, depth);
        }

        /* Check for functions - not serializable */
        if (JS_IsFunction(ctx, val)) {
            return enif_make_tuple2(env,
                enif_make_atom(env, "error"),
                enif_make_atom(env, "function_not_serializable"));
        }

        /* Check for generic objects */
        if (class_id == JS_CLASS_OBJECT) {
            return js_object_to_erl(env, ctx, val, depth);
        }

        /* Typed arrays, ArrayBuffer, etc. - TODO: could add support */
        if (class_id >= JS_CLASS_ARRAY_BUFFER && class_id <= JS_CLASS_FLOAT64_ARRAY) {
            return enif_make_tuple2(env,
                enif_make_atom(env, "error"),
                enif_make_atom(env, "typed_array_not_supported"));
        }
    }

    /* Unknown type */
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, "unknown_js_type"));
}

/* ============================================================================
 * Elixir → JS Type Conversion
 * ============================================================================ */

/* Forward declaration for recursion */
static JSValue erl_to_js(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM term, int depth);

/* Convert Elixir list to JS array */
static JSValue erl_list_to_js(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM list, int depth)
{
    if (depth > MAX_SERIALIZE_DEPTH) {
        return JS_ThrowInternalError(ctx, "max depth exceeded");
    }

    /* Get list length */
    unsigned int len;
    if (!enif_get_list_length(env, list, &len)) {
        return JS_ThrowTypeError(ctx, "expected list");
    }

    JSGCRef arr_ref;
    JSValue *arr = JS_PushGCRef(ctx, &arr_ref);
    *arr = JS_NewArray(ctx, (int)len);

    if (JS_IsException(*arr)) {
        JS_PopGCRef(ctx, &arr_ref);
        return JS_EXCEPTION;
    }

    ERL_NIF_TERM head, tail;
    int i = 0;
    tail = list;

    while (enif_get_list_cell(env, tail, &head, &tail)) {
        JSGCRef elem_ref;
        JSValue *elem = JS_PushGCRef(ctx, &elem_ref);
        *elem = erl_to_js(env, ctx, head, depth + 1);

        if (JS_IsException(*elem)) {
            JS_PopGCRef(ctx, &elem_ref);
            JS_PopGCRef(ctx, &arr_ref);
            return JS_EXCEPTION;
        }

        JSValue set_result = JS_SetPropertyUint32(ctx, *arr, (uint32_t)i, *elem);
        JS_PopGCRef(ctx, &elem_ref);

        if (JS_IsException(set_result)) {
            JS_PopGCRef(ctx, &arr_ref);
            return JS_EXCEPTION;
        }

        i++;
    }

    JSValue result = *arr;
    JS_PopGCRef(ctx, &arr_ref);
    return result;
}

/* Convert Elixir map to JS object */
static JSValue erl_map_to_js(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM map, int depth)
{
    if (depth > MAX_SERIALIZE_DEPTH) {
        return JS_ThrowInternalError(ctx, "max depth exceeded");
    }

    JSGCRef obj_ref;
    JSValue *obj = JS_PushGCRef(ctx, &obj_ref);
    *obj = JS_NewObject(ctx);

    if (JS_IsException(*obj)) {
        JS_PopGCRef(ctx, &obj_ref);
        return JS_EXCEPTION;
    }

    ErlNifMapIterator iter;
    if (!enif_map_iterator_create(env, map, &iter, ERL_NIF_MAP_ITERATOR_FIRST)) {
        JS_PopGCRef(ctx, &obj_ref);
        return JS_ThrowTypeError(ctx, "expected map");
    }

    ERL_NIF_TERM key, value;
    while (enif_map_iterator_get_pair(env, &iter, &key, &value)) {
        /* Convert key to string */
        char key_buf[1024];
        int key_len = 0;

        /* Try as binary first */
        ErlNifBinary key_bin;
        if (enif_inspect_binary(env, key, &key_bin)) {
            if (key_bin.size < sizeof(key_buf)) {
                memcpy(key_buf, key_bin.data, key_bin.size);
                key_len = (int)key_bin.size;
            } else {
                enif_map_iterator_destroy(env, &iter);
                JS_PopGCRef(ctx, &obj_ref);
                return JS_ThrowTypeError(ctx, "map key too long");
            }
        }
        /* Try as atom */
        else if (enif_get_atom(env, key, key_buf, sizeof(key_buf), ERL_NIF_LATIN1)) {
            key_len = (int)strlen(key_buf);
        }
        /* Try as integer (convert to string) */
        else {
            long i;
            if (enif_get_long(env, key, &i)) {
                key_len = snprintf(key_buf, sizeof(key_buf), "%ld", i);
            } else {
                enif_map_iterator_destroy(env, &iter);
                JS_PopGCRef(ctx, &obj_ref);
                return JS_ThrowTypeError(ctx, "unsupported map key type");
            }
        }

        key_buf[key_len] = '\0';

        /* Convert value recursively */
        JSGCRef val_ref;
        JSValue *val = JS_PushGCRef(ctx, &val_ref);
        *val = erl_to_js(env, ctx, value, depth + 1);

        if (JS_IsException(*val)) {
            JS_PopGCRef(ctx, &val_ref);
            enif_map_iterator_destroy(env, &iter);
            JS_PopGCRef(ctx, &obj_ref);
            return JS_EXCEPTION;
        }

        JSValue set_result = JS_SetPropertyStr(ctx, *obj, key_buf, *val);
        JS_PopGCRef(ctx, &val_ref);

        if (JS_IsException(set_result)) {
            enif_map_iterator_destroy(env, &iter);
            JS_PopGCRef(ctx, &obj_ref);
            return JS_EXCEPTION;
        }

        enif_map_iterator_next(env, &iter);
    }

    enif_map_iterator_destroy(env, &iter);

    JSValue result = *obj;
    JS_PopGCRef(ctx, &obj_ref);
    return result;
}

/* Main Elixir → JS conversion function */
static JSValue erl_to_js(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM term, int depth)
{
    /* Check for nil/null */
    if (enif_is_identical(term, enif_make_atom(env, "nil"))) {
        return JS_NULL;
    }

    /* Check for booleans */
    if (enif_is_identical(term, enif_make_atom(env, "true"))) {
        return JS_TRUE;
    }
    if (enif_is_identical(term, enif_make_atom(env, "false"))) {
        return JS_FALSE;
    }

    /* Check for integers */
    ErlNifSInt64 i64;
    if (enif_get_int64(env, term, &i64)) {
        /* MQuickJS uses 31-bit signed integers */
        if (i64 >= INT32_MIN && i64 <= INT32_MAX) {
            return JS_NewInt32(ctx, (int32_t)i64);
        }
        /* Large integers become floats (loses precision beyond 2^53) */
        return JS_NewFloat64(ctx, (double)i64);
    }

    /* Check for floats */
    double d;
    if (enif_get_double(env, term, &d)) {
        return JS_NewFloat64(ctx, d);
    }

    /* Check for binaries (strings) */
    ErlNifBinary bin;
    if (enif_inspect_binary(env, term, &bin)) {
        return JS_NewStringLen(ctx, (char *)bin.data, bin.size);
    }

    /* Check for atoms (convert to string, except nil/true/false handled above) */
    char atom_buf[256];
    if (enif_get_atom(env, term, atom_buf, sizeof(atom_buf), ERL_NIF_LATIN1)) {
        return JS_NewString(ctx, atom_buf);
    }

    /* Check for lists → JS Array */
    if (enif_is_list(env, term)) {
        return erl_list_to_js(env, ctx, term, depth);
    }

    /* Check for maps → JS Object */
    if (enif_is_map(env, term)) {
        return erl_map_to_js(env, ctx, term, depth);
    }

    /* Unsupported type */
    return JS_ThrowTypeError(ctx, "unsupported Elixir type");
}

/* ============================================================================
 * NIF Functions
 * ============================================================================ */

/* Create a new JS context */
static ERL_NIF_TERM nif_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    unsigned long mem_size = 65536;  /* Default 64KB */

    /* Parse memory option if provided */
    if (argc > 0) {
        if (!enif_get_ulong(env, argv[0], &mem_size)) {
            return enif_make_badarg(env);
        }
    }

    /* Allocate context resource */
    JsContext *js = enif_alloc_resource(JS_CONTEXT_TYPE, sizeof(JsContext));
    if (!js) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "alloc_failed"));
    }

    js->mem_size = mem_size;

    /* Use simple malloc - same as working standalone test */
    js->mem_buf = malloc(mem_size);
    if (!js->mem_buf) {
        enif_release_resource(js);
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "alloc_failed"));
    }

    /* Initialize MQuickJS */
    js->ctx = JS_NewContext(js->mem_buf, js->mem_size, &js_stdlib);
    if (!js->ctx) {
        free(js->mem_buf);
        enif_release_resource(js);
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "js_context_failed"));
    }

    /* Set up logging */
    JS_SetLogFunc(js->ctx, js_log_func);

    ERL_NIF_TERM result = enif_make_resource(env, js);
    enif_release_resource(js);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), result);
}

/* Evaluate JavaScript code and return the result */
static ERL_NIF_TERM nif_eval(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    JsContext *js;
    if (!enif_get_resource(env, argv[0], JS_CONTEXT_TYPE, (void **)&js)) {
        return enif_make_badarg(env);
    }

    ErlNifBinary code_bin;
    if (!enif_inspect_binary(env, argv[1], &code_bin)) {
        return enif_make_badarg(env);
    }

    /*
     * IMPORTANT: Copy the code to a local buffer before passing to JS_Eval.
     *
     * Passing the Erlang binary data pointer directly to JS_Eval causes
     * intermittent parsing failures ("unexpected character" or undefined
     * variable errors). The exact cause is unclear but may be related to
     * how the BEAM manages binary memory. Copying to a malloc'd buffer
     * eliminates this issue.
     *
     * See docs/known-issues.md for the investigation history.
     */
    char *code_copy = malloc(code_bin.size + 1);
    if (!code_copy) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "alloc_failed"));
    }
    memcpy(code_copy, code_bin.data, code_bin.size);
    code_copy[code_bin.size] = '\0';

    /* Use JS_EVAL_RETVAL to get the expression result */
    JSValue result = JS_Eval(js->ctx, code_copy, code_bin.size, "eval", JS_EVAL_RETVAL);
    free(code_copy);

    if (JS_IsException(result)) {
        JSValue err = JS_GetException(js->ctx);

        /* Try to get error message */
        JSValue msg = JS_GetPropertyStr(js->ctx, err, "message");
        if (JS_IsString(js->ctx, msg)) {
            JSCStringBuf buf;
            const char *str = JS_ToCString(js->ctx, msg, &buf);
            size_t len = strlen(str);
            ERL_NIF_TERM binary;
            unsigned char *data = enif_make_new_binary(env, len, &binary);
            memcpy(data, str, len);
            return enif_make_tuple2(env,
                enif_make_atom(env, "error"),
                binary);
        }

        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "js_exception"));
    }

    /* Convert JS result to Elixir term */
    ERL_NIF_TERM erl_result = js_to_erl(env, js->ctx, result, 0);

    /* Check if conversion failed */
    if (enif_is_tuple(env, erl_result)) {
        int arity;
        const ERL_NIF_TERM *tuple;
        if (enif_get_tuple(env, erl_result, &arity, &tuple) && arity == 2) {
            if (enif_is_identical(tuple[0], enif_make_atom(env, "error"))) {
                return erl_result;
            }
        }
    }

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), erl_result);
}

/* Get a global variable */
static ERL_NIF_TERM nif_get(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    JsContext *js;
    if (!enif_get_resource(env, argv[0], JS_CONTEXT_TYPE, (void **)&js)) {
        return enif_make_badarg(env);
    }

    /* Get the variable name */
    char name_buf[256];
    ErlNifBinary name_bin;

    if (enif_inspect_binary(env, argv[1], &name_bin)) {
        if (name_bin.size >= sizeof(name_buf)) {
            return enif_make_badarg(env);
        }
        memcpy(name_buf, name_bin.data, name_bin.size);
        name_buf[name_bin.size] = '\0';
    } else if (enif_get_atom(env, argv[1], name_buf, sizeof(name_buf), ERL_NIF_LATIN1)) {
        /* Already null-terminated */
    } else {
        return enif_make_badarg(env);
    }

    /* Get global object and then the property */
    JSValue global = JS_GetGlobalObject(js->ctx);
    JSValue val = JS_GetPropertyStr(js->ctx, global, name_buf);

    if (JS_IsException(val)) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "get_failed"));
    }

    ERL_NIF_TERM result = js_to_erl(env, js->ctx, val, 0);

    /* Check if conversion failed */
    if (enif_is_tuple(env, result)) {
        int arity;
        const ERL_NIF_TERM *tuple;
        if (enif_get_tuple(env, result, &arity, &tuple) && arity == 2) {
            if (enif_is_identical(tuple[0], enif_make_atom(env, "error"))) {
                return result;
            }
        }
    }

    return enif_make_tuple2(env, enif_make_atom(env, "ok"), result);
}

/* Set a global variable */
static ERL_NIF_TERM nif_set(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    JsContext *js;
    if (!enif_get_resource(env, argv[0], JS_CONTEXT_TYPE, (void **)&js)) {
        return enif_make_badarg(env);
    }

    /* Get the variable name */
    char name_buf[256];
    ErlNifBinary name_bin;

    if (enif_inspect_binary(env, argv[1], &name_bin)) {
        if (name_bin.size >= sizeof(name_buf)) {
            return enif_make_badarg(env);
        }
        memcpy(name_buf, name_bin.data, name_bin.size);
        name_buf[name_bin.size] = '\0';
    } else if (enif_get_atom(env, argv[1], name_buf, sizeof(name_buf), ERL_NIF_LATIN1)) {
        /* Already null-terminated */
    } else {
        return enif_make_badarg(env);
    }

    /* Convert Elixir value to JS */
    JSValue js_val = erl_to_js(env, js->ctx, argv[2], 0);

    if (JS_IsException(js_val)) {
        JSValue err = JS_GetException(js->ctx);
        JSValue msg = JS_GetPropertyStr(js->ctx, err, "message");
        if (JS_IsString(js->ctx, msg)) {
            JSCStringBuf buf;
            const char *str = JS_ToCString(js->ctx, msg, &buf);
            size_t len = strlen(str);
            ERL_NIF_TERM binary;
            unsigned char *data = enif_make_new_binary(env, len, &binary);
            memcpy(data, str, len);
            return enif_make_tuple2(env,
                enif_make_atom(env, "error"),
                binary);
        }
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "conversion_failed"));
    }

    /* Set on global object */
    JSValue global = JS_GetGlobalObject(js->ctx);
    JSValue set_result = JS_SetPropertyStr(js->ctx, global, name_buf, js_val);

    if (JS_IsException(set_result)) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "set_failed"));
    }

    return enif_make_atom(env, "ok");
}

/* Trigger garbage collection */
static ERL_NIF_TERM nif_gc(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[])
{
    JsContext *js;
    if (!enif_get_resource(env, argv[0], JS_CONTEXT_TYPE, (void **)&js)) {
        return enif_make_badarg(env);
    }

    JS_GC(js->ctx);

    return enif_make_atom(env, "ok");
}

/* Resource destructor */
static void js_context_destructor(ErlNifEnv *env, void *obj)
{
    JsContext *js = (JsContext *)obj;
    if (js->ctx) {
        JS_FreeContext(js->ctx);
        js->ctx = NULL;
    }
    if (js->mem_buf) {
        free(js->mem_buf);
        js->mem_buf = NULL;
    }
}

/* NIF initialization */
static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info)
{
    JS_CONTEXT_TYPE = enif_open_resource_type(env, NULL, "JsContext",
        js_context_destructor, ERL_NIF_RT_CREATE, NULL);
    if (!JS_CONTEXT_TYPE) {
        return 1;
    }
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"nif_new", 1, nif_new, 0},
    {"nif_eval", 2, nif_eval, 0},
    {"nif_get", 2, nif_get, 0},
    {"nif_set", 3, nif_set, 0},
    {"nif_gc", 1, nif_gc, 0},
};

ERL_NIF_INIT(Elixir.MquickjsEx.NIF, nif_funcs, load, NULL, NULL, NULL)
