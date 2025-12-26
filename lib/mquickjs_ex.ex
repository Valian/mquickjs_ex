defmodule MquickjsEx do
  @moduledoc """
  MquickjsEx embeds MQuickJS (a minimal JavaScript engine) into Elixir via NIFs.

  ## Basic Usage

      {:ok, ctx} = MquickjsEx.new()
      {:ok, result} = MquickjsEx.eval(ctx, "1 + 2")
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

  Returns `{:ok, result}` where result is the value of the last expression,
  or `{:error, reason}` on failure.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> MquickjsEx.eval(ctx, "1 + 2")
      {:ok, 3}

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> MquickjsEx.eval(ctx, ~s|"hello"|)
      {:ok, "hello"}

  """
  def eval(ctx, code) when is_binary(code) do
    NIF.nif_eval(ctx, code)
  end

  @doc """
  Evaluate JavaScript code, raising on error.

  Returns `{result, ctx}` on success to allow chaining.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> {result, ^ctx} = MquickjsEx.eval!(ctx, "1 + 2")
      iex> result
      3

  """
  def eval!(ctx, code) when is_binary(code) do
    case NIF.nif_eval(ctx, code) do
      {:ok, result} -> {result, ctx}
      {:error, reason} when is_binary(reason) -> raise "JS Error: #{reason}"
      {:error, reason} -> raise "JS Error: #{inspect(reason)}"
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
  def get(ctx, name) when is_atom(name) or is_binary(name) do
    NIF.nif_get(ctx, name)
  end

  @doc """
  Get a global variable, raising on error.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> {_, ctx} = MquickjsEx.eval!(ctx, "var x = 42;")
      iex> MquickjsEx.get!(ctx, :x)
      42

  """
  def get!(ctx, name) when is_atom(name) or is_binary(name) do
    case NIF.nif_get(ctx, name) do
      {:ok, value} -> value
      {:error, reason} when is_binary(reason) -> raise "JS Error: #{reason}"
      {:error, reason} -> raise "JS Error: #{inspect(reason)}"
    end
  end

  @doc """
  Set a global variable in the JavaScript context.

  The variable name can be an atom or string. The value is converted
  from Elixir to JavaScript according to the type conversion table.

  Returns `:ok` on success, or `{:error, reason}` on failure.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> MquickjsEx.set(ctx, :message, "Hello from Elixir")
      :ok
      iex> MquickjsEx.eval(ctx, "message")
      {:ok, "Hello from Elixir"}

  """
  def set(ctx, name, value) when is_atom(name) or is_binary(name) do
    NIF.nif_set(ctx, name, value)
  end

  @doc """
  Set a global variable, raising on error.

  Returns the context for chaining.

  ## Examples

      iex> {:ok, ctx} = MquickjsEx.new()
      iex> ctx = MquickjsEx.set!(ctx, :x, 100)
      iex> MquickjsEx.get!(ctx, :x)
      100

  """
  def set!(ctx, name, value) when is_atom(name) or is_binary(name) do
    case NIF.nif_set(ctx, name, value) do
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
  def gc(ctx) do
    NIF.nif_gc(ctx)
  end
end
