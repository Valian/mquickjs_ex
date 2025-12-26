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

typedef struct {
    uint8_t *mem_buf;
    size_t mem_size;
    JSContext *ctx;
} JsContext;

static void js_log_func(void *opaque, const void *buf, size_t buf_len)
{
    fwrite(buf, 1, buf_len, stdout);
}

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

/* Evaluate JavaScript code */
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

    JSValue result = JS_Eval(js->ctx, code_copy, code_bin.size, "eval", 0);
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

    /* For Phase 1, just return :ok if it didn't throw */
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_atom(env, "executed"));
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
};

ERL_NIF_INIT(Elixir.MquickjsEx.NIF, nif_funcs, load, NULL, NULL, NULL)
