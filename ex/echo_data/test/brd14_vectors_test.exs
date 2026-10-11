defmodule EchoData.Brd14VectorsTest do
  @moduledoc """
  The repository's generated vectors (`vectors/*.tsv`, from `tools/oracle.py`) replayed through
  echo_data. Outside the brd14 repository (an installed package) the files are absent and the
  suite is skipped — unless `BRD14_REQUIRE_VECTORS` is set, which turns absence into a failure.
  """
  use ExUnit.Case, async: true

  import Bitwise, only: [>>>: 2]
  alias EchoData.{BrandedId, Snowflake}

  @dir Path.expand("../../../vectors", __DIR__)
  @present File.dir?(@dir)

  defp rows(name) do
    Path.join(@dir, name)
    |> File.stream!()
    |> Stream.map(&String.trim_trailing(&1, "\n"))
    |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&String.split(&1, "\t"))
  end

  defp unhex("-"), do: ""
  defp unhex(hex), do: Base.decode16!(hex, case: :lower)
  defp class(name), do: name |> String.downcase() |> String.to_existing_atom()

  if @present do
    test "valid.tsv: encode, parse, validate, hash32, unix_ms and fields agree" do
      for [ns, snow, id, hash, unix_ms, ts, node, seq] <- rows("valid.tsv") do
        snow = String.to_integer(snow)
        assert BrandedId.encode(ns, snow) == {:ok, id}
        assert BrandedId.parse(id) == {:ok, ns, snow}
        assert BrandedId.validate(id) == :ok
        assert BrandedId.hash32(snow) == String.to_integer(hash)
        assert Snowflake.unix_ms(snow) == String.to_integer(unix_ms)
        assert snow >>> 22 == String.to_integer(ts)
        assert Snowflake.node_id(snow) == String.to_integer(node)
        assert Snowflake.sequence(snow) == String.to_integer(seq)
      end
    end

    test "invalid.tsv: validate names the contract class, parse refuses" do
      for [id_hex, cls] <- rows("invalid.tsv") do
        id = unhex(id_hex)
        assert BrandedId.validate(id) == {:error, class(cls)}, "id #{inspect(id)}"
        assert BrandedId.parse(id) == :error
      end
    end

    test "encode_invalid.tsv: validate_encode names the class, encode refuses" do
      for [ns_hex, snow, cls] <- rows("encode_invalid.tsv") do
        ns = unhex(ns_hex)
        snow = String.to_integer(snow)
        assert BrandedId.validate_encode(ns, snow) == {:error, class(cls)}
        assert BrandedId.encode(ns, snow) == :error
      end
    end

    test "node.tsv: node_from is the contract's FNV derivation" do
      for [host_hex, pid, node] <- rows("node.tsv") do
        assert Snowflake.node_from(unhex(host_hex), String.to_integer(pid)) ==
                 String.to_integer(node)
      end
    end
  else
    if System.get_env("BRD14_REQUIRE_VECTORS") do
      test "vectors/ is required" do
        flunk("vectors/ absent at #{@dir} but BRD14_REQUIRE_VECTORS is set")
      end
    end
  end
end
