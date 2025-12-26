# MquickjsEx Implementation Plan

## Overview

Embed MQuickJS (a minimal JavaScript engine) into Elixir via NIFs, enabling LLM-generated JavaScript to call Elixir functions through a trampoline pattern.

## Phase 1: Minimal Viable Proof (Days 1-2)

**Goal:** Validate that MQuickJS can be compiled and called from Elixir NIFs.

### 1.1 Project Setup

```
mquickjs_ex/
├── mix.exs
├── Makefile
├── c_src/
│   ├── mquickjs_ex.c          # NIF implementation
│   ├── mquickjs_ex_stdlib.c   # Our stdlib definition
│   └── vendor/                # MQuickJS source files
│       ├── mquickjs.c
│       ├── mquickjs.h
│       ├── mquickjs_build.c
│       ├── mquickjs_build.h
│       ├── dtoa.c / .h
│       ├── libm.c / .h
│       └── cutils.c / .h
├── lib/
│   └── mquickjs_ex.ex
└── test/
```

### 1.2 Build System

The MQuickJS build is two-stage:

```makefile
# Stage 1: Build stdlib generator (host tool)
c_src/stdlib_gen: c_src/mquickjs_ex_stdlib.c c_src/vendor/mquickjs_build.c
	$(CC) -o $@ $^ -I c_src/vendor

# Stage 2: Generate headers
c_src/mquickjs_ex_stdlib.h c_src/mquickjs_atom.h: c_src/stdlib_gen
	cd c_src && ./stdlib_gen

# Stage 3: Build NIF
priv/mquickjs_ex.so: c_src/mquickjs_ex.c c_src/vendor/*.c c_src/mquickjs_ex_stdlib.h
	$(CC) -shared -fPIC -o $@ c_src/mquickjs_ex.c c_src/vendor/mquickjs.c \
	      c_src/vendor/dtoa.c c_src/vendor/libm.c c_src/vendor/cutils.c \
	      -I c_src/vendor $(ERLANG_INCLUDES)
```

### 1.3 Minimal NIF (Proof of Concept)

```c
// c_src/mquickjs_ex.c
#include "erl_nif.h"
#include "mquickjs.h"
#include "mquickjs_ex_stdlib.h"

// NIF resource type for JS context
static ErlNifResourceType *JS_CONTEXT_TYPE;

typedef struct {
    uint8_t *mem_buf;
    size_t mem_size;
    JSContext *ctx;
} JsContext;

// Create new context
static ERL_NIF_TERM nif_new(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    size_t mem_size = 65536;  // Default 64KB

    // Parse memory option if provided
    if (argc > 0) {
        enif_get_ulong(env, argv[0], &mem_size);
    }

    // Allocate context resource
    JsContext *js = enif_alloc_resource(JS_CONTEXT_TYPE, sizeof(JsContext));
    js->mem_size = mem_size;
    js->mem_buf = enif_alloc(mem_size);

    // Initialize MQuickJS
    js->ctx = JS_NewContext(js->mem_buf, js->mem_size, &js_stdlib);

    if (!js->ctx) {
        enif_release_resource(js);
        return enif_make_atom(env, "error");
    }

    ERL_NIF_TERM result = enif_make_resource(env, js);
    enif_release_resource(js);
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), result);
}

// Simple eval - just return if it works
static ERL_NIF_TERM nif_eval(ErlNifEnv *env, int argc, const ERL_NIF_TERM argv[]) {
    JsContext *js;
    if (!enif_get_resource(env, argv[0], JS_CONTEXT_TYPE, (void **)&js)) {
        return enif_make_badarg(env);
    }

    ErlNifBinary code_bin;
    if (!enif_inspect_binary(env, argv[1], &code_bin)) {
        return enif_make_badarg(env);
    }

    JSValue result = JS_Eval(js->ctx, (char *)code_bin.data, code_bin.size, "eval", 0);

    if (JS_IsException(result)) {
        return enif_make_tuple2(env,
            enif_make_atom(env, "error"),
            enif_make_atom(env, "js_exception"));
    }

    // For now, just return :ok if it didn't throw
    return enif_make_tuple2(env, enif_make_atom(env, "ok"), enif_make_atom(env, "executed"));
}

// Resource destructor
static void js_context_destructor(ErlNifEnv *env, void *obj) {
    JsContext *js = (JsContext *)obj;
    if (js->ctx) {
        JS_FreeContext(js->ctx);
    }
    if (js->mem_buf) {
        enif_free(js->mem_buf);
    }
}

// NIF initialization
static int load(ErlNifEnv *env, void **priv_data, ERL_NIF_TERM load_info) {
    JS_CONTEXT_TYPE = enif_open_resource_type(env, NULL, "JsContext",
        js_context_destructor, ERL_NIF_RT_CREATE, NULL);
    return 0;
}

static ErlNifFunc nif_funcs[] = {
    {"nif_new", 1, nif_new, ERL_NIF_DIRTY_JOB_CPU_BOUND},
    {"nif_eval", 2, nif_eval, ERL_NIF_DIRTY_JOB_CPU_BOUND},
};

ERL_NIF_INIT(Elixir.MquickjsEx.NIF, nif_funcs, load, NULL, NULL, NULL)
```

