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
      compilers: Mix.compilers() ++ [:echo_data_nif],
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
      files: ~w(lib priv/census.vectors native/echo_data_nif/src native/echo_data_nif/Cargo.toml
                native/vendor mix.exs README.md LICENSE .formatter.exs)
    ]
  end
end

defmodule Mix.Tasks.Compile.EchoDataNif do
  @moduledoc """
  Builds the optional NIF (native/echo_data_nif, Rustler) into priv/echo_data_nif.so.

  `ECHO_DATA_NIF=0` skips it; `ECHO_DATA_NIF=1` makes a missing cargo or a failed build an
  error. Otherwise (the default) the build is best effort: without cargo, or when it fails,
  the library compiles and runs on its pure Elixir fallback, and says so.
  """
  use Mix.Task.Compiler

  @crate Path.expand("native/echo_data_nif", __DIR__)
  @priv Path.expand("priv", __DIR__)

  @impl true
  def run(_args) do
    mode = System.get_env("ECHO_DATA_NIF")

    cond do
      mode == "0" or not File.exists?(Path.join(@crate, "Cargo.toml")) ->
        {:noop, []}

      System.find_executable("cargo") == nil ->
        fail(mode, "cargo not found")

      true ->
        build(mode)
    end
  end

  defp build(mode) do
    args = ["build", "--release", "--quiet", "--manifest-path", Path.join(@crate, "Cargo.toml")]

    case System.cmd("cargo", args, stderr_to_stdout: true) do
      {_, 0} ->
        install(Path.join([@crate, "target", "release", lib_name()]))

      {out, status} ->
        fail(mode, "cargo build exited #{status}:\n" <> out)
    end
  end

  defp install(built) do
    target = Path.join(@priv, "echo_data_nif.so")
    File.mkdir_p!(@priv)

    if File.exists?(target) and File.read!(target) == File.read!(built) do
      {:noop, []}
    else
      File.cp!(built, target)
      {:ok, []}
    end
  end

  defp lib_name do
    case :os.type() do
      {:unix, :darwin} -> "libecho_data_nif.dylib"
      {:win32, _} -> "echo_data_nif.dll"
      _ -> "libecho_data_nif.so"
    end
  end

  defp fail("1", why), do: Mix.raise("echo_data: the NIF is required (ECHO_DATA_NIF=1) — " <> why)

  defp fail(_mode, why) do
    Mix.shell().info("echo_data: NIF not built (" <> why <> "); using the pure Elixir fallback")
    {:noop, []}
  end
end
