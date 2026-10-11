defmodule EchoData.Bcs.ArchetypesTest do
  @moduledoc """
  The EchoData.Bcs.Archetypes row (echo2-migration.md §5): the pure
  resolver — right-most-wins compose with `:extends` stripped, the
  root-first chain through a fetch function, the cycle and the
  8-bundle-depth refusals, and fetch error propagation.
  """
  use ExUnit.Case, async: true

  alias EchoData.{Bcs.Archetypes, BrandedId}

  setup_all do
    :ok = EchoData.Snowflake.start(4)
    :ok
  end

  test "compose/2 merges right-most-wins with overrides last and strips :extends" do
    chain = [%{a: 1, b: 1, extends: "parent"}, %{b: 2, c: 2}]

    assert Archetypes.compose(chain, %{c: 3}) == %{a: 1, b: 2, c: 3}
  end

  test "resolve/3 walks the :extends chain root-first and applies overrides last" do
    base = BrandedId.generate!("ARC")
    child = BrandedId.generate!("ARC")

    defs = %{
      base => %{venue: :otc, fee: 10},
      child => %{extends: base, fee: 7, tier: :gold}
    }

    fetch = fn id -> Map.fetch(defs, id) |> case do
      {:ok, props} -> {:ok, props}
      :error -> {:error, :missing}
    end end

    assert Archetypes.resolve(fetch, child) == {:ok, %{venue: :otc, fee: 7, tier: :gold}}
    assert Archetypes.resolve(fetch, child, %{fee: 1}) == {:ok, %{venue: :otc, fee: 1, tier: :gold}}
  end

  test "resolve/3 refuses a cycle" do
    a = BrandedId.generate!("ARC")
    b = BrandedId.generate!("ARC")

    defs = %{a => %{extends: b}, b => %{extends: a}}
    fetch = fn id -> {:ok, Map.fetch!(defs, id)} end

    assert Archetypes.resolve(fetch, a) == {:error, :cycle}
  end

  test "resolve/3 holds an eight-bundle chain and refuses the ninth" do
    fetch = fn defs -> fn id -> {:ok, Map.fetch!(defs, id)} end end

    eight = chain_of(8)
    assert {:ok, composed} = Archetypes.resolve(fetch.(eight.defs), eight.head)
    assert composed.depth == 1
    refute Map.has_key?(composed, :extends)

    nine = chain_of(9)
    assert Archetypes.resolve(fetch.(nine.defs), nine.head) == {:error, :depth}
  end

  test "resolve/3 propagates the fetch error" do
    fetch = fn _id -> {:error, :missing} end
    assert Archetypes.resolve(fetch, BrandedId.generate!("ARC")) == {:error, :missing}
  end

  defp chain_of(n) do
    ids = for _ <- 1..n, do: BrandedId.generate!("ARC")

    defs =
      ids
      |> Enum.with_index(1)
      |> Enum.zip(tl(ids) ++ [nil])
      |> Map.new(fn {{id, depth}, parent} ->
        props = %{depth: depth}
        props = if parent, do: Map.put(props, :extends, parent), else: props
        {id, props}
      end)

    %{head: hd(ids), defs: defs}
  end
end