### 1.4 Minimal Elixir Wrapper

```elixir
# lib/mquickjs_ex/nif.ex
defmodule MquickjsEx.NIF do
  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:mquickjs_ex), 'mquickjs_ex')
    :erlang.load_nif(path, 0)
  end

  def nif_new(_mem_size), do: :erlang.nif_error(:not_loaded)
  def nif_eval(_ctx, _code), do: :erlang.nif_error(:not_loaded)
end

# lib/mquickjs_ex.ex
defmodule MquickjsEx do
  alias MquickjsEx.NIF

  def new(opts \\ []) do
    mem_size = Keyword.get(opts, :memory, 65536)
    NIF.nif_new(mem_size)
  end

  def eval!({:ok, ctx}, code) when is_binary(code) do
    case NIF.nif_eval(ctx, code) do
      {:ok, _} -> {:ok, ctx}
      {:error, reason} -> raise "JS Error: #{inspect(reason)}"
    end
  end
end
```

### 1.5 Validation Test

```elixir
# test/mquickjs_ex_test.exs
defmodule MquickjsExTest do
  use ExUnit.Case

  test "can create context and eval simple code" do
    {:ok, ctx} = MquickjsEx.new()
    assert {:ok, _ctx} = MquickjsEx.eval!({:ok, ctx}, "var x = 1 + 2;")
  end
end
```

**Phase 1 Success Criteria:**
- [x] MQuickJS compiles as part of mix build
- [x] Can create a JS context from Elixir
- [x] Can evaluate simple JS code without crashing
- [x] Context cleanup works (no memory leaks)

**Phase 1 Complete** - See `c_src/mquickjs_ex.c` for implementation.

---

## Phase 2: Type Serialization (Days 3-4)

**Goal:** Convert values between Elixir and JavaScript.

### 2.1 JS → Elixir Serialization

```c
// In mquickjs_ex.c
static ERL_NIF_TERM js_to_erl(ErlNifEnv *env, JSContext *ctx, JSValue val) {
    if (JS_IsNull(val) || JS_IsUndefined(val)) {
        return enif_make_atom(env, "nil");
    }

    if (JS_IsBool(val)) {
        return JS_IsTrue(val) ? enif_make_atom(env, "true")
                              : enif_make_atom(env, "false");
    }

    if (JS_IsNumber(val)) {
        double d;
        JS_ToNumber(ctx, &d, val);
        // Check if it's an integer
        if (d == (int64_t)d && d >= INT64_MIN && d <= INT64_MAX) {
            return enif_make_int64(env, (int64_t)d);
        }
        return enif_make_double(env, d);
    }

    if (JS_IsString(val)) {
        JSCStringBuf buf;
        const char *str = JS_ToCString(ctx, val, &buf);
        size_t len = strlen(str);
        ERL_NIF_TERM binary;
        unsigned char *data = enif_make_new_binary(env, len, &binary);
        memcpy(data, str, len);
        return binary;
    }

    if (JS_IsArray(ctx, val)) {
        // Get length, iterate, build list
        // ... (recursive serialization)
    }

    if (JS_IsObject(val)) {
        // Get own property names, iterate, build map
        // ... (recursive serialization)
    }

    // Functions and other types → error
    return enif_make_tuple2(env,
        enif_make_atom(env, "error"),
        enif_make_atom(env, "unserializable_type"));
}
```

### 2.2 Elixir → JS Serialization

