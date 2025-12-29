defmodule MquickjsEx.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/Valian/mquickjs_ex"

  def project do
    [
      app: :mquickjs_ex,
      version: @version,
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "MquickjsEx",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp description do
    "Embed MQuickJS JavaScript engine in Elixir via NIFs. No Node.js required."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url
      },
      files: ~w(lib c_src .formatter.exs mix.exs README.md LICENSE Makefile),
      exclude_patterns: ~w(c_src/*.h c_src/mquickjs_ex_stdlib_gen)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.8", runtime: false},
      {:jason, "~> 1.4"},
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end
end
