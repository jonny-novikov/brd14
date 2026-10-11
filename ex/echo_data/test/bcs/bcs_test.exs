defmodule EchoData.BcsTest do
  @moduledoc """
  The EchoData.Bcs row (echo2-migration.md §5): the gate admits one
  namespace and refuses everything else; classification beyond the
  namespace collapses to `:invalid` exactly as `BrandedId.parse/1`
  reports it.
  """
  use ExUnit.Case, async: true

  alias EchoData.{Bcs, BrandedId}

  setup_all do
    :ok = EchoData.Snowflake.start(4)
    :ok
  end

  test "gate/2 admits the declared namespace with the snowflake payload" do
    id = BrandedId.generate!("ORD")
    {:ok, "ORD", snow} = BrandedId.parse(id)

    assert Bcs.gate(id, "ORD") == {:ok, snow}
  end

  test "gate/2 refuses a foreign namespace" do
    id = BrandedId.generate!("USR")
    assert Bcs.gate(id, "ORD") == {:error, :namespace}
  end

  test "gate/2 collapses malformed input to :invalid" do
    assert Bcs.gate("not-a-branded-id", "ORD") == {:error, :invalid}
    assert Bcs.gate("", "ORD") == {:error, :invalid}
  end

  test "gate!/2 returns the bare snowflake on admission" do
    id = BrandedId.generate!("ORD")
    {:ok, "ORD", snow} = BrandedId.parse(id)

    assert Bcs.gate!(id, "ORD") == snow
  end

  test "gate!/2 raises NamespaceError naming both namespaces" do
    id = BrandedId.generate!("USR")

    err =
      assert_raise Bcs.NamespaceError, fn ->
        Bcs.gate!(id, "ORD")
      end

    assert err.message =~ "expected namespace ORD"
    assert err.message =~ "USR"
  end

  test "gate!/2 raises ArgumentError on malformed input" do
    assert_raise ArgumentError, "invalid branded id", fn ->
      Bcs.gate!("junk", "ORD")
    end
  end
end