```c
static JSValue erl_to_js(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM term) {
    // Check for nil/null
    if (enif_is_identical(term, enif_make_atom(env, "nil"))) {
        return JS_NULL;
    }

    // Check for booleans
    if (enif_is_identical(term, enif_make_atom(env, "true"))) {
        return JS_NewBool(1);
    }
    if (enif_is_identical(term, enif_make_atom(env, "false"))) {
        return JS_NewBool(0);
    }

    // Check for integers
    int64_t i;
    if (enif_get_int64(env, term, &i)) {
        return JS_NewInt32(ctx, (int32_t)i);  // Note: MQuickJS uses 31-bit signed
    }

    // Check for floats
    double d;
    if (enif_get_double(env, term, &d)) {
        return JS_NewFloat64(ctx, d);
    }

    // Check for binaries (strings)
    ErlNifBinary bin;
    if (enif_inspect_binary(env, term, &bin)) {
        return JS_NewStringLen(ctx, (char *)bin.data, bin.size);
    }

    // Check for atoms (convert to string)
    char atom_buf[256];
    if (enif_get_atom(env, term, atom_buf, sizeof(atom_buf), ERL_NIF_LATIN1)) {
        return JS_NewString(ctx, atom_buf);
    }

    // Check for lists → JS Array
    // Check for maps → JS Object
    // ... (recursive serialization with GCRef protection)

    return JS_UNDEFINED;
}
```

### 2.3 GC-Safe Recursive Serialization

Converting nested structures requires protecting intermediate values:

```c
static JSValue erl_map_to_js(ErlNifEnv *env, JSContext *ctx, ERL_NIF_TERM map) {
    JSGCRef obj_ref, key_ref, val_ref;
    JSValue *obj, *key_val, *value_val;

    obj = JS_PushGCRef(ctx, &obj_ref);
    key_val = JS_PushGCRef(ctx, &key_ref);
    value_val = JS_PushGCRef(ctx, &val_ref);

    *obj = JS_NewObject(ctx);
    if (JS_IsException(*obj)) goto fail;

    ErlNifMapIterator iter;
    enif_map_iterator_create(env, map, &iter, ERL_NIF_MAP_ITERATOR_FIRST);

    ERL_NIF_TERM key, value;
    while (enif_map_iterator_get_pair(env, &iter, &key, &value)) {
        // Convert key to string
        *key_val = erl_to_js(env, ctx, key);
        *value_val = erl_to_js(env, ctx, value);

        JSCStringBuf buf;
        const char *key_str = JS_ToCString(ctx, *key_val, &buf);
        JS_SetPropertyStr(ctx, *obj, key_str, *value_val);

        enif_map_iterator_next(env, &iter);
    }

    enif_map_iterator_destroy(env, &iter);

    JSValue result = *obj;
    JS_PopGCRef(ctx, &val_ref);
    JS_PopGCRef(ctx, &key_ref);
    JS_PopGCRef(ctx, &obj_ref);
    return result;

fail:
    JS_PopGCRef(ctx, &val_ref);
    JS_PopGCRef(ctx, &key_ref);
    JS_PopGCRef(ctx, &obj_ref);
    return JS_EXCEPTION;
}
```

**Phase 2 Success Criteria:**
- [x] `eval!` returns Elixir terms (integers, floats, strings, booleans, nil)
- [x] `eval!` returns nested structures (lists, maps)
- [x] `set!` accepts Elixir terms and sets JS globals
- [x] `get!` retrieves JS globals as Elixir terms

**Phase 2 Complete** - See `c_src/mquickjs_ex.c` for implementation. Key implementation notes:
- Uses `JS_EVAL_RETVAL` flag to get expression results
- Object enumeration via `js_object_keys()` from `mquickjs_priv.h`
- GC protection via `JS_PushGCRef`/`JS_PopGCRef` for nested conversions
- Recursion depth limit (100) to prevent stack overflow
- Functions return `{:error, :function_not_serializable}`

---

## Phase 3: Trampoline Pattern (Days 5-7)

**Goal:** Enable JS to call Elixir functions via yield/resume.

### 3.1 The `__call` Built-in Function

Register a C function that triggers the trampoline:

