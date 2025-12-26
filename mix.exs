defmodule MquickjsEx.MixProject do
  use Mix.Project

  def project do
    [
      app: :mquickjs_ex,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.8", runtime: false},
      {:jason, "~> 1.4"}
    ]
  end
end
