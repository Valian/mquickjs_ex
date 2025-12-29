defmodule MquickjsEx.Context do
  @moduledoc false

  defstruct [:ref, callbacks: %{}]

  @type t :: %__MODULE__{
          ref: reference(),
          callbacks: %{String.t() => function()}
        }

  @spec new(reference()) :: t()
  def new(ref) when is_reference(ref) do
    %__MODULE__{ref: ref}
  end

  @spec put_callback(t(), atom() | String.t(), function()) :: t()
  def put_callback(%__MODULE__{} = ctx, name, fun) when is_function(fun) do
    %{ctx | callbacks: Map.put(ctx.callbacks, to_string(name), fun)}
  end

  @spec has_callbacks?(t()) :: boolean()
  def has_callbacks?(%__MODULE__{callbacks: callbacks}) do
    map_size(callbacks) > 0
  end
end