```c
// Global flag to track yield state
typedef struct {
    int yielded;
    char *func_name;
    ERL_NIF_TERM args;  // Serialized arguments
} YieldState;

static YieldState yield_state = {0};

// The __call function JS will invoke
static JSValue js_call_elixir(JSContext *ctx, JSValue *this_val,
                               int argc, JSValue *argv) {
    if (argc < 2) {
        return JS_ThrowTypeError(ctx, "__call requires (name, args)");
    }

    // Get function name
    JSCStringBuf name_buf;
    const char *name = JS_ToCString(ctx, argv[0], &name_buf);

    // Serialize args array to Elixir terms
    // Store in yield_state for retrieval by NIF
    yield_state.yielded = 1;
    yield_state.func_name = strdup(name);
    // ... serialize argv[1] (the args array)

    // Throw a special "yield" exception to unwind the stack
    return JS_ThrowInternalError(ctx, "__yield__");
}
```

### 3.2 Modified Eval with Yield Detection

```c
static ERL_NIF_TERM nif_eval_or_resume(ErlNifEnv *env, int argc,
                                        const ERL_NIF_TERM argv[]) {
    JsContext *js;
    enif_get_resource(env, argv[0], JS_CONTEXT_TYPE, (void **)&js);

    // Check if this is a resume (argv[1] is {:resume, result})
    // or a fresh eval (argv[1] is code binary)

    JSValue result;
    if (is_resume) {
        // Set the resume value and continue
        // ... (implementation depends on MQuickJS continuation support)
    } else {
        // Fresh eval
        ErlNifBinary code_bin;
        enif_inspect_binary(env, argv[1], &code_bin);
        result = JS_Eval(js->ctx, (char *)code_bin.data, code_bin.size, "eval", 0);
    }

    // Check for yield
    if (JS_IsException(result)) {
        JSValue err = JS_GetException(js->ctx);
        // Check if it's our special yield marker
        if (is_yield_exception(js->ctx, err)) {
            // Return {:yield, func_name, args, continuation}
            return enif_make_tuple4(env,
                enif_make_atom(env, "yield"),
                /* func_name */,
                /* args */,
                /* continuation token */);
        }
        // Real exception
        return enif_make_tuple2(env, enif_make_atom(env, "error"), /* ... */);
    }

    // Normal completion
    return enif_make_tuple3(env,
        enif_make_atom(env, "ok"),
        js_to_erl(env, js->ctx, result),
        enif_make_resource(env, js));
}
```

### 3.3 Continuation Strategy: The Replay Approach

MQuickJS doesn't have native coroutine support - no generators, no `yield`, no way to pause and resume execution mid-function. Once you exit `JS_Eval`, the call stack is gone.

**Our solution: Replay with cached results.**

```javascript
// Generated wrapper for user code
var __call_results = [];
var __call_index = 0;

function __call(name, args) {
    if (__call_index < __call_results.length) {
        return __call_results[__call_index++];  // Return cached result
    }
    // No cached result - yield to Elixir
    __yield_and_call(name, args);  // Throws to exit JS
}

// User code runs here
// On resume, __call_results has one more entry, code re-runs from start
// Previous __call invocations return cached results instantly
```

#### How Replay Works

For code with 3 callbacks:

```javascript
var a = fetch("url1");  // Call #1
var b = fetch("url2");  // Call #2
var c = fetch("url3");  // Call #3
return a + b + c;
```

| Run | Code before call #1 | fetch("url1") | Code before call #2 | fetch("url2") | Code before call #3 | fetch("url3") | Result |
|-----|---------------------|---------------|---------------------|---------------|---------------------|---------------|--------|
| 1   | executes | → yields | - | - | - | - | Elixir runs callback |
| 2   | **re-executes** | returns cached | executes | → yields | - | - | Elixir runs callback |
| 3   | **re-executes** | returns cached | **re-executes** | returns cached | executes | → yields | Elixir runs callback |
| 4   | **re-executes** | returns cached | **re-executes** | returns cached | **re-executes** | returns cached | ✓ completes |

**The tradeoff:** Code before each callback runs multiple times. With N callbacks, the code before the first callback runs N times.

#### Why This Is Acceptable for LLM Sandboxes

**1. Callbacks are the slow part, not JS execution**

Typical LLM-generated code:
```javascript
var data = http_get("https://api.example.com");  // 50-200ms
var parsed = JSON.parse(data);                    // 0.01ms
var result = transform(parsed);                   // 0.1ms
save_result(result);                              // 10-50ms
```

