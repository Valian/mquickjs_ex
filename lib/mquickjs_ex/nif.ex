defmodule MquickjsEx.NIF do
  @moduledoc false
  @on_load :load_nif

  def load_nif do
    path = :filename.join(:code.priv_dir(:mquickjs_ex), ~c"mquickjs_ex")

    case :erlang.load_nif(path, 0) do
      :ok -> :ok
      {:error, {:reload, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  def nif_new(_mem_size), do: :erlang.nif_error(:not_loaded)
  def nif_eval(_ctx, _code), do: :erlang.nif_error(:not_loaded)
end
