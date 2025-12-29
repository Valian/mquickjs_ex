defmodule MquickjsEx.RuntimeException do
  @moduledoc """
  Exception raised when JavaScript execution fails or an API function encounters an error.
  """

  defexception [:message, :scope, :function, :js_error]

  @type t :: %__MODULE__{
          message: String.t(),
          scope: list(String.t()) | nil,
          function: atom() | nil,
          js_error: String.t() | nil
        }

  @impl true
  def exception(opts) when is_list(opts) do
    cond do
      # API function error with scope/function context
      Keyword.has_key?(opts, :scope) and Keyword.has_key?(opts, :function) ->
        scope = Keyword.get(opts, :scope, [])
        function = Keyword.get(opts, :function)
        msg = Keyword.get(opts, :message, "unknown error")

        path =
          if scope == [] do
            to_string(function)
          else
            Enum.join(scope ++ [to_string(function)], ".")
          end

        %__MODULE__{
          message: "#{path}: #{msg}",
          scope: scope,
          function: function,
          js_error: nil
        }

      # Plain JS error
      Keyword.has_key?(opts, :js_error) ->
        js_error = Keyword.get(opts, :js_error)

        %__MODULE__{
          message: "JS Error: #{js_error}",
          scope: nil,
          function: nil,
          js_error: js_error
        }

      # Simple message
      true ->
        msg = Keyword.get(opts, :message, "unknown error")

        %__MODULE__{
          message: msg,
          scope: nil,
          function: nil,
          js_error: nil
        }
    end
  end

  def exception(msg) when is_binary(msg) do
    %__MODULE__{
      message: msg,
      scope: nil,
      function: nil,
      js_error: nil
    }
  end

  @impl true
  def message(%__MODULE__{message: msg}), do: msg
end
