# MicroQuickJS Embedding Guide

This guide explains how to embed MicroQuickJS (MQuickJS) into a C library. MQuickJS is a minimal JavaScript engine designed for embedded systems with constrained memory.

## Key Files

| File | Purpose |
|------|---------|
| `mquickjs.h` | **Public C API** - include this in your code |
| `mquickjs.c` | Core engine implementation (~560KB) |
| `mquickjs_build.h` | Macros for defining stdlib (classes, functions, properties) |
| `mquickjs_build.c` | Build tool that compiles stdlib definitions to ROM-resident C structures |
| `dtoa.c`, `dtoa.h` | Number-to-string conversion |
| `libm.c`, `libm.h` | Math library (includes soft-float for FPU-less systems) |
| `cutils.c`, `cutils.h` | Utility functions |
| `example.c` | **Complete embedding example** - start here |
| `example_stdlib.c` | Example stdlib definition with custom classes |

## Build Process Overview

MQuickJS requires a two-stage build:

1. **Build stdlib generator** (host tool): Compile your `*_stdlib.c` file with `mquickjs_build.c` to create a host executable
2. **Generate headers**: Run the stdlib generator to produce `*_stdlib.h` (stdlib data) and `mquickjs_atom.h` (atom table)
3. **Build final binary**: Compile your application with the generated headers

See `Makefile` lines 91-112 for the pattern.

## Minimal Embedding

```c
#include "mquickjs.h"

// Include your generated stdlib header
#include "my_stdlib.h"

void run_script(const char *code, size_t code_len) {
    // 1. Allocate fixed memory buffer
    size_t mem_size = 65536;  // 64KB - adjust as needed
    uint8_t *mem_buf = malloc(mem_size);

    // 2. Create context with your stdlib
    JSContext *ctx = JS_NewContext(mem_buf, mem_size, &js_stdlib);

    // 3. Optional: set up logging
    JS_SetLogFunc(ctx, my_log_func);

    // 4. Evaluate JavaScript
    JSValue result = JS_Eval(ctx, code, code_len, "script.js", 0);

    // 5. Check for errors
    if (JS_IsException(result)) {
        JSValue err = JS_GetException(ctx);
        JS_PrintValueF(ctx, err, JS_DUMP_LONG);
    }

    // 6. Cleanup (only needed to call finalizers)
    JS_FreeContext(ctx);
    free(mem_buf);
}
```

## Critical: Memory Model & GC

MQuickJS uses a **compacting garbage collector**. This has major implications:

### Objects Can Move

Any JS allocation can trigger GC, which **moves objects in memory**. This means:

```c
// WRONG - obj1 may be invalid after JS_NewObject creates obj2
JSValue obj1 = JS_NewObject(ctx);
JSValue obj2 = JS_NewObject(ctx);  // obj1's address may have changed!
JS_SetPropertyStr(ctx, obj1, "x", obj2);  // CRASH or corruption
```

### Use JSGCRef to Hold Values

```c
// CORRECT - use JSGCRef to protect values across allocations
JSValue my_func(JSContext *ctx, JSValue *this_val, int argc, JSValue *argv) {
    JSGCRef obj1_ref, obj2_ref;
    JSValue *obj1, *obj2, ret;

    ret = JS_EXCEPTION;

    // Push references - these track object movement
    obj1 = JS_PushGCRef(ctx, &obj1_ref);
    obj2 = JS_PushGCRef(ctx, &obj2_ref);

    *obj1 = JS_NewObject(ctx);
    if (JS_IsException(*obj1))
        goto fail;

    *obj2 = JS_NewObject(ctx);  // obj1 may move, but obj1_ref.val is updated
    if (JS_IsException(*obj2))
        goto fail;

    JS_SetPropertyStr(ctx, *obj1, "x", *obj2);  // Safe - using dereferenced pointers
    ret = *obj1;

fail:
    // Pop in reverse order (stack discipline)
    JS_PopGCRef(ctx, &obj2_ref);
    JS_PopGCRef(ctx, &obj1_ref);
    return ret;
}
```

### No JS_FreeValue

Unlike QuickJS, there's no reference counting. The GC handles all cleanup automatically.

## Defining Custom Classes

See `example_stdlib.c` for a complete example. The pattern:

### 1. Define class ID

```c
// In your header or source file
#define JS_CLASS_MY_WIDGET (JS_CLASS_USER + 0)
#define JS_CLASS_COUNT (JS_CLASS_USER + 1)  // Total class count
```

### 2. Define C functions

```c
// Constructor - note FRAME_CF_CTOR flag handling
static JSValue js_widget_constructor(JSContext *ctx, JSValue *this_val,
                                     int argc, JSValue *argv) {
    if (!(argc & FRAME_CF_CTOR))
        return JS_ThrowTypeError(ctx, "must be called with new");
    argc &= ~FRAME_CF_CTOR;

    JSValue obj = JS_NewObjectClassUser(ctx, JS_CLASS_MY_WIDGET);
    MyWidgetData *data = malloc(sizeof(*data));
    JS_SetOpaque(ctx, obj, data);

    // Initialize from argv...

    return obj;
}

// Finalizer - called when object is GC'd
static void js_widget_finalizer(JSContext *ctx, void *opaque) {
    MyWidgetData *data = opaque;
    free(data);
}

// Method
static JSValue js_widget_get_value(JSContext *ctx, JSValue *this_val,
                                   int argc, JSValue *argv) {
    if (JS_GetClassID(ctx, *this_val) != JS_CLASS_MY_WIDGET)
        return JS_ThrowTypeError(ctx, "not a Widget");
    MyWidgetData *data = JS_GetOpaque(ctx, *this_val);
    return JS_NewInt32(ctx, data->value);
}
```

