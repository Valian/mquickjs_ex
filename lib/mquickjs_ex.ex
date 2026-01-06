defmodule MquickjsEx do
  @external_resource "README.md"
  @moduledoc @external_resource
             |> File.read!()
             |> String.split("<!-- MDOC !-->")
             |> Enum.fetch!(1)

  alias MquickjsEx.Context
  alias MquickjsEx.NIF
  alias MquickjsEx.RuntimeException

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

  ## Options

    * `:timeout` - Timeout in milliseconds. If the execution exceeds this duration,
      it will be interrupted and `{:error, :timeout}` will be returned.
      A value of `0` or omitting this option means no timeout (default).

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> MquickjsEx.eval(ctx, "1 + 2")
      {:ok, 3}

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> MquickjsEx.eval(ctx, ~s|"hello"|)
      {:ok, "hello"}

      # With timeout
      iex> {:ok, ctx} = MquickjsEx.new()
      iex> MquickjsEx.eval(ctx, "2 + 2", timeout: 1000)
      {:ok, 4}

  """
  def eval(%Context{} = ctx, code, opts \\ []) when is_binary(code) do
    timeout = Keyword.get(opts, :timeout, 0)

    if Context.has_callbacks?(ctx) do
      case run_with_callbacks(ctx, code, ctx.callbacks, timeout) do
        {:ok, result, _ctx} -> {:ok, result}
        {:error, _} = error -> error
      end
    else
      NIF.nif_eval(ctx.ref, code, timeout)
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
    case eval(ctx, code) do
      {:ok, result} -> {result, ctx}
      {:error, reason} -> raise_js_error(reason)
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
    case get(ctx, name) do
      {:ok, value} -> value
      {:error, reason} -> raise_js_error(reason)
    end
  end

  @doc """
  Set a global variable or function in the JavaScript context.

  The variable name can be an atom or string. The value is converted
  from Elixir to JavaScript according to the type conversion table.

  If the value is a function, it becomes a callable JavaScript function
  via the trampoline pattern. The function receives a single argument:
  a list of all arguments passed from JavaScript.

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
  def set(%Context{} = ctx, name, fun)
      when (is_atom(name) or is_binary(name)) and is_function(fun) do
    {:ok, Context.put_callback(ctx, name, fun)}
  end

  def set(%Context{} = ctx, name, value) when is_atom(name) or is_binary(name) do
    set(ctx, [name], value)
  end

  def set(%Context{} = ctx, path, value) when is_list(path) and length(path) > 0 do
    case NIF.nif_set_path(ctx.ref, path, value) do
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
  def set!(%Context{} = ctx, name_or_path, value) do
    case set(ctx, name_or_path, value) do
      {:ok, ctx} -> ctx
      {:error, reason} -> raise_js_error(reason)
    end
  end

  @doc """
  Load an API module into the JavaScript context.

  The module must be defined using `use MquickjsEx.API`.

  Returns `{:ok, ctx}` on success, or `{:error, reason}` on failure.

  ## Examples

      defmodule MathAPI do
        use MquickjsEx.API, scope: "math"
        defjs add(a, b), do: a + b
        defjs multiply(a, b), do: a * b
      end

      {:ok, ctx} = MquickjsEx.new()
      {:ok, ctx} = MquickjsEx.load_api(ctx, MathAPI)
      {:ok, 5} = MquickjsEx.eval(ctx, "math.add(2, 3)")

  """
  def load_api(%Context{} = ctx, module, data \\ nil) when is_atom(module) do
    try do
      scope = module.scope()
      functions = module.__js_functions__()

      # Register each function as a callback with metadata
      ctx =
        Enum.reduce(functions, ctx, fn {name, uses_state, variadic}, acc ->
          full_name = build_full_name(scope, name)
          # Create function reference with correct arity
          fun = build_callback_fun(module, name, uses_state, variadic)
          Context.put_callback_meta(acc, full_name, fun, uses_state, variadic)
        end)

      # Track loaded API
      ctx = Context.add_loaded_api(ctx, module)

      # Run install callback if defined
      {:ok, MquickjsEx.API.install(ctx, module, scope, data)}
    rescue
      e in UndefinedFunctionError ->
        {:error, "Module #{inspect(module)} is not a valid MquickjsEx.API: #{Exception.message(e)}"}

      e in RuntimeException ->
        {:error, Exception.message(e)}
    end
  end

  @doc """
  Load an API module into the JavaScript context, raising on error.

  Returns the context for chaining.

  See `load_api/3` for details.
  """
  def load_api!(%Context{} = ctx, module, data \\ nil) when is_atom(module) do
    case load_api(ctx, module, data) do
      {:ok, ctx} -> ctx
      {:error, reason} -> raise_js_error(reason)
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
  Store a key-value pair in private storage.

  Private storage is useful for storing Elixir data that should be
  associated with the context but not exposed to JavaScript.

  Returns the updated context.

  ## Examples

      {:ok, ctx} = MquickjsEx.new()
      ctx = MquickjsEx.put_private(ctx, :user_id, 123)

  """
  def put_private(%Context{} = ctx, key, value) do
    %{ctx | private: Map.put(ctx.private, key, value)}
  end

  @doc """
  Retrieve a value from private storage.

  Returns `{:ok, value}` if the key exists, `:error` otherwise.

  ## Examples

      {:ok, ctx} = MquickjsEx.new()
      ctx = MquickjsEx.put_private(ctx, :user_id, 123)
      {:ok, 123} = MquickjsEx.get_private(ctx, :user_id)
      :error = MquickjsEx.get_private(ctx, :nonexistent)

  """
  def get_private(%Context{private: private}, key) do
    case Map.fetch(private, key) do
      {:ok, value} -> {:ok, value}
      :error -> :error
    end
  end

  @doc """
  Retrieve a value from private storage, raising if not found.

  ## Examples

      {:ok, ctx} = MquickjsEx.new()
      ctx = MquickjsEx.put_private(ctx, :user_id, 123)
      123 = MquickjsEx.get_private!(ctx, :user_id)

  """
  def get_private!(%Context{} = ctx, key) do
    case get_private(ctx, key) do
      {:ok, value} -> value
      :error -> raise "private key `#{inspect(key)}` does not exist"
    end
  end

  @doc """
  Remove a key from private storage.

  Returns the updated context.

  ## Examples

      {:ok, ctx} = MquickjsEx.new()
      ctx = MquickjsEx.put_private(ctx, :user_id, 123)
      ctx = MquickjsEx.delete_private(ctx, :user_id)
      :error = MquickjsEx.get_private(ctx, :user_id)

  """
  def delete_private(%Context{} = ctx, key) do
    %{ctx | private: Map.delete(ctx.private, key)}
  end

  # Build full function name with scope
  defp build_full_name([], name), do: to_string(name)

  defp build_full_name(scope, name) do
    Enum.join(scope ++ [to_string(name)], ".")
  end

  # Build a callback function that wraps the module function
  defp build_callback_fun(module, name, uses_state, variadic) do
    if uses_state do
      if variadic do
        # Variadic with state: fun(args, state)
        fn args, ctx ->
          apply(module, name, [args, ctx])
        end
      else
        # Non-variadic with state: fun(arg1, arg2, ..., state)
        fn args, ctx ->
          apply(module, name, args ++ [ctx])
        end
      end
    else
      if variadic do
        # Variadic without state: fun(args)
        fn args, _ctx ->
          apply(module, name, [args])
        end
      else
        # Non-variadic without state: fun(arg1, arg2, ...)
        fn args, _ctx ->
          apply(module, name, args)
        end
      end
    end
  end

  # Raise a JS error using RuntimeException
  defp raise_js_error(reason) when is_binary(reason) do
    raise RuntimeException, js_error: reason
  end

  defp raise_js_error(reason) do
    raise RuntimeException, js_error: inspect(reason)
  end

  # Internal: run with callbacks (used by eval when callbacks present)
  defp run_with_callbacks(%Context{} = ctx, code, callbacks, timeout) when is_map(callbacks) do
    wrapped_code = wrap_with_callbacks(code, Map.keys(callbacks))
    run_loop(ctx, wrapped_code, callbacks, [], timeout)
  end

  # Wrap user code with callback function definitions.
  # Each registered callback becomes a JS function that calls __call().
  # Handles scoped functions by creating namespace objects.
  defp wrap_with_callbacks(code, callback_names) do
    wrappers =
      callback_names
      |> Enum.map(&build_js_wrapper/1)
      |> Enum.join("\n")

    "#{wrappers}\n#{code}"
  end

  defp build_js_wrapper(name) do
    parts = String.split(name, ".")

    if length(parts) > 1 do
      # Scoped function - need namespace setup
      namespace_setup = build_namespace_setup(parts)
      func_wrapper = build_scoped_func_wrapper(name, parts)
      namespace_setup <> "\n" <> func_wrapper
    else
      # Simple top-level function
      """
      function #{name}() {
        var args = [];
        for (var i = 0; i < arguments.length; i++) args.push(arguments[i]);
        return __call("#{name}", args);
      }
      """
    end
  end

  defp build_namespace_setup(parts) do
    # For ["math", "utils", "add"], generate:
    # var math = math || {};
    # math.utils = math.utils || {};
    parts
    |> Enum.take(length(parts) - 1)
    |> Enum.with_index()
    |> Enum.map(fn {_part, idx} ->
      path = Enum.take(parts, idx + 1) |> Enum.join(".")

      if idx == 0 do
        "var #{path} = #{path} || {};"
      else
        "#{path} = #{path} || {};"
      end
    end)
    |> Enum.join("\n")
  end

  defp build_scoped_func_wrapper(full_name, parts) do
    path = Enum.join(parts, ".")

    """
    #{path} = function() {
      var args = [];
      for (var i = 0; i < arguments.length; i++) args.push(arguments[i]);
      return __call("#{full_name}", args);
    };
    """
  end

  # The run loop: execute code, handle yields, resume with results.
  defp run_loop(%Context{} = ctx, code, callbacks, cached_results, timeout) do
    # Convert cached results to JSON strings for the NIF
    cached_json = Enum.map(cached_results, &Jason.encode!/1)

    case NIF.nif_run(ctx.ref, code, cached_json, timeout) do
      {:ok, result} ->
        {:ok, result, ctx}

      {:yield, func_name, args_json} ->
        case Jason.decode(args_json) do
          {:ok, args} ->
            case Map.fetch(callbacks, func_name) do
              {:ok, callback_entry} ->
                try do
                  {result, new_ctx} = execute_callback(callback_entry, args, ctx)
                  run_loop(new_ctx, code, callbacks, cached_results ++ [result], timeout)
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

  # Execute callback - handles both legacy format (plain function) and new format (map with metadata)
  defp execute_callback(%{fun: fun, uses_state: true}, args, ctx) do
    case fun.(args, ctx) do
      {result, %Context{} = new_ctx} -> {result, new_ctx}
      result -> {result, ctx}
    end
  end

  defp execute_callback(%{fun: fun, uses_state: false}, args, ctx) do
    result = fun.(args, ctx)
    {result, ctx}
  end

  # Legacy format: plain function that receives args list
  defp execute_callback(fun, args, ctx) when is_function(fun) do
    result = fun.(args)
    {result, ctx}
  end
end
