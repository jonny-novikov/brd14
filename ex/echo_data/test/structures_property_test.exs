defmodule EchoData.StructuresPropertyTest do
  @moduledoc """
  The branded structures against plain models (docs/structures/spec.md): BrandedTree vs a sorted
  list, Buckets vs filtering by bucket, BrandedChamp vs a map — plus persistence (an old version
  never changes) and loud writes / quiet reads for invalid ids.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Bitwise

  alias EchoData.{BrandedChamp, BrandedId, BrandedTree, Buckets}

  @epoch 1_704_067_200_000
  @t0 1_769_526_697_641
  @span 200

  # Snowflakes minted within a 200 ms window, any node and sequence — with a quarter of them
  # on a millisecond boundary (node 0, seq 0), the only place a half-open bound is observable.
  defp snow do
    map(
      tuple({integer(0..@span), frequency([{1, constant(0)}, {3, integer(0..0x3FFFFF)}])}),
      fn {dt, low} -> (@t0 - @epoch + dt) <<< 22 ||| low end
    )
  end

  defp ns, do: member_of(["AAA", "BBB", "ORD"])
  defp op, do: tuple({member_of([:put, :put, :put, :delete]), ns(), snow(), integer()})
  defp dt(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp min_for(ms), do: (ms - @epoch) <<< 22

  defp model_apply(ops) do
    Enum.reduce(ops, %{}, fn
      {:put, ns, s, v}, m -> Map.put(m, {ns, s}, v)
      {:delete, ns, s, _}, m -> Map.delete(m, {ns, s})
    end)
  end

  defp sorted(model, ns), do: for({{^ns, s}, v} <- Enum.sort(model), do: {s, v})
  defp ids(pairs, ns), do: for({s, v} <- pairs, do: {BrandedId.encode!(ns, s), v})

  describe "BrandedTree" do
    property "first, last, to_list, page_after and between agree with a sorted list" do
      check all(
              ops <- list_of(op(), max_length: 120),
              n <- integer(1..10),
              cut <- integer(0..@span),
              width <- integer(0..@span)
            ) do
        tree =
          Enum.reduce(ops, BrandedTree.new(), fn
            {:put, ns, s, v}, t -> BrandedTree.put(t, BrandedId.encode!(ns, s), v)
            {:delete, ns, s, _}, t -> BrandedTree.delete(t, BrandedId.encode!(ns, s))
          end)

        model = model_apply(ops)
        assert BrandedTree.size(tree) == map_size(model)

        for ns <- ["AAA", "BBB", "ORD"] do
          want = sorted(model, ns)
          assert BrandedTree.to_list(tree, ns) == ids(want, ns)

          case want do
            [] ->
              assert BrandedTree.first(tree, ns) == :error
              assert BrandedTree.last(tree, ns) == :error

            [{s0, v0} | _] ->
              {sl, vl} = List.last(want)
              assert BrandedTree.first(tree, ns) == {:ok, BrandedId.encode!(ns, s0), v0}
              assert BrandedTree.last(tree, ns) == {:ok, BrandedId.encode!(ns, sl), vl}
          end

          # page_after: strictly after the cursor's snowflake, at most n, ascending.
          assert BrandedTree.page_after(tree, ns, nil, n) == ids(Enum.take(want, n), ns)

          for {s, _} <- Enum.take(want, 3) do
            cursor = BrandedId.encode!(ns, s)
            after_ = Enum.filter(want, fn {x, _} -> x > s end) |> Enum.take(n)
            assert BrandedTree.page_after(tree, ns, cursor, n) == ids(after_, ns)
          end

          # between: min_for(from) <= snow < min_for(until), half-open.
          from = @t0 + cut
          until = from + width
          window = Enum.filter(want, fn {x, _} -> x >= min_for(from) and x < min_for(until) end)
          assert BrandedTree.between(tree, ns, dt(from), dt(until)) == ids(window, ns)
        end
      end
    end

    test "an invalid id is refused on put and absent on fetch" do
      assert_raise ArgumentError, fn ->
        BrandedTree.put(BrandedTree.new(), "usr0KHTOWnGLuC", 1)
      end

      assert BrandedTree.fetch(BrandedTree.new(), "USRzzzzzzzzzzz") == :error
    end
  end

  describe "Buckets" do
    property "expire_older_than drops exactly the buckets older than the cutoff's bucket" do
      check all(
              ops <- list_of(op(), max_length: 150),
              bits <- integer(4..14),
              cut <- integer(0..@span)
            ) do
        b =
          Enum.reduce(ops, Buckets.new(bucket_bits: bits), fn
            {:put, _ns, s, v}, acc -> Buckets.put_by_snowflake(acc, s, v)
            {:delete, _ns, s, _}, acc -> Buckets.delete_by_snowflake(acc, s)
          end)

        # Buckets key by snowflake alone: the model drops the namespace too.
        model =
          Enum.reduce(ops, %{}, fn
            {:put, _, s, v}, m -> Map.put(m, s, v)
            {:delete, _, s, _}, m -> Map.delete(m, s)
          end)

        assert Buckets.size(b) == map_size(model)

        assert Buckets.bucket_count(b) ==
                 model |> Map.keys() |> Enum.map(&(&1 >>> (22 + bits))) |> Enum.uniq() |> length()

        cutoff_key = min_for(@t0 + cut) >>> (22 + bits)
        {gone, kept} = Enum.split_with(model, fn {s, _} -> s >>> (22 + bits) < cutoff_key end)
        {expired, b2} = Buckets.expire_older_than(b, dt(@t0 + cut))

        assert expired == length(gone)
        assert Buckets.size(b2) == length(kept)
        for {s, v} <- kept, do: assert(Buckets.fetch_by_snowflake(b2, s) == {:ok, v})
        for {s, _} <- gone, do: assert(Buckets.fetch_by_snowflake(b2, s) == :error)
        # Persistent: the old version still holds everything.
        for {s, v} <- model, do: assert(Buckets.fetch_by_snowflake(b, s) == {:ok, v})
      end
    end
  end

  describe "BrandedChamp" do
    property "agrees with a map, and every old version is unchanged" do
      check all(ops <- list_of(op(), max_length: 150)) do
        {final, versions} =
          Enum.reduce(ops, {BrandedChamp.new(), []}, fn op, {c, vs} ->
            next =
              case op do
                {:put, ns, s, v} -> BrandedChamp.put!(c, BrandedId.encode!(ns, s), v)
                {:delete, ns, s, _} -> BrandedChamp.delete(c, BrandedId.encode!(ns, s))
              end

            {next, [{c, BrandedChamp.to_list(c)} | vs]}
          end)

        model = model_apply(ops)
        assert BrandedChamp.size(final) == map_size(model)

        assert Enum.sort(BrandedChamp.to_snowflake_list(final)) ==
                 Enum.sort(for {{ns, s}, v} <- model, do: {ns, s, v})

        for {old, snapshot} <- versions do
          assert BrandedChamp.to_list(old) == snapshot
        end
      end
    end

    test "an invalid id is refused on put! and absent on fetch" do
      assert_raise ArgumentError, fn ->
        BrandedChamp.put!(BrandedChamp.new(), "USR0KHTOWnGLu!", 1)
      end

      assert BrandedChamp.fetch(BrandedChamp.new(), "USRzzzzzzzzzzz") == :error
    end
  end
end
