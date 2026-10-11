defmodule EchoData.Native do
  @moduledoc """
  Optional NIF acceleration for the branded contract (codec + hash), backed by
  the Rust core through the C shim in `native/`. When the shared object is
  absent every call falls back to the pure Elixir implementations, so the
  library works without the native build and accelerates where it is present.

  `loaded?/0` reports the active path; `EchoData.BrandedId.self_check!/0`
  asserts at boot that both paths agree on the contract vectors.
  """
  @on_load :load

  def load do
    path =
      case :code.priv_dir(:echo_data) do
        {:error, _} -> "priv/echo_native"
        dir -> Path.join(dir, "echo_native")
      end

    result = :erlang.load_nif(String.to_charlist(path), 0)
    :persistent_term.put({__MODULE__, :loaded}, result == :ok)
    :ok
  end

  def loaded?, do: :persistent_term.get({__MODULE__, :loaded}, false)

  def decode(_id), do: :erlang.nif_error(:not_loaded)
  def decode_hash(_id), do: :erlang.nif_error(:not_loaded)
  def encode(_ns, _snow), do: :erlang.nif_error(:not_loaded)
  def hash32(_snow), do: :erlang.nif_error(:not_loaded)
end