The HTTP calls dominate. Re-running `JSON.parse` 4 times adds microseconds to a 200ms operation.

**2. LLM code is typically linear with few callbacks**

Most generated scripts:
- Fetch some data (1-3 API calls)
- Transform it (pure JS, no callbacks)
- Return or save result (0-1 callback)

A script with 5 callbacks is unusual. 10+ is rare.

**3. Side effects before callbacks are uncommon**

The main risk with replay is side effects:
```javascript
console.log("Starting...");  // Prints 3 times if 3 callbacks follow
var a = fetch("url1");
var b = fetch("url2");
var c = fetch("url3");
```

But LLM-generated sandbox code rarely has side effects before its first callback. The pattern is usually:
- Set up variables (no side effects)
- Call external APIs
- Process and return

**4. Mitigation via documentation**

We document: "Code before callbacks may execute multiple times. Avoid side effects before your first callback, or accept they may repeat."

For the rare cases where this matters, users can restructure:
```javascript
// Instead of:
console.log("Starting");
var a = fetch("url1");

// Do:
var a = fetch("url1");
console.log("Starting");  // Now only runs once
```

#### Overhead Estimate

| Component | Time per replay |
|-----------|-----------------|
| Parse JS code | ~10-50μs (cached bytecode: ~0) |
| Execute preamble (variable setup) | ~1-10μs |
| Check cached results | ~0.1μs per cached call |
| **Total per extra run** | **~10-60μs** |

For 5 callbacks: ~5 extra runs × 30μs = 150μs overhead.
Compared to 5 × 100ms HTTP calls = 500ms total.
Overhead: **0.03%** - negligible.

#### When Replay Becomes a Problem

**High callback count (>20):**
- Quadratic growth: N callbacks = N×(N-1)/2 extra preamble executions
- 20 callbacks ≈ 190 extra runs ≈ 5-10ms overhead
- Still acceptable, but worth monitoring

**Expensive preamble:**
```javascript
var bigArray = [];
for (var i = 0; i < 100000; i++) bigArray.push(i);  // 10ms
var a = fetch("url1");  // This preamble re-runs
```
- Solution: Move expensive computation after callbacks, or accept the cost

**Non-deterministic preamble:**
```javascript
var startTime = Date.now();
var data = fetch("url");
console.log("Took " + (Date.now() - startTime) + "ms");  // Wrong!
```
- `startTime` differs on each replay
- Solution: Document this limitation; use callbacks for timing

#### Alternative Approaches (Future)

If replay becomes problematic, we have options:

**CPS Transformation:** Convert code to continuation-passing style at the Elixir level (like Babel does for async/await). Complex but eliminates replay.

**MQuickJS Patching:** Add coroutine support to the engine. Invasive but clean semantically.

**Promise-based API:** Don't pretend it's synchronous. User writes callback chains explicitly. More honest but uglier for LLMs.

For v1, replay is the pragmatic choice. It works, it's simple, and for 95% of LLM sandbox use cases, the overhead is invisible.

### 3.4 Elixir Run Loop

```elixir
defmodule MquickjsEx do
  def run(js, code, callbacks \\ %{}) do
    wrapped_code = wrap_with_trampoline(code, Map.keys(callbacks))
    run_loop(js, {:eval, wrapped_code}, callbacks, [])
  end

  defp run_loop(js, action, callbacks, results_acc) do
    case NIF.eval_or_resume(js, action, results_acc) do
      {:ok, result, js} ->
        {:ok, result, js}

      {:yield, func_name, args, js} ->
        case Map.fetch(callbacks, func_name) do
          {:ok, callback} ->
            result = callback.(args)
            run_loop(js, {:resume, result}, callbacks, results_acc ++ [result])

          :error ->
            {:error, %Error{message: "Unknown callback: #{func_name}"}}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp wrap_with_trampoline(code, callback_names) do
    wrappers = Enum.map_join(callback_names, "\n", fn name ->
      "function #{name}() { return __call('#{name}', Array.prototype.slice.call(arguments)); }"
    end)

    """
    var __call_results = __call_results || [];
    var __call_index = 0;
    function __call(name, args) {
      if (__call_index < __call_results.length) {
        return __call_results[__call_index++];
      }
      __yield(name, JSON.stringify(args));
    }
    #{wrappers}
    (function() {
      #{code}
    })();
    """
  end
end
```

