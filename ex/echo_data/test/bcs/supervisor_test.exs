defmodule EchoData.Bcs.SupervisorTest do
  @moduledoc """
  The EchoData.Bcs.Supervisor row (echo2-migration.md §5): named
  PropertyStores from `{name, ns}` pairs under `:one_for_one`. The
  supervisor and its children carry fixed names — the suite is
  `async: false` (the hazards bank).
  """
  use ExUnit.Case, async: false

  alias EchoData.{Bcs.PropertyStore, Bcs.Supervisor, BrandedId}

  setup_all do
    :ok = EchoData.Snowflake.start(4)
    :ok
  end

  setup do
    {:ok, sup} =
      Supervisor.start_link([{:emq0_store_orders, "ORD"}, {:emq0_store_users, "USR"}])

    # the supervisor traps exits and follows the dying test process down —
    # the stop below races that shutdown, so an already-dead exit is fine
    on_exit(fn ->
      try do
        Elixir.Supervisor.stop(sup)
      catch
        :exit, _ -> :ok
      end
    end)

    %{sup: sup}
  end

  test "named stores start from the {name, ns} pairs and gate per namespace" do
    assert is_pid(Process.whereis(:emq0_store_orders))
    assert is_pid(Process.whereis(:emq0_store_users))

    ord = BrandedId.generate!("ORD")
    assert PropertyStore.put(:emq0_store_orders, ord, %{}) == :ok
    assert PropertyStore.put(:emq0_store_users, ord, %{}) == {:error, :namespace}
  end

  test "a killed child restarts under :one_for_one, leaving the sibling untouched" do
    orders = Process.whereis(:emq0_store_orders)
    users = Process.whereis(:emq0_store_users)

    ref = Process.monitor(orders)
    Process.exit(orders, :kill)
    assert_receive {:DOWN, ^ref, :process, ^orders, :killed}, 1_000

    wait_until(fn ->
      pid = Process.whereis(:emq0_store_orders)
      is_pid(pid) and pid != orders
    end)

    assert Process.whereis(:emq0_store_users) == users

    ord = BrandedId.generate!("ORD")
    assert PropertyStore.put(:emq0_store_orders, ord, %{}) == :ok
  end

  defp wait_until(pred, tries \\ 200) do
    cond do
      pred.() -> :ok
      tries == 0 -> flunk("condition never held")
      true ->
        Process.sleep(5)
        wait_until(pred, tries - 1)
    end
  end
end
