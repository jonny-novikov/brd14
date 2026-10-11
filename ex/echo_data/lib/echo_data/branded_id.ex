defmodule EchoData.BrandedId do
  @moduledoc """
  The branded ID contract: `3 x [A-Z]` namespace ++ `base62(snowflake)` padded
  to 11 — 14 bytes, fixed. One module owns the codec and the hash; everything
  else (tries, maps, the persistence type, the web layer) calls through here. When the NIF is
  present (`EchoData.Native.loaded?/0`) the native core serves these calls;
  otherwise the pure implementations do, with identical results — asserted by
  `self_check!/0`.

      iex> EchoData.BrandedId.encode!("USR", 274557032793636864)
      "USR0KHTOWnGLuC"
      iex> EchoData.BrandedId.parse("USR0KHTOWnGLuC")
      {:ok, "USR", 274557032793636864}
      iex> EchoData.BrandedId.hash32(274557032793636864)
      234878118
  """

  import Bitwise
  alias EchoData.{Base62, Native}

  @type t :: <<_::112>>

  defguard is_branded(id) when is_binary(id) and byte_size(id) == 14

  @doc "Parses a branded ID into `{:ok, namespace, snowflake}` or `:error`."
  @spec parse(binary()) :: {:ok, binary(), non_neg_integer()} | :error
  def parse(id) when is_branded(id) do
    if Native.loaded?() do
      case Native.decode(id) do
        {ns, snow} -> {:ok, ns, snow}
        :error -> :error
      end
    else
      pure_parse(id)
    end
  end

  def parse(_), do: :error

  @doc "Parses and hashes in one step: `{:ok, ns, snowflake, hash32}` or `:error`."
  def parse_hash(id) when is_branded(id) do
    if Native.loaded?() do
      case Native.decode_hash(id) do
        {ns, snow, hash} -> {:ok, ns, snow, hash}
        :error -> :error
      end
    else
      with {:ok, ns, snow} <- pure_parse(id), do: {:ok, ns, snow, pure_hash32(snow)}
    end
  end

  def parse_hash(_), do: :error

  @spec decode(binary()) :: {:ok, non_neg_integer()} | :error
  def decode(id) do
    with {:ok, _ns, snow} <- parse(id), do: {:ok, snow}
  end

  def decode!(id) do
    case decode(id) do
      {:ok, snow} -> snow
      :error -> raise ArgumentError, "invalid branded id: #{inspect(id)}"
    end
  end

  @spec encode(binary(), non_neg_integer()) :: {:ok, t()} | :error
  def encode(<<_::binary-size(3)>> = ns, snow)
      when is_integer(snow) and snow >= 0 and snow <= 9_223_372_036_854_775_807 do
    if valid_ns?(ns) do
      if Native.loaded?() do
        case Native.encode(ns, snow) do
          id when is_binary(id) -> {:ok, id}
          :error -> :error
        end
      else
        {:ok, ns <> Base62.encode(snow)}
      end
    else
      :error
    end
  end

  def encode(_, _), do: :error

  def encode!(ns, snow) do
    case encode(ns, snow) do
      {:ok, id} -> id
      :error -> raise ArgumentError, "invalid namespace or snowflake: #{inspect({ns, snow})}"
    end
  end

  @doc "Mints a fresh branded ID in the namespace (requires `EchoData.Snowflake.start/1`)."
  def generate!(ns), do: encode!(ns, EchoData.Snowflake.next())

  def valid?(id), do: parse(id) != :error

  def namespace(id) when is_branded(id), do: binary_part(id, 0, 3)

  def unix_ms(id) do
    with {:ok, snow} <- decode(id), do: {:ok, EchoData.Snowflake.unix_ms(snow)}
  end

  @doc """
  The trie hash: the first half of MurmurHash3's fmix64, truncated to 32 bits.
  Single source — `ChampNode` and every other consumer call here.
  Contract vector: `hash32(274557032793636864) == 234878118`.
  """
  @spec hash32(non_neg_integer()) :: non_neg_integer()
  def hash32(snow) when is_integer(snow) and snow >= 0 do
    if Native.loaded?(), do: Native.hash32(snow), else: pure_hash32(snow)
  end

  @doc "Asserts native and pure paths agree on the contract vectors. Call at boot."
  def self_check! do
    ref = 274_557_032_793_636_864

    checks = [
      {pure_hash32(ref), 234_878_118},
      {"USR" <> Base62.encode(ref), "USR0KHTOWnGLuC"},
      {pure_parse("USR0NgWEfAEJfs"), {:ok, "USR", 320_636_799_581_945_856}},
      {Base62.decode("zzzzzzzzzzz"), :error}
    ]

    native_checks =
      if Native.loaded?() do
        [
          {Native.hash32(ref), 234_878_118},
          {Native.encode("USR", ref), "USR0KHTOWnGLuC"},
          {Native.decode("USR0NgWEfAEJfs"), {"USR", 320_636_799_581_945_856}},
          {Native.decode("USRzzzzzzzzzzz"), :error}
        ]
      else
        []
      end

    for {got, want} <- checks ++ native_checks, got != want do
      raise "branded contract self-check failed: got #{inspect(got)}, want #{inspect(want)}"
    end

    {:ok, if(Native.loaded?(), do: :native, else: :pure)}
  end

  defp valid_ns?(<<a, b, c>>), do: a in ?A..?Z and b in ?A..?Z and c in ?A..?Z

  defp pure_parse(<<ns::binary-size(3), payload::binary-size(11)>>) do
    with true <- valid_ns?(ns),
         {:ok, snow} <- Base62.decode(payload) do
      {:ok, ns, snow}
    else
      _ -> :error
    end
  end

  defp pure_hash32(snow) do
    h = band(snow, 0xFFFFFFFFFFFFFFFF)
    h = bxor(h, h >>> 33)
    h = band(h * 0xFF51AFD7ED558CCD, 0xFFFFFFFFFFFFFFFF)
    h = bxor(h, h >>> 33)
    band(h, 0xFFFFFFFF)
  end
end

defmodule EchoData.BrandedId.Sigil do
  @moduledoc """
  Compile-time validated branded literals: `import EchoData.BrandedId.Sigil`,
  then `~b"USR0KHTOWnGLuC"` — an invalid literal fails the build, not the request.
  """

  defmacro sigil_b({:<<>>, _, [str]}, _mods) when is_binary(str) do
    case EchoData.BrandedId.parse(str) do
      {:ok, _, _} -> str
      :error -> raise CompileError, description: "invalid branded id literal: " <> inspect(str)
    end
  end
end
