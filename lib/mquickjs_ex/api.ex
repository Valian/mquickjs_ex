defmodule MquickjsEx.API do
  @moduledoc """
  Behaviour for defining JavaScript APIs callable from MquickjsEx contexts.

  ## Basic Usage

      defmodule MyAPI do
        use MquickjsEx.API

        defjs add(a, b), do: a + b
        defjs greet(name), do: "Hello, \#{name}!"
      end

      {:ok, ctx} = MquickjsEx.new()
      {:ok, ctx} = MquickjsEx.load_api(ctx, MyAPI)
      {:ok, 3} = MquickjsEx.eval(ctx, "add(1, 2)")

  ## Scoped APIs

  You can namespace your functions:

      defmodule MathAPI do
        use MquickjsEx.API, scope: "math"
        # or: use MquickjsEx.API, scope: [:math]

        defjs add(a, b), do: a + b
      end

      # Call as: math.add(1, 2)

  Nested scopes work too:

      use MquickjsEx.API, scope: "utils.math"
      # or: use MquickjsEx.API, scope: [:utils, :math]

      # Call as: utils.math.add(1, 2)

  ## Accessing State

  To access or modify the JavaScript context state, use the three-argument form:

      defjs get_config(key), state do
        MquickjsEx.get!(state, [key])
      end

      defjs set_config(key, value), state do
        new_state = MquickjsEx.set!(state, [key], value)
        {nil, new_state}  # Return {result, new_state} to modify state
      end

  ## Variadic Functions

  For functions that accept any number of arguments:

      @variadic true
      defjs sum(args), do: Enum.sum(args)

      # Call as: sum(1, 2, 3, 4, 5)

  ## Guards

  Pattern matching with guards works:

      defjs double(x) when is_number(x), do: x * 2
      defjs double(x) when is_binary(x), do: x <> x

  ## Argument Destructuring

  Pattern match on arguments:

      defjs first([head | _tail]), do: head
      defjs get_name(%{"name" => name}), do: name

  ## Install Callback

  Optionally run setup code when the API is loaded:

      @impl MquickjsEx.API
      def install(ctx, _scope, _data) do
        MquickjsEx.set!(ctx, :initialized, true)
      end

  Or return JavaScript code to evaluate:

      @impl MquickjsEx.API
      def install(_ctx, _scope, _data) do
        "var API_VERSION = 1;"
      end
  """

  alias MquickjsEx.Context

  @type scope_def :: list(String.t())

  @doc "Returns the scope path for this API module"
  @callback scope :: scope_def()

  @doc "Optional callback run when the API is loaded"
  @callback install(Context.t(), scope_def(), any()) :: Context.t() | String.t()

  @optional_callbacks [install: 3]

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @behaviour MquickjsEx.API
      Module.register_attribute(__MODULE__, :js_function, accumulate: true)
      @before_compile MquickjsEx.API
      @variadic false

      import MquickjsEx.API, only: [defjs: 2, defjs: 3, runtime_exception!: 1]

      @impl MquickjsEx.API
      def scope do
        unquote(MquickjsEx.API.normalize_scope(Keyword.get(opts, :scope, [])))
      end

      defoverridable scope: 0
    end
  end

  @doc false
  def normalize_scope(scope) when is_binary(scope) do
    scope |> String.split(".", trim: true)
  end

  def normalize_scope(scope) when is_list(scope) do
    Enum.map(scope, &to_string/1)
  end

  def normalize_scope(scope) when is_atom(scope) and not is_nil(scope) do
    [to_string(scope)]
  end

  def normalize_scope(nil), do: []
  def normalize_scope([]), do: []

  @doc """
  Define a JavaScript-callable function.

  ## Without state access

      defjs add(a, b), do: a + b

  ## With state access

      defjs get_value(key), state do
        MquickjsEx.get!(state, [key])
      end

  To modify state, return `{result, new_state}`:

      defjs set_value(key, value), state do
        {nil, MquickjsEx.set!(state, [key], value)}
      end
  """
  defmacro defjs(fa, rest) do
    name = extract_function_name(fa)

    quote do
      @js_function MquickjsEx.API.validate_func!(
                     {unquote(name), false,
                      Module.delete_attribute(__MODULE__, :variadic) || false},
                     __MODULE__,
                     @js_function
                   )

      def unquote(fa), unquote(rest)
    end
  end

  @doc """
  Define a JavaScript-callable function with state access.

  See `defjs/2` for details.
  """
  defmacro defjs(fa, state, rest) do
    name = extract_function_name(fa)

    # Append state param to function args using Macro.prewalk
    {fa_with_state, _} =
      Macro.prewalk(fa, :ok, fn
        {^name, context, args}, acc ->
          {{name, context, args ++ List.wrap(state)}, acc}

        ast, acc ->
          {ast, acc}
      end)

    quote do
      @js_function MquickjsEx.API.validate_func!(
                     {unquote(name), true,
                      Module.delete_attribute(__MODULE__, :variadic) || false},
                     __MODULE__,
                     @js_function
                   )

      def unquote(fa_with_state), unquote(rest)
    end
  end

  defp extract_function_name(fa) do
    case fa do
      {:when, _, [{name, _, _} | _]} -> name
      {name, _, _} -> name
    end
  end

  @doc """
  Raises a runtime exception with context about the API function.

  Use this in `defjs` functions to raise errors with proper context:

      defjs divide(a, b), do:
        if b == 0, do: runtime_exception!("division by zero"), else: a / b
  """
  defmacro runtime_exception!(message) do
    quote do
      {function, _arity} = __ENV__.function

      raise MquickjsEx.RuntimeException,
        scope: scope(),
        function: function,
        message: unquote(message)
    end
  end

  @doc false
  def validate_func!({name, uses_state, variadic}, module, values) do
    issue =
      Enum.find(values, fn
        {^name, prev_state, _variadic} -> prev_state != uses_state
        _ -> false
      end)

    if issue do
      raise CompileError,
        description:
          "#{Exception.format_mfa(module, name, [])} is inconsistently using state. " <>
            "All clauses must either use state or not use state."
    end

    {name, uses_state, variadic}
  end

  defmacro __before_compile__(env) do
    attributes =
      env.module
      |> Module.get_attribute(:js_function)
      |> Enum.uniq()
      |> Enum.reverse()

    quote do
      @doc false
      def __js_functions__ do
        unquote(Macro.escape(attributes))
      end
    end
  end

  @doc false
  def install(ctx, module, scope, data) do
    if function_exported?(module, :install, 3) do
      case module.install(ctx, scope, data) do
        %Context{} = new_ctx ->
          new_ctx

        code when is_binary(code) ->
          {_, new_ctx} = MquickjsEx.eval!(ctx, code)
          new_ctx

        other ->
          raise MquickjsEx.RuntimeException,
            message: "install/3 must return Context or JS code string, got #{inspect(other)}"
      end
    else
      ctx
    end
  end
end