### 3. Define property/method tables

```c
// Prototype methods (instance methods)
static const JSPropDef js_widget_proto[] = {
    JS_CGETSET_DEF("value", js_widget_get_value, NULL),
    JS_CFUNC_DEF("doSomething", 1, js_widget_do_something),
    JS_PROP_END,
};

// Static methods (on constructor)
static const JSPropDef js_widget_static[] = {
    JS_CFUNC_DEF("create", 2, js_widget_create),
    JS_PROP_END,
};

// Class definition
static const JSClassDef js_widget_class = JS_CLASS_DEF(
    "Widget",                    // JS name
    2,                           // constructor arg count
    js_widget_constructor,       // constructor function
    JS_CLASS_MY_WIDGET,          // class ID
    js_widget_static,            // static props (NULL if none)
    js_widget_proto,             // prototype props (NULL if none)
    NULL,                        // parent class (NULL if none)
    js_widget_finalizer          // finalizer (NULL if none)
);
```

### 4. Register in global object

```c
static const JSPropDef js_global_object[] = {
    // ... standard classes ...
    JS_PROP_CLASS_DEF("Widget", &js_widget_class),
    JS_PROP_END,
};
```

## Calling JS Functions from C

```c
// Check stack space first
if (JS_StackCheck(ctx, 3))
    return JS_EXCEPTION;

// Push arguments in reverse order
JS_PushArg(ctx, arg1);        // First argument
JS_PushArg(ctx, func_value);  // Function to call
JS_PushArg(ctx, this_value);  // 'this' value (JS_NULL for global)

// Call with argument count
JSValue result = JS_Call(ctx, 1);  // 1 argument
```

## Type Conversions

### C → JS

```c
JS_NewInt32(ctx, 42)           // int → Number
JS_NewFloat64(ctx, 3.14)       // double → Number
JS_NewString(ctx, "hello")     // char* → String
JS_NewStringLen(ctx, buf, len) // buffer → String
JS_NewBool(1)                  // int → Boolean (no ctx needed)
JS_NewObject(ctx)              // → empty Object
JS_NewArray(ctx, 5)            // → Array with initial length
JS_NULL                        // → null
JS_UNDEFINED                   // → undefined
```

### JS → C

```c
int val;
if (JS_ToInt32(ctx, &val, js_val))  // Returns non-zero on error
    return JS_EXCEPTION;

double dval;
if (JS_ToNumber(ctx, &dval, js_val))
    return JS_EXCEPTION;

JSCStringBuf buf;
const char *str = JS_ToCString(ctx, js_val, &buf);
// str is valid until next allocation or buf goes out of scope
```

## Error Handling

```c
// Throw an error
return JS_ThrowTypeError(ctx, "expected number, got %s", type_name);
return JS_ThrowRangeError(ctx, "index out of bounds: %d", idx);

// Check for exception
if (JS_IsException(result)) {
    JSValue err = JS_GetException(ctx);
    // Log or handle error
    return JS_EXCEPTION;
}
```

## Precompiled Bytecode

For ROM-constrained systems, you can precompile JS to bytecode:

```c
// On build host: compile and save
JSValue code = JS_Parse(ctx, source, source_len, "script.js", 0);
JSBytecodeHeader hdr;
const uint8_t *data;
uint32_t data_len;
JS_PrepareBytecode(ctx, &hdr, &data, &data_len, code);
// Write hdr + data to file

// On target: load and run
if (JS_IsBytecode(buf, buf_len)) {
    JS_RelocateBytecode(ctx, buf, buf_len);
    JSValue code = JS_LoadBytecode(ctx, buf);
    JS_Run(ctx, code);
}
```

## JavaScript Subset Limitations

Be aware of these restrictions when writing JS for MQuickJS:

- **Strict mode only** - all code runs in strict mode
- **No array holes** - `[1,,3]` is a syntax error; `a[10] = x` on empty array throws
- **No direct eval** - only `(1,eval)(...)` works
- **No value boxing** - `new Number(1)` not supported
- **Limited Date** - only `Date.now()` available
- **for..of arrays only** - no custom iterators
- **Properties always writable/enumerable/configurable**

## Debug Helpers

```c
JS_SetLogFunc(ctx, my_write_func);     // Set output for debug prints
JS_PrintValue(ctx, val);                // Print value
JS_PrintValueF(ctx, val, JS_DUMP_LONG); // Print with full object contents
JS_DumpMemory(ctx, 1);                  // Dump memory stats
```

## Memory Sizing

The memory buffer must hold:
- Context structures (~2-3KB overhead)
- All JS objects, strings, bytecode
- Execution stack
- GC working space

Start with 64KB for simple scripts. Use `JS_DumpMemory()` to analyze usage. The engine can run meaningful programs in as little as 10KB.

## File Reference Summary

When integrating, you'll typically need:

**Required source files:**
- `mquickjs.c` - core engine
- `dtoa.c` - number formatting
- `libm.c` - math (or link system libm)
- `cutils.c` - utilities

**Required headers:**
- `mquickjs.h` - public API
- `mquickjs_build.h` - for stdlib definition
- `cutils.h`, `dtoa.h`, `libm.h` - internal dependencies

**Build-time only:**
- `mquickjs_build.c` - stdlib generator (compiled as host tool)

**Reference implementations:**
- `example.c` - minimal embedding example
- `example_stdlib.c` - custom class example
- `mqjs.c` - full REPL implementation
- `mqjs_stdlib.c` - complete stdlib definition
