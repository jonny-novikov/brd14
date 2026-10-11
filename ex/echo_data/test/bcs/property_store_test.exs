defmodule EchoData.Bcs.PropertyStoreTest do
  @moduledoc """
  The EchoData.Bcs.PropertyStore row (echo2-migration.md §5): a GenServer
  over one private ordered_set, gated at every door. Store names are
  unique per test, so the suite stays async.
  """
  use ExUnit.Case, async: true

  alias EchoData.{Bcs.PropertyStore, BrandedId}

  setup_all do
    :ok = EchoData.Snowflake.start(4)
    :ok
  end

  setup do
    name = :"property_store_#{System.unique_integer([:positive])}"
    {:ok, store} = PropertyStore.start_link(name: name, namespace: "ORD")
    on_exit(fn -> if Process.alive?(store), do: GenServer.stop(store) end)
    %{store: store}
  end

  test "put/3 and get/2 round-trip under the declared namespace", %{store: store} do
    id = BrandedId.generate!("ORD")

    assert PropertyStore.put(store, id, %{qty: 5}) == :ok
    assert PropertyStore.get(store, id) == {:ok, %{qty: 5}}
  end

  test "put/3 and get/2 are gated both ways", %{store: store} do
    foreign = BrandedId.generate!("USR")

    assert PropertyStore.put(store, foreign, %{}) == {:error, :namespace}
    assert PropertyStore.put(store, "junk", %{}) == {:error, :invalid}
    assert PropertyStore.get(store, foreign) == {:error, :namespace}
    assert PropertyStore.get(store, "junk") == {:error, :invalid}
  end

  test "get/2 answers :not_found for an absent admitted id", %{store: store} do
    assert PropertyStore.get(store, BrandedId.generate!("ORD")) == {:error, :not_found}
  end

  test "page_desc/2 walks newest-first", %{store: store} do
    [a, b, c] = mint_ascending(3)
    for id <- [a, b, c], do: :ok = PropertyStore.put(store, id, %{})

    assert PropertyStore.page_desc(store, 2) == {:ok, [c, b]}
    assert PropertyStore.page_desc(store, 10) == {:ok, [c, b, a]}
  end

  test "window/3 answers ascending ids in [lo, hi) with gated bounds", %{store: store} do
    [a, b, c, d] = mint_ascending(4)
    for id <- [a, b, c, d], do: :ok = PropertyStore.put(store, id, %{})

    assert PropertyStore.window(store, a, c) == {:ok, [a, b]}
    assert PropertyStore.window(store, a, d) == {:ok, [a, b, c]}

    foreign = BrandedId.generate!("USR")
    assert PropertyStore.window(store, foreign, c) == {:error, :namespace}
    assert PropertyStore.window(store, a, "junk") == {:error, :invalid}
  end

  test "placement/1 answers the 32-bit placement hash or :invalid" do
    id = BrandedId.generate!("ORD")
    {:ok, _ns, snow} = BrandedId.parse(id)

    assert PropertyStore.placement(id) == {:ok, BrandedId.hash32(snow)}
    assert PropertyStore.placement("junk") == {:error, :invalid}
  end

  test "record_entity/2 admits silently and drops the foreign kind silently", %{store: store} do
    ord = BrandedId.generate!("ORD")
    foreign = BrandedId.generate!("USR")

    PropertyStore.record_entity(store, ord)
    PropertyStore.record_entity(store, foreign)

    # a call serializes behind the casts above
    assert PropertyStore.get(store, ord) == {:ok, true}
    assert PropertyStore.page_desc(store, 10) == {:ok, [ord]}
  end

  defp mint_ascending(n) do
    for _ <- 1..n do
      Process.sleep(2)
      BrandedId.generate!("ORD")
    end
  end
end
