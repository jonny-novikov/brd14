defmodule EchoData.Bcs.EdgeStoreTest do
  @moduledoc """
  The EchoData.Bcs.EdgeStore row (echo2-migration.md §5): one kind of
  edge, both ends gated, forward and reverse traversal ascending with an
  optional limit. Store names are unique per test, so the suite stays
  async.
  """
  use ExUnit.Case, async: true

  alias EchoData.{Bcs.EdgeStore, BrandedId}

  setup_all do
    :ok = EchoData.Snowflake.start(4)
    :ok
  end

  setup do
    name = :"edge_store_#{System.unique_integer([:positive])}"

    {:ok, store} =
      EdgeStore.start_link(name: name, relation: :holds, subject_ns: "PRT", object_ns: "AST")

    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    %{store: store}
  end

  test "link/4, props/3, degree/2, and unlink/3 round-trip one edge", %{store: store} do
    prt = BrandedId.generate!("PRT")
    ast = BrandedId.generate!("AST")

    assert EdgeStore.link(store, prt, ast, %{qty: 100}) == :ok
    assert EdgeStore.props(store, prt, ast) == {:ok, %{qty: 100}}
    assert EdgeStore.degree(store, prt) == {:ok, 1}

    assert EdgeStore.unlink(store, prt, ast) == :ok
    assert EdgeStore.props(store, prt, ast) == {:error, :not_found}
    assert EdgeStore.degree(store, prt) == {:ok, 0}
  end

  test "both ends are gated on every verb", %{store: store} do
    prt = BrandedId.generate!("PRT")
    ast = BrandedId.generate!("AST")
    foreign = BrandedId.generate!("USR")

    assert EdgeStore.link(store, foreign, ast, %{}) == {:error, :namespace}
    assert EdgeStore.link(store, prt, foreign, %{}) == {:error, :namespace}
    assert EdgeStore.link(store, "junk", ast, %{}) == {:error, :invalid}

    assert EdgeStore.unlink(store, foreign, ast) == {:error, :namespace}
    assert EdgeStore.props(store, prt, "junk") == {:error, :invalid}
    assert EdgeStore.from(store, foreign) == {:error, :namespace}
    assert EdgeStore.to(store, foreign) == {:error, :namespace}
    assert EdgeStore.degree(store, "junk") == {:error, :invalid}
  end

  test "unlink/3 and props/3 answer :not_found for an absent edge", %{store: store} do
    prt = BrandedId.generate!("PRT")
    ast = BrandedId.generate!("AST")

    assert EdgeStore.unlink(store, prt, ast) == {:error, :not_found}
    assert EdgeStore.props(store, prt, ast) == {:error, :not_found}
  end

  test "from/3 traverses forward ascending with an optional limit", %{store: store} do
    prt = BrandedId.generate!("PRT")
    [a1, a2, a3] = mint_ascending("AST", 3)

    for {ast, i} <- Enum.with_index([a1, a2, a3], 1) do
      :ok = EdgeStore.link(store, prt, ast, %{n: i})
    end

    assert EdgeStore.from(store, prt) == {:ok, [{a1, %{n: 1}}, {a2, %{n: 2}}, {a3, %{n: 3}}]}
    assert EdgeStore.from(store, prt, 2) == {:ok, [{a1, %{n: 1}}, {a2, %{n: 2}}]}
  end

  test "to/3 traverses reverse ascending with an optional limit", %{store: store} do
    ast = BrandedId.generate!("AST")
    [p1, p2, p3] = mint_ascending("PRT", 3)

    for prt <- [p1, p2, p3], do: :ok = EdgeStore.link(store, prt, ast, %{})

    assert EdgeStore.to(store, ast) == {:ok, [{p1, %{}}, {p2, %{}}, {p3, %{}}]}
    assert EdgeStore.to(store, ast, 2) == {:ok, [{p1, %{}}, {p2, %{}}]}
  end

  test "link/4 updates the props of an existing edge", %{store: store} do
    prt = BrandedId.generate!("PRT")
    ast = BrandedId.generate!("AST")

    :ok = EdgeStore.link(store, prt, ast, %{qty: 1})
    :ok = EdgeStore.link(store, prt, ast, %{qty: 2})

    assert EdgeStore.props(store, prt, ast) == {:ok, %{qty: 2}}
    assert EdgeStore.degree(store, prt) == {:ok, 1}
  end

  defp mint_ascending(ns, n) do
    for _ <- 1..n do
      Process.sleep(2)
      BrandedId.generate!(ns)
    end
  end
end
