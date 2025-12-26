# MquickjsEx API Design

An Elixir library for executing JavaScript code using MQuickJS, a lightweight JavaScript engine optimized for embedded systems.

## Core Concepts

MQuickJS is a stripped-down JavaScript engine (ES5 subset with stricter rules) that:
- Runs in a fixed memory buffer (no malloc)
- Uses a compacting garbage collector
- Supports precompiled bytecode

This library wraps MQuickJS via NIFs, providing an ergonomic Elixir API inspired by [tv-labs/lua](https://github.com/tv-labs/lua).

## Basic Usage

### Creating a JavaScript Context

```elixir
# Create a new JS context with default memory (64KB)
js = MquickjsEx.new()

# Create with custom memory limit
js = MquickjsEx.new(memory: 128 * 1024)  # 128KB
```

### Evaluating JavaScript Code

```elixir
# Simple evaluation - returns {result, updated_state}
{result, js} = MquickjsEx.eval!(js, "2 + 2")
# result => 4

# Multi-statement code
{result, js} = MquickjsEx.eval!(js, """
  var x = 10;
  var y = 20;
  x + y
""")
# result => 30

# Without return value (faster, returns nil)
{nil, js} = MquickjsEx.eval!(js, "var counter = 0;")
```

### Error Handling

```elixir
# Bang version raises on JS errors
MquickjsEx.eval!(js, "undefined_var")
# ** (MquickjsEx.Error) ReferenceError: undefined_var is not defined

# Non-bang version returns {:ok, result, state} or {:error, reason}
case MquickjsEx.eval(js, "risky_code()") do
  {:ok, result, js} -> handle_success(result)
  {:error, %MquickjsEx.Error{} = err} -> handle_error(err)
end
```

### State Persistence

The JS context maintains state across calls:

```elixir
js = MquickjsEx.new()

{_, js} = MquickjsEx.eval!(js, "var count = 0;")
{_, js} = MquickjsEx.eval!(js, "count++;")
{_, js} = MquickjsEx.eval!(js, "count++;")
{result, _} = MquickjsEx.eval!(js, "count")
# result => 2
```

## Getting and Setting Global Variables

### Setting Values

```elixir
js = MquickjsEx.new()

# Set a global variable
js = MquickjsEx.set!(js, :message, "Hello from Elixir")

# Access it from JS
{result, _} = MquickjsEx.eval!(js, "message")
# result => "Hello from Elixir"

# Set nested properties (creates objects as needed)
js = MquickjsEx.set!(js, [:config, :debug], true)
js = MquickjsEx.set!(js, [:config, :timeout], 5000)

{result, _} = MquickjsEx.eval!(js, "config.debug")
# result => true
```

### Getting Values

```elixir
js = MquickjsEx.new()
{_, js} = MquickjsEx.eval!(js, "var user = {name: 'Alice', age: 30};")

# Get a global variable
name = MquickjsEx.get!(js, :user)
# name => %{"name" => "Alice", "age" => 30}

# Get nested properties
name = MquickjsEx.get!(js, [:user, :name])
# name => "Alice"
```

## Type Conversions

### Elixir to JavaScript

| Elixir | JavaScript |
|--------|------------|
| `nil` | `null` |
| `true` / `false` | `true` / `false` |
| integers | number (31-bit signed) |
| floats | number |
| strings (binary) | string |
| atoms | string |
| lists | Array |
| maps | Object |

### JavaScript to Elixir

| JavaScript | Elixir |
|------------|--------|
| `null` | `nil` |
| `undefined` | `nil` |
| `true` / `false` | `true` / `false` |
| number (integer) | integer |
| number (float) | float |
| string | binary string |
| Array | list |
| Object | map with string keys |
| function | raises error (cannot serialize) |

## Compile-Time Validation (Sigil)

The `~JS` sigil validates JavaScript syntax at compile time:

```elixir
import MquickjsEx

# Syntax validated at compile time
code = ~JS"""
  function greet(name) {
    return "Hello, " + name;
  }
  greet("World")
"""

{result, _} = MquickjsEx.eval!(js, code)
# result => "Hello, World"
```

With the `c` modifier, the code is precompiled to bytecode:

```elixir
# Precompiled to bytecode at compile time (faster execution)
code = ~JS"""
  var sum = 0;
  for (var i = 0; i < 100; i++) {
    sum += i;
  }
  sum
"""c

{result, _} = MquickjsEx.eval!(js, code)
```

## Memory Management

MQuickJS operates within a fixed memory buffer:

```elixir
# Check memory usage
stats = MquickjsEx.memory_stats(js)
# %{used: 4096, total: 65536, percent: 6.25}

# Trigger garbage collection
js = MquickjsEx.gc(js)
```

## Interrupting Execution

For long-running scripts, you can set an interrupt handler:

```elixir
js = MquickjsEx.new()

# Set a timeout (milliseconds)
js = MquickjsEx.set_timeout(js, 1000)

# This will raise after 1 second
MquickjsEx.eval!(js, "while(true) {}")
# ** (MquickjsEx.TimeoutError) JavaScript execution timed out
```

---

## TODO: Future Features

The following features from the Lua library are planned but not yet implemented:

### Exposing Elixir Functions to JavaScript

```elixir
# TODO: Basic function exposure
js = MquickjsEx.set!(js, [:Math, :sum], fn args ->
  Enum.sum(args)
end)

{result, _} = MquickjsEx.eval!(js, "Math.sum([1, 2, 3, 4, 5])")
# result => 15
```

### API Modules (deflua equivalent)

```elixir
# TODO: Module-based API definition
defmodule MyAPI do
  use MquickjsEx.API

  defjs add(a, b) do
    a + b
  end

  defjs greet(name) do
    "Hello, #{name}!"
  end
end

js = MquickjsEx.new() |> MquickjsEx.load_api(MyAPI)
```

### Calling JavaScript Functions from Elixir

```elixir
# TODO: Direct function calls
{_, js} = MquickjsEx.eval!(js, """
  function multiply(a, b) {
    return a * b;
  }
""")

{result, _} = MquickjsEx.call_function!(js, :multiply, [3, 4])
# result => 12
```

### Private Context (Sandbox Isolation)

```elixir
# TODO: Private Elixir-side context invisible to JS
js = MquickjsEx.put_private(js, :api_key, "secret123")

# Accessible from exposed Elixir functions, but not from JS code
js = MquickjsEx.set!(js, :make_request, fn args, js ->
  api_key = MquickjsEx.get_private!(js, :api_key)
  # Use api_key to make authenticated request
end)
```

### Userdata (Opaque Elixir Terms)

```elixir
# TODO: Pass Elixir terms through JS as opaque references
js = MquickjsEx.set!(js, :conn, {:userdata, conn})

# JS can pass it back to Elixir functions but can't inspect it
```

---

## MQuickJS Limitations

Be aware of MQuickJS's stricter JavaScript mode:

1. **Strict mode only** - No `with` keyword, globals must be declared with `var`
2. **No array holes** - `[1, , 3]` is a syntax error
3. **Limited Date** - Only `Date.now()` is supported
4. **ASCII-only case functions** - `toLowerCase`/`toUpperCase` only handle ASCII
5. **No direct eval** - Only global `eval` via `(1, eval)('code')`
6. **ES5 subset** - No `let`/`const`, no arrow functions, no classes
