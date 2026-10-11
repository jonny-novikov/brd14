defmodule EchoData.Native do
  @moduledoc """
  Optional NIF (Rustler, `native/echo_data_nif`) over the repository's Rust crates: the brd14
  codec and hash from `brd14`, and the persistent branded champ from `brd14-data`
  (`EchoData.NativeChamp` is its Elixir face). When the shared object is absent every codec call
  falls back to the pure Elixir implementations, so the library works without the native build
  and accelerates where it is present.

  `loaded?/0` reports the active path; `EchoData.BrandedId.self_check!/0` asserts at boot that
  both paths agree on the contract vectors. Setting `ECHO_DATA_NATIVE=0` skips loading and forces
  the pure path.
  """
  @on_load :load

  def load do
    if System.get_env("ECHO_DATA_NATIVE") == "0" do
      # Forced pure (the parity shim ex-pure, and comparisons against the NIF).
      :persistent_term.put({__MODULE__, :loaded}, false)
    else
      load_nif()
    end

    :ok
  end

  defp load_nif do
    path =
      case :code.priv_dir(:echo_data) do
        {:error, _} -> "priv/echo_data_nif"
        dir -> Path.join(dir, "echo_data_nif")
      end

    result = :erlang.load_nif(String.to_charlist(path), 0)
    :persistent_term.put({__MODULE__, :loaded}, result == :ok)
  end

  def loaded?, do: :persistent_term.get({__MODULE__, :loaded}, false)

  # codec — the API of the C shim this replaces
  def decode(_id), do: :erlang.nif_error(:not_loaded)
  def decode_hash(_id), do: :erlang.nif_error(:not_loaded)
  def encode(_ns, _snow), do: :erlang.nif_error(:not_loaded)
  def hash32(_snow), do: :erlang.nif_error(:not_loaded)

  # champ — see EchoData.NativeChamp
  def champ_new, do: :erlang.nif_error(:not_loaded)
  def champ_put(_c, _id, _value), do: :erlang.nif_error(:not_loaded)
  def champ_put_snow(_c, _ns, _snow, _value), do: :erlang.nif_error(:not_loaded)
  def champ_get(_c, _id), do: :erlang.nif_error(:not_loaded)
  def champ_get_snow(_c, _ns, _snow), do: :erlang.nif_error(:not_loaded)
  def champ_delete(_c, _id), do: :erlang.nif_error(:not_loaded)
  def champ_delete_snow(_c, _ns, _snow), do: :erlang.nif_error(:not_loaded)
  def champ_size(_c), do: :erlang.nif_error(:not_loaded)
  def champ_namespace_size(_c, _ns), do: :erlang.nif_error(:not_loaded)
  def champ_namespaces(_c), do: :erlang.nif_error(:not_loaded)
  def champ_digest(_c, _ns), do: :erlang.nif_error(:not_loaded)
  def champ_to_list(_c), do: :erlang.nif_error(:not_loaded)
  def champ_from_list(_entries), do: :erlang.nif_error(:not_loaded)
end
