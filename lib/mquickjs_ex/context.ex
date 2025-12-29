defmodule MquickjsEx.Context do
  @moduledoc false

  @type callback_meta :: %{
          fun: function(),
          uses_state: boolean(),
          variadic: boolean()
        }

  @type callback_entry :: function() | callback_meta()

  defstruct [:ref, callbacks: %{}, loaded_apis: [], private: %{}]

  @type t :: %__MODULE__{
          ref: reference(),
          callbacks: %{String.t() => callback_entry()},
          loaded_apis: [module()],
          private: map()
        }

  @spec new(reference()) :: t()
  def new(ref) when is_reference(ref) do
    %__MODULE__{ref: ref}
  end

  @doc """
  Register a simple callback function (legacy format).
  """
  @spec put_callback(t(), atom() | String.t(), function()) :: t()
  def put_callback(%__MODULE__{} = ctx, name, fun) when is_function(fun) do
    %{ctx | callbacks: Map.put(ctx.callbacks, to_string(name), fun)}
  end

  @doc """
  Register a callback with metadata (from API module).
  """
  @spec put_callback_meta(t(), String.t(), function(), boolean(), boolean()) :: t()
  def put_callback_meta(%__MODULE__{} = ctx, name, fun, uses_state, variadic)
      when is_function(fun) and is_boolean(uses_state) and is_boolean(variadic) do
    meta = %{fun: fun, uses_state: uses_state, variadic: variadic}
    %{ctx | callbacks: Map.put(ctx.callbacks, name, meta)}
  end

  @doc """
  Track that an API module has been loaded.
  """
  @spec add_loaded_api(t(), module()) :: t()
  def add_loaded_api(%__MODULE__{loaded_apis: apis} = ctx, module) when is_atom(module) do
    %{ctx | loaded_apis: [module | apis]}
  end

  @spec has_callbacks?(t()) :: boolean()
  def has_callbacks?(%__MODULE__{callbacks: callbacks}) do
    map_size(callbacks) > 0
  end
end