**Phase 3 Success Criteria:**
- [x] JS code can call `__call("name", [args])` and yield to Elixir
- [x] Elixir callbacks receive correct arguments
- [x] Resume injects callback result back into JS
- [x] Multiple sequential callbacks work correctly
- [x] Nested callbacks work (callback triggers another callback)

**Phase 3 Complete** - See `c_src/mquickjs_ex.c` (nif_run function) and `lib/mquickjs_ex.ex` (run/3, run!/3).

Key implementation notes:
- Uses pure JavaScript for the yield mechanism (no stdlib modification needed)
- `__call` function checks cached results or throws special exception
- Exception message format: `__yield__:<func_name>:<args_json>`
- Elixir run loop parses yield, executes callback, replays with cached results
- JSON serialization via Jason for callback arguments and results
- 25 new tests covering basic, sequential, nested callbacks, and error handling

---

## Phase 4: Full API (Days 8-10)

### 4.1 Complete Public API

```elixir
defmodule MquickjsEx do
  defstruct [:ctx, :callbacks, :private]

  def new(opts \\ [])
  def eval!(js, code)
  def eval(js, code)
  def run(js, code, callbacks \\ %{})
  def set!(js, path, value)
  def get!(js, path)
  def get(js, path)
  def gc(js)
  def memory_stats(js)
  def set_timeout(js, ms)
end
```

### 4.2 Error Handling

```elixir
defmodule MquickjsEx.Error do
  defexception [:message, :name, :stack]
end

defmodule MquickjsEx.TimeoutError do
  defexception [:message]
end
```

### 4.3 Sigil (Compile-time Validation)

```elixir
defmodule MquickjsEx.Sigil do
  defmacro sigil_JS({:<<>>, _, [code]}, []) do
    # Validate syntax at compile time by attempting parse
    validate_js_syntax!(code)
    quote do: unquote(code)
  end

  defmacro sigil_JS({:<<>>, _, [code]}, 'c') do
    # Compile to bytecode at compile time
    bytecode = compile_to_bytecode!(code)
    quote do: {:bytecode, unquote(bytecode)}
  end
end
```

**Phase 4 Success Criteria:**
- [ ] All API functions from docs/API.md implemented
- [ ] Comprehensive error messages with JS stack traces
- [ ] Timeout interruption works
- [ ] `~JS` sigil validates syntax at compile time

---

## Phase 5: Production Hardening (Days 11-14)

### 5.1 Memory Safety
- Fuzz test with random JS inputs
- Test memory exhaustion scenarios
- Verify no leaks with `:recon` or similar

### 5.2 Performance
- Benchmark against other JS-in-Elixir solutions
- Profile NIF overhead
- Optimize hot paths in serialization

### 5.3 Documentation
- ExDoc with examples
- Guide for LLM sandbox use case
- Security considerations

### 5.4 Hex Release
- CI/CD pipeline
- Precompiled NIFs for common platforms
- Version compatibility matrix

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| MQuickJS compacting GC causes crashes | All JS ↔ Elixir boundaries serialize; never hold JSValue across allocations |
| Trampoline overhead too high | Benchmark early; batch APIs if needed |
| MQuickJS missing features | Document limitations; ES5 subset is known |
| Build complexity (two-stage) | Encapsulate in Makefile; test on CI early |
| Dirty scheduler starvation | Set reasonable timeouts; document best practices |

---

## Open Questions

1. **Bytecode caching:** Should compiled bytecode be cached in the context, or passed from Elixir?
2. **Multiple contexts:** Allow multiple isolated contexts? (Yes, seems useful for sandboxing)
3. **Interrupt mechanism:** MQuickJS interrupt callback - how to wire to Elixir timeout?
4. **Precompiled NIFs:** Worth the complexity for initial release?

---

## Success Metrics

After Phase 3, we should be able to run:

```elixir
js = MquickjsEx.new()

{:ok, result, _js} = MquickjsEx.run(js, """
  var response = fetch_data("https://api.example.com/data");
  var parsed = JSON.parse(response);
  parsed.items.length
""", %{
  "fetch_data" => fn [url] ->
    HTTPoison.get!(url).body
  end
})

assert result == 42
```

This demonstrates: context creation, code evaluation, Elixir callback invocation, result serialization - the core value proposition.
