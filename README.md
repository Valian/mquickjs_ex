# MquickjsEx

[![Hex.pm](https://img.shields.io/hexpm/v/mquickjs_ex.svg)](https://hex.pm/packages/mquickjs_ex)
[![Elixir](https://img.shields.io/badge/elixir-%3E%3D%201.16-blueviolet)](https://elixir-lang.org/)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)

<!-- MDOC !-->

**Embed a JavaScript engine inside your Elixir process using [MQuickJS](https://bellard.org/mquickjs/).**

MquickjsEx provides an ergonomic interface to MQuickJS, a minimal JavaScript engine targeting embedded systems. It runs JavaScript code in as little as 10KB of RAM while enabling bidirectional function calls between Elixir and JavaScript.

## Why MquickjsEx?

**No external runtime required.** Unlike solutions that shell out to Node.js or Bun, MquickjsEx embeds JavaScript execution directly in your Elixir process via NIFs. No separate runtime to install, no process spawning, no IPC overhead.

**Perfect for LLM tool calling.** When an LLM generates JavaScript code (for data transformation, calculations, or custom logic), MquickjsEx can execute it safely in a sandboxed environment with controlled access to your Elixir functions. The LLM writes JavaScript; you control what it can actually do.

```elixir
# LLM generates this code
js_code = """
var data = fetch_records("users");
var active = data.filter(function(u) { return u.status === "active"; });
save_result(active.length);
"""

# You control what functions are available
ctx = MquickjsEx.new!()
      |> MquickjsEx.set!(:fetch_records, fn [table] -> MyApp.Repo.all(table) end)
      |> MquickjsEx.set!(:save_result, fn [val] -> send(self(), {:result, val}) end)

MquickjsEx.eval!(ctx, js_code)
```

## Features

- **No dependencies** - No Node.js, Bun, or Deno installation required
- **In-process** - Runs in the BEAM, no subprocess spawning or IPC
- **Lightweight** - MQuickJS runs in a fixed memory buffer (default 64KB)
- **Safe** - JavaScript runs in a sandboxed environment with no file system or network access
- **Bidirectional** - Call JavaScript from Elixir and Elixir from JavaScript
- **Type conversion** - Automatic conversion between Elixir and JavaScript types
- **API modules** - Define reusable function sets with the `MquickjsEx.API` behaviour
- **Private storage** - Store Elixir data associated with a context without exposing it to JavaScript

## Installation

Add `mquickjs_ex` to your list of dependencies in `mix.exs`:

```elixir
def deps do
  [
    {:mquickjs_ex, "~> 0.1.0"}
  ]
end
```

## Quick Start

```elixir
# Create a new JavaScript context
{:ok, ctx} = MquickjsEx.new()

# Evaluate JavaScript code
{:ok, result} = MquickjsEx.eval(ctx, "1 + 2")
# => {:ok, 3}

# Set values in JavaScript
ctx = MquickjsEx.set!(ctx, :message, "Hello from Elixir")
{:ok, msg} = MquickjsEx.eval(ctx, "message")
# => {:ok, "Hello from Elixir"}

# Call Elixir functions from JavaScript
ctx = MquickjsEx.set!(ctx, :add, fn [a, b] -> a + b end)
{result, _ctx} = MquickjsEx.eval!(ctx, "add(40, 2)")
# => 42
```

## Type Conversions

| Elixir            | JavaScript           | Notes                          |
|-------------------|----------------------|--------------------------------|
| `nil`             | `null`               |                                |
| `true` / `false`  | `true` / `false`     |                                |
| integers          | number               | 31-bit signed integers         |
| floats            | number               | 64-bit floating point          |
| binaries          | string               | UTF-8 encoded                  |
| atoms             | string               | Converted via `to_string/1`    |
| lists             | Array                |                                |
| maps              | Object               |                                |
| functions         | callable             | Via trampoline (see below)     |

## Calling Elixir from JavaScript

When you register an Elixir function with `set/3`, it becomes callable from JavaScript. Under the hood, this uses a **trampoline pattern** with re-execution:

### How It Works

1. JavaScript code calls a registered function (e.g., `add(1, 2)`)
2. The call throws a special `__yield__` exception, halting JavaScript execution
3. Control returns to Elixir, which executes the callback with the provided arguments
4. The result is cached and JavaScript code is **re-executed from the beginning**
5. On replay, the cached result is returned instead of yielding
6. This repeats until all callbacks complete and JavaScript finishes

```
Run 1: JS executes → calls add(1,2) → yields to Elixir → Elixir computes 3
Run 2: JS executes → add(1,2) returns 3 (cached) → JS completes
```

For multiple callback calls, each run replays from the start with accumulated cached results:

```
Run 1: code → fetch("a") → yields       [cache: ]
Run 2: code → fetch("a")=cached → fetch("b") → yields   [cache: result_a]
Run 3: code → fetch("a")=cached → fetch("b")=cached → completes   [cache: result_a, result_b]
```

### Implications

- **Idempotent code**: JavaScript code should be idempotent (no side effects that accumulate on replay)
- **Performance**: Multiple callbacks mean multiple re-executions; keep callback-heavy code efficient
- **Determinism**: Code must execute the same way each time to hit cached results in order

## Defining API Modules

For reusable function sets, use the `MquickjsEx.API` behaviour:

```elixir
defmodule MathAPI do
  use MquickjsEx.API, scope: "math"

  defjs add(a, b), do: a + b
  defjs multiply(a, b), do: a * b
end

{:ok, ctx} = MquickjsEx.new()
{:ok, ctx} = MquickjsEx.load_api(ctx, MathAPI)

{:ok, 5} = MquickjsEx.eval(ctx, "math.add(2, 3)")
{:ok, 6} = MquickjsEx.eval(ctx, "math.multiply(2, 3)")
```

### Nested Scopes

```elixir
use MquickjsEx.API, scope: "utils.math"
# Functions available as: utils.math.add(1, 2)
```

### Accessing Context State

Use the three-argument form of `defjs` to access or modify the JavaScript context:

```elixir
defmodule ConfigAPI do
  use MquickjsEx.API, scope: "config"

  # Read-only access to state
  defjs get(key), state do
    MquickjsEx.get!(state, key)
  end

  # Modify state by returning {result, new_state}
  defjs set(key, value), state do
    new_state = MquickjsEx.set!(state, key, value)
    {nil, new_state}
  end
end
```

### Variadic Functions

For functions accepting any number of arguments:

```elixir
@variadic true
defjs sum(args), do: Enum.sum(args)

# Called as: sum(1, 2, 3, 4, 5) => 15
```

### Install Callback

Run setup code when the API is loaded:

```elixir
@impl MquickjsEx.API
def install(ctx, _scope, _data) do
  MquickjsEx.set!(ctx, :api_loaded, true)
end

# Or return JavaScript code to evaluate:
@impl MquickjsEx.API
def install(_ctx, _scope, _data) do
  "var API_VERSION = 1;"
end
```

## Private Storage

Store Elixir data associated with a context without exposing it to JavaScript:

```elixir
{:ok, ctx} = MquickjsEx.new()
ctx = MquickjsEx.put_private(ctx, :user_id, 123)
ctx = MquickjsEx.put_private(ctx, :session, %{role: :admin})

{:ok, 123} = MquickjsEx.get_private(ctx, :user_id)
123 = MquickjsEx.get_private!(ctx, :user_id)

ctx = MquickjsEx.delete_private(ctx, :user_id)
:error = MquickjsEx.get_private(ctx, :user_id)
```

Private storage is useful for passing context to API callbacks:

```elixir
defmodule UserAPI do
  use MquickjsEx.API, scope: "user"

  defjs current_id(), state do
    MquickjsEx.get_private!(state, :user_id)
  end
end
```

## Memory Configuration

Configure the JavaScript heap size when creating a context:

```elixir
# Default: 64KB
{:ok, ctx} = MquickjsEx.new()

# Custom size: 128KB
{:ok, ctx} = MquickjsEx.new(memory: 131072)

# Minimal: 10KB (MQuickJS can run in as little as 10KB!)
{:ok, ctx} = MquickjsEx.new(memory: 10240)
```

## JavaScript Subset (MQuickJS Limitations)

MQuickJS implements a subset of JavaScript close to ES5 in a **stricter mode**:

### Always Strict Mode

- No `with` keyword
- Global variables must be declared with `var`

### Array Restrictions

- Arrays cannot have holes: `a[10] = 1` throws `TypeError` if `a.length < 10`
- Array literals with holes are syntax errors: `[1, , 3]` is invalid
- Use objects for sparse array-like structures

### No Direct `eval`

```javascript
eval('1 + 2');        // Forbidden
(1, eval)('1 + 2');   // OK (indirect/global eval)
```

### No Value Boxing

`new Number(1)`, `new String("x")`, `new Boolean(true)` are not supported.

### Limited Built-ins

- `Date`: Only `Date.now()` is supported
- `String.toLowerCase()`/`toUpperCase()`: ASCII only
- `RegExp`: Case folding is ASCII only; matching is unicode-only

### Supported ES6+ Features

- `for...of` (arrays only, no custom iterators)
- Typed arrays
- `\u{hex}` unicode escapes in strings
- Math: `imul`, `clz32`, `fround`, `trunc`, `log2`, `log10`
- Exponentiation operator (`**`)
- RegExp: `s`, `y`, `u` flags
- String: `codePointAt`, `replaceAll`, `trimStart`, `trimEnd`
- `globalThis`

For the complete reference, see the [MQuickJS documentation](https://bellard.org/mquickjs/).

<!-- MDOC !-->

## API Reference

### Context Management

| Function | Description |
|----------|-------------|
| `new/1` | Create a new JavaScript context |
| `eval/2` | Evaluate JavaScript code, returns `{:ok, result}` or `{:error, reason}` |
| `eval!/2` | Evaluate JavaScript code, raises on error, returns `{result, ctx}` |
| `get/2` | Get a global variable |
| `get!/2` | Get a global variable, raises on error |
| `set/3` | Set a global variable or function |
| `set!/3` | Set a global variable or function, raises on error |
| `gc/1` | Trigger garbage collection |

### API Modules

| Function | Description |
|----------|-------------|
| `load_api/3` | Load an API module, returns `{:ok, ctx}` or `{:error, reason}` |
| `load_api!/3` | Load an API module, raises on error, returns `ctx` |

### Private Storage

| Function | Description |
|----------|-------------|
| `put_private/3` | Store a key-value pair in private storage |
| `get_private/2` | Retrieve a value, returns `{:ok, value}` or `:error` |
| `get_private!/2` | Retrieve a value, raises if not found |
| `delete_private/2` | Remove a key from private storage |

## Acknowledgments

This project builds on [MQuickJS](https://github.com/bellard/mquickjs) by Fabrice Bellard and Charlie Gordon - a remarkable minimal JavaScript engine that makes embedding JS in resource-constrained environments possible.

**Based on tv-labs/lua:**

The Elixir API design and significant portions of the macro system are derived from [tv-labs/lua](https://github.com/tv-labs/lua) by TV Labs Ltd. Specifically:

- The `MquickjsEx.API` module with its `defjs` macro is adapted from `Lua.API` and `deflua`
- The public API patterns (`new`, `eval`, `get`, `set`, `load_api`, private storage) follow tv-labs/lua's design
- The exception handling structure is adapted from `Lua.RuntimeException`

We are grateful to the tv-labs/lua maintainers for creating such an ergonomic interface pattern for embedding scripting languages in Elixir.

**Other inspiration:**

- [livebook-dev/pythonx](https://github.com/livebook-dev/pythonx) - Demonstrated embedding another language runtime directly in the BEAM

## License

Apache 2.0 - see [LICENSE](LICENSE) and [NOTICE](NOTICE) for details.

### Third-Party Code

This library includes:

- Vendored code from [MQuickJS](https://github.com/bellard/mquickjs) (Micro QuickJS JavaScript Engine) by Fabrice Bellard and Charlie Gordon, licensed under the MIT License. See `c_src/vendor/LICENSE` for details.

- Code derived from [tv-labs/lua](https://github.com/tv-labs/lua) by TV Labs Ltd, licensed under the Apache License 2.0. See [NOTICE](NOTICE) for attribution details.
