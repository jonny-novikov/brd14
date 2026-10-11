defmodule EchoData.MixProject do
  use Mix.Project

  def project do
    [
      app: :echo_data,
      version: "0.1.0",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
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

  # Run "mix help deps" to learn about dependencies.
  # `stream_data` is test-only (the property-based BrandedChamp namespace-cache
  # suite uses `ExUnitProperties`); it is NOT a runtime dep, so the library stays
  # dependency-free at runtime and Ecto-free everywhere (INV2). Already locked at
  # the umbrella root.
  defp deps do
    [
      {:stream_data, "~> 1.0", only: :test}
    ]
  end
end
