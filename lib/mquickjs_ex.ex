defmodule MquickjsEx do
  @moduledoc """
  MquickjsEx embeds MQuickJS (a minimal JavaScript engine) into Elixir via NIFs.
  """

  alias MquickjsEx.NIF

  @doc """
  Create a new JavaScript context.

  ## Options

    * `:memory` - Memory size in bytes for the JS heap (default: 65536 = 64KB)

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> is_reference(ctx)
      true

  """
  def new(opts \\ []) do
    mem_size = Keyword.get(opts, :memory, 65536)
    NIF.nif_new(mem_size)
  end

  @doc """
  Evaluate JavaScript code in the given context.

  Returns `{:ok, :executed}` on success, or `{:error, reason}` on failure.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> MquickjsEx.eval(ctx, "var x = 1 + 2;")
      {:ok, :executed}

  """
  def eval(ctx, code) when is_binary(code) do
    NIF.nif_eval(ctx, code)
  end

  @doc """
  Evaluate JavaScript code, raising on error.

  Returns `{:ok, ctx}` on success to allow chaining.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> {:ok, ^ctx} = MquickjsEx.eval!(ctx, "var x = 1 + 2;")

  """
  def eval!(ctx, code) when is_binary(code) do
    case NIF.nif_eval(ctx, code) do
      {:ok, _} -> {:ok, ctx}
      {:error, reason} -> raise "JS Error: #{inspect(reason)}"
    end
  end
end
