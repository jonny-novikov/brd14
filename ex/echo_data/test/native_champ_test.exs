defmodule EchoData.NativeChampTest do
  @moduledoc """
  The Rust champ behind the NIF against the oracle's vectors and against `BrandedChamp`:
  same digests, same iteration order, value semantics, any term in and out.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise, only: [<<<: 2]

  @moduletag :nif

  alias EchoData.{BrandedChamp, BrandedId, ChampNode, NativeChamp}
  alias EchoData.Test.ChampVectors

  @ns "AAA"

  if ChampVectors.present?() do
    test "every champ.tsv row: size, digest and read-back through the NIF" do
      for row <- ChampVectors.rows() do
        {c, model} =
          row.program
          |> Enum.with_index()
          |> Enum.reduce({NativeChamp.new(), %{}}, fn
            {{:put, k}, i}, {c, m} ->
              {NativeChamp.put_by_snowflake(c, @ns, k, i), Map.put(m, k, i)}

            {{:delete, k}, _}, {c, m} ->
              {NativeChamp.delete_by_snowflake(c, @ns, k), Map.delete(m, k)}
          end)

        assert NativeChamp.size(c) == row.size, row.case
        hex = NativeChamp.shape_digest(c, @ns) |> Integer.to_string(16) |> String.downcase()
        assert String.pad_leading(hex, 16, "0") == row.digest, row.case

        for k <- row.keys do
          assert NativeChamp.fetch_by_snowflake(c, @ns, k) == Map.fetch(model, k), row.case
        end
      end
    end
  end

  property "iteration order equals ChampNode's for the same operations" do
    check all(
            ops <-
              list_of(tuple({member_of([:put, :put, :delete]), integer(0..0x7FFFFFFFFFFFFFFF)}),
                max_length: 200
              )
          ) do
      {native, pure} =
        Enum.reduce(ops, {NativeChamp.new(), BrandedChamp.new()}, fn
          {:put, s}, {n, p} ->
            {NativeChamp.put_by_snowflake(n, @ns, s, s),
             BrandedChamp.put_by_snowflake(p, @ns, s, s)}

          {:delete, s}, {n, p} ->
            {NativeChamp.delete_by_snowflake(n, @ns, s),
             BrandedChamp.delete_by_snowflake(p, @ns, s)}
        end)

      root = Map.get(pure.namespaces, @ns, ChampNode.new())

      assert for({_ns, s, v} <- NativeChamp.to_snowflake_list(native), do: {s, v}) ==
               ChampNode.to_list(root)
    end
  end

  test "value semantics: an old version never changes" do
    ids = for s <- 1..500, do: BrandedId.encode!("ORD", s * 7919)
    v1 = NativeChamp.new(for id <- ids, do: {id, :one})
    v2 = Enum.reduce(Enum.take(ids, 250), v1, &NativeChamp.delete(&2, &1))
    v3 = NativeChamp.put!(v2, hd(ids), :again)

    assert NativeChamp.size(v1) == 500 and NativeChamp.size(v2) == 250 and
             NativeChamp.size(v3) == 251

    assert Enum.all?(ids, &(NativeChamp.fetch(v1, &1) == {:ok, :one}))
    assert NativeChamp.fetch(v2, hd(ids)) == :error
    assert NativeChamp.fetch(v3, hd(ids)) == {:ok, :again}
  end

  test "any term goes in, an equal term comes out — also from another process" do
    terms = [
      %{a: [1, 2.5, "x"]},
      {:tuple, self(), make_ref()},
      <<0, 255>>,
      1 <<< 100,
      -3,
      nil,
      fn -> :f end
    ]

    c =
      Enum.reduce(Enum.with_index(terms, 1), NativeChamp.new(), fn {t, i}, c ->
        NativeChamp.put_by_snowflake(c, "TRM", i, t)
      end)

    for {t, i} <- Enum.with_index(terms, 1),
        do: assert(NativeChamp.fetch_by_snowflake(c, "TRM", i) == {:ok, t})

    parent = self()

    spawn(fn ->
      send(parent, {:got, NativeChamp.fetch_by_snowflake(c, "TRM", 1), NativeChamp.size(c)})
    end)

    assert_receive {:got, {:ok, %{a: [1, 2.5, "x"]}}, 7}
  end

  test "writes are loud, reads are quiet, namespaces are counted" do
    c = NativeChamp.new([{"USR0KHTOWnGLuC", 1}, {"ORD0KHTOWnGLuC", 2}])
    assert NativeChamp.namespaces(c) == ["ORD", "USR"]
    assert NativeChamp.namespace_size(c, "USR") == 1 and NativeChamp.namespace_size(c, "ZZZ") == 0
    assert_raise ArgumentError, ~r/namespace/, fn -> NativeChamp.put!(c, "usr0KHTOWnGLuC", 1) end
    assert_raise ArgumentError, ~r/range/, fn -> NativeChamp.put!(c, "USRzzzzzzzzzzz", 1) end
    assert_raise ArgumentError, ~r/length/, fn -> NativeChamp.delete(c, "USR") end
    assert NativeChamp.fetch(c, "USR0KHTOWnGLu!") == :error
    assert NativeChamp.fetch(c, :not_an_id) == :error
    assert Enum.count(c) == 2
  end

  test "from_champ copies a BrandedChamp off-heap with the same digest" do
    pure =
      Enum.reduce(
        1..2000,
        BrandedChamp.new(),
        &BrandedChamp.put_by_snowflake(&2, "SES", &1 * 104_729, &1)
      )

    native = NativeChamp.from_champ(BrandedChamp.to_snowflake_list(pure))
    assert NativeChamp.size(native) == 2000

    assert NativeChamp.shape_digest(native, "SES")
           |> Integer.to_string(16)
           |> String.downcase()
           |> String.pad_leading(16, "0") ==
             ChampVectors.digest(pure.namespaces["SES"])
  end
end
