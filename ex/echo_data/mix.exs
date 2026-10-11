defmodule EchoData.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/jonny-novikov/brd14"

  # Standalone: no umbrella build/config/deps paths. The library is pure Elixir
  # at runtime; `EchoData.Native` loads an optional NIF from priv/ when present
  # and falls back to pure Elixir otherwise.
  def project do
    [
      app: :echo_data,
      version: @version,
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      test_coverage: [summary: [threshold: 0]]
    ]
  end

  # The boot module starts the lock-free Snowflake generator and runs
  # `BrandedId.self_check!/0` (logging the codec mode). Ecto-free by design —
  # any Ecto type that wraps a branded id lives in the consuming app, not here;
  # the dependency arrow points one way (INV2).
  def application do
    [
      extra_applications: [:logger],
      mod: {EchoData.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # `stream_data` is test-only (property suites use `ExUnitProperties`); the
  # library stays dependency-free at runtime.
  defp deps do
    [
      {:stream_data, "~> 1.0", only: :test}
    ]
  end

  defp description do
    "Branded identity (brd14: 3-letter namespace ++ base62 snowflake, 14 bytes) and the " <>
      "persistent structures built on it: BrandedChamp, BrandedMap, BrandedTree, Buckets."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib priv/census.vectors mix.exs README.md LICENSE .formatter.exs)
    ]
  end
end
