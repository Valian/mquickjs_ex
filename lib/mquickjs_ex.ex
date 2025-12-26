defmodule MquickjsEx do
  @moduledoc """
  MquickjsEx embeds MQuickJS (a minimal JavaScript engine) into Elixir via NIFs.

  ## Basic Usage

      {:ok, ctx} = MquickjsEx.new()
      {:ok, result} = MquickjsEx.eval(ctx, "1 + 2")
      # result => 3

  ## Setting Values and Functions

  Use `set/3` to set both values and functions:

      {:ok, ctx} = MquickjsEx.new()
      ctx = MquickjsEx.set!(ctx, :config, %{debug: true})
      ctx = MquickjsEx.set!(ctx, :add, fn [a, b] -> a + b end)
      {result, _} = MquickjsEx.eval!(ctx, "add(1, 2)")
      # result => 3

  ## Type Conversions

  | Elixir        | JavaScript |
  |---------------|------------|
  | `nil`         | `null`     |
  | `true`/`false`| `true`/`false` |
  | integers      | number (31-bit signed) |
  | floats        | number     |
  | binaries      | string     |
  | atoms         | string     |
  | lists         | Array      |
  | maps          | Object     |
  | functions     | callable (via trampoline) |

  """

  alias MquickjsEx.Context
  alias MquickjsEx.NIF

  @doc """
  Create a new JavaScript context.

  ## Options

    * `:memory` - Memory size in bytes for the JS heap (default: 65536 = 64KB)

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> is_struct(ctx, MquickjsEx.Context)
      true

  """
  def new(opts \\ []) do
    mem_size = Keyword.get(opts, :memory, 65536)

    case NIF.nif_new(mem_size) do
      {:ok, ref} -> {:ok, Context.new(ref)}
      error -> error
    end
  end

  @doc """
  Evaluate JavaScript code in the given context.

  Returns `{:ok, result}` where result is the value of the last expression,
  or `{:error, reason}` on failure.

  If the context has registered callback functions (set via `set/3`), they
  will be available to call from the JavaScript code.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> MquickjsEx.eval(ctx, "1 + 2")
      {:ok, 3}

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> MquickjsEx.eval(ctx, ~s|"hello"|)
      {:ok, "hello"}

  """
  def eval(%Context{} = ctx, code) when is_binary(code) do
    if Context.has_callbacks?(ctx) do
      case run_with_callbacks(ctx, code, ctx.callbacks) do
        {:ok, result, _ctx} -> {:ok, result}
        {:error, _} = error -> error
      end
    else
      NIF.nif_eval(ctx.ref, code)
    end
  end

  @doc """
  Evaluate JavaScript code, raising on error.

  Returns `{result, ctx}` on success to allow chaining.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> {result, _ctx} = MquickjsEx.eval!(ctx, "1 + 2")
      iex> result
      3

  """
  def eval!(%Context{} = ctx, code) when is_binary(code) do
    if Context.has_callbacks?(ctx) do
      case run_with_callbacks(ctx, code, ctx.callbacks) do
        {:ok, result, ctx} -> {result, ctx}
        {:error, reason} when is_binary(reason) -> raise "JS Error: #{reason}"
        {:error, reason} -> raise "JS Error: #{inspect(reason)}"
      end
    else
      case NIF.nif_eval(ctx.ref, code) do
        {:ok, result} -> {result, ctx}
        {:error, reason} when is_binary(reason) -> raise "JS Error: #{reason}"
        {:error, reason} -> raise "JS Error: #{inspect(reason)}"
      end
    end
  end

  @doc """
  Get a global variable from the JavaScript context.

  The variable name can be an atom or string.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> MquickjsEx.eval(ctx, "var x = 42;")
      iex> MquickjsEx.get(ctx, :x)
      {:ok, 42}

  """
  def get(%Context{} = ctx, name) when is_atom(name) or is_binary(name) do
    NIF.nif_get(ctx.ref, name)
  end

  @doc """
  Get a global variable, raising on error.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> {_, ctx} = MquickjsEx.eval!(ctx, "var x = 42;")
      iex> MquickjsEx.get!(ctx, :x)
      42

  """
  def get!(%Context{} = ctx, name) when is_atom(name) or is_binary(name) do
    case NIF.nif_get(ctx.ref, name) do
      {:ok, value} -> value
      {:error, reason} when is_binary(reason) -> raise "JS Error: #{reason}"
      {:error, reason} -> raise "JS Error: #{inspect(reason)}"
    end
  end

  @doc """
  Set a global variable or function in the JavaScript context.

  The variable name can be an atom or string. The value is converted
  from Elixir to JavaScript according to the type conversion table.

  If the value is a function (arity 1, receiving a list of arguments),
  it becomes a callable JavaScript function via the trampoline pattern.

  Returns `{:ok, ctx}` on success (with potentially updated context for functions),
  or `{:error, reason}` on failure.

  ## Examples

      # Setting a value
      iex> {:ok, ctx} = MquickjsEx.new()
      iex> {:ok, ctx} = MquickjsEx.set(ctx, :message, "Hello from Elixir")
      iex> MquickjsEx.eval(ctx, "message")
      {:ok, "Hello from Elixir"}

      # Setting a function
      iex> {:ok, ctx} = MquickjsEx.new()
      iex> {:ok, ctx} = MquickjsEx.set(ctx, :add, fn [a, b] -> a + b end)
      iex> MquickjsEx.eval(ctx, "add(1, 2)")
      {:ok, 3}

  """
  def set(%Context{} = ctx, name, fun) when (is_atom(name) or is_binary(name)) and is_function(fun, 1) do
    {:ok, Context.put_callback(ctx, name, fun)}
  end

  def set(%Context{} = ctx, name, value) when is_atom(name) or is_binary(name) do
    case NIF.nif_set(ctx.ref, name, value) do
      :ok -> {:ok, ctx}
      error -> error
    end
  end

  @doc """
  Set a global variable or function, raising on error.

  Returns the context for chaining.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> ctx = MquickjsEx.set!(ctx, :x, 100)
      iex> MquickjsEx.get!(ctx, :x)
      100

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> ctx = MquickjsEx.set!(ctx, :double, fn [x] -> x * 2 end)
      iex> {result, _} = MquickjsEx.eval!(ctx, "double(21)")
      iex> result
      42

  """
  def set!(%Context{} = ctx, name, fun) when (is_atom(name) or is_binary(name)) and is_function(fun, 1) do
    Context.put_callback(ctx, name, fun)
  end

  def set!(%Context{} = ctx, name, value) when is_atom(name) or is_binary(name) do
    case NIF.nif_set(ctx.ref, name, value) do
      :ok -> ctx
      {:error, reason} when is_binary(reason) -> raise "JS Error: #{reason}"
      {:error, reason} -> raise "JS Error: #{inspect(reason)}"
    end
  end

  @doc """
  Trigger garbage collection in the JavaScript context.

  Returns `:ok`.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> MquickjsEx.gc(ctx)
      :ok

  """
  def gc(%Context{} = ctx) do
    NIF.nif_gc(ctx.ref)
  end

  @doc """
  Run JavaScript code with callback support.

  This function enables JavaScript code to call back into Elixir functions
  using the trampoline pattern. The `callbacks` parameter is a map of
  function names to Elixir functions.

  Note: If you've set functions via `set/3`, you can use `eval/2` instead -
  the registered callbacks will be available automatically.

  ## How It Works

  When JS code calls a registered callback function, the execution yields
  to Elixir, which executes the callback and resumes JS execution with
  the result. This process repeats until the code completes.

  Note: Due to MQuickJS limitations, code before each callback may execute
  multiple times (replay pattern). Avoid side effects before your first callback.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> {:ok, result, _ctx} = MquickjsEx.run(ctx, \"fetch_data('url')\", %{
      ...>   \"fetch_data\" => fn [url] -> \"data from \#{url}\" end
      ...> })
      iex> result
      \"data from url\"

      # Multiple callbacks
      iex> {:ok, ctx} = MquickjsEx.new()
      iex> callbacks = %{
      ...>   \"add\" => fn [a, b] -> a + b end,
      ...>   \"multiply\" => fn [a, b] -> a * b end
      ...> }
      iex> {:ok, result, _ctx} = MquickjsEx.run(ctx, \"add(2, 3) + multiply(4, 5)\", callbacks)
      iex> result
      25

  ## Parameters

    * `ctx` - The JavaScript context
    * `code` - JavaScript code to execute
    * `callbacks` - Map of function names (strings) to Elixir functions.
      Each function receives a list of arguments and should return a value.

  ## Returns

    * `{:ok, result, ctx}` - Code completed successfully
    * `{:error, reason}` - An error occurred

  """
  def run(%Context{} = ctx, code, callbacks \\ %{}) when is_binary(code) and is_map(callbacks) do
    # Merge explicit callbacks with context callbacks (explicit takes precedence)
    all_callbacks = Map.merge(ctx.callbacks, callbacks)
    run_with_callbacks(ctx, code, all_callbacks)
  end

  @doc """
  Run JavaScript code with callback support, raising on error.

  Same as `run/3` but raises on error and returns `{result, ctx}` for chaining.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> {result, _ctx} = MquickjsEx.run!(ctx, \"double(21)\", %{
      ...>   \"double\" => fn [x] -> x * 2 end
      ...> })
      iex> result
      42

  """
  def run!(%Context{} = ctx, code, callbacks \\ %{}) when is_binary(code) and is_map(callbacks) do
    case run(ctx, code, callbacks) do
      {:ok, result, ctx} -> {result, ctx}
      {:error, reason} when is_binary(reason) -> raise "JS Error: #{reason}"
      {:error, reason} -> raise "JS Error: #{inspect(reason)}"
    end
  end

  # Internal: run with callbacks (used by both eval and run when callbacks present)
  defp run_with_callbacks(%Context{} = ctx, code, callbacks) when is_map(callbacks) do
    wrapped_code = wrap_with_callbacks(code, Map.keys(callbacks))
    run_loop(ctx, wrapped_code, callbacks, [])
  end

  # Wrap user code with callback function definitions.
  # Each registered callback becomes a JS function that calls __call().
  defp wrap_with_callbacks(code, callback_names) do
    wrappers =
      callback_names
      |> Enum.map(fn name ->
        # Create a wrapper function that calls __call with the function name and args
        """
        function #{name}() {
          var args = [];
          for (var i = 0; i < arguments.length; i++) args.push(arguments[i]);
          return __call("#{name}", args);
        }
        """
      end)
      |> Enum.join("\n")

    # Just prepend the wrappers - user code runs in global scope
    # and the last expression value is returned by JS_EVAL_RETVAL
    "#{wrappers}\n#{code}"
  end

  # The run loop: execute code, handle yields, resume with results.
  defp run_loop(%Context{} = ctx, code, callbacks, cached_results) do
    # Convert cached results to JSON strings for the NIF
    cached_json = Enum.map(cached_results, &Jason.encode!/1)

    case NIF.nif_run(ctx.ref, code, cached_json) do
      {:ok, result} ->
        {:ok, result, ctx}

      {:yield, func_name, args_json} ->
        # Parse the args JSON
        case Jason.decode(args_json) do
          {:ok, args} ->
            # Look up the callback
            case Map.fetch(callbacks, func_name) do
              {:ok, callback} when is_function(callback) ->
                # Execute the callback
                try do
                  result = callback.(args)
                  # Add result to cache and re-run
                  run_loop(ctx, code, callbacks, cached_results ++ [result])
                rescue
                  e ->
                    {:error, "Callback error in #{func_name}: #{Exception.message(e)}"}
                end

              :error ->
                {:error, "Unknown callback: #{func_name}"}
            end

          {:error, _} ->
            {:error, "Failed to parse callback args"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end
end
