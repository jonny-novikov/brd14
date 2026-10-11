defmodule EchoData.Bcs.ProjectionTest do
  @moduledoc """
  bcs2.2 — the read projection: writes through the owner, reads beside it.

  The star scenario (E0, RED on HEAD by construction): suspend the owner and
  reads still answer while a concurrently spawned write is provably blocked.
  On HEAD every read verb is a `GenServer.call`, so a suspended owner blocks
  reads exactly as it blocks writes — the suspend tests fail there.
  """

  use ExUnit.Case, async: false

  alias EchoData.BrandedId
  alias EchoData.Bcs.EdgeStore
  alias EchoData.Bcs.Projection
  alias EchoData.Bcs.PropertyStore

  # registered census rows only (the bcs2.1 namespaces audit): ORD for the
  # property store, PRT/AST for the edge store, USR as the foreign kind —
  # the same codes the four compat files mint under
  @ns "ORD"
  @sns "PRT"
  @ons "AST"

  defp mint(i), do: BrandedId.encode!(@ns, i)
  defp mint_s(i), do: BrandedId.encode!(@sns, i)
  defp mint_o(i), do: BrandedId.encode!(@ons, i)

  defp await(fun, timeout \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    await_loop(fun, deadline)
  end

  defp await_loop(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met within the await window")

      true ->
        Process.sleep(10)
        await_loop(fun, deadline)
    end
  end

  describe "US1 — reads answer while the owner is suspended" do
    test "property store: suspended owner blocks a write, every read verb answers" do
      store = :bcs22_ps_suspend
      start_supervised!({PropertyStore, name: store, namespace: @ns})

      ids = for i <- 1..5, do: mint(i)
      for {id, i} <- Enum.with_index(ids, 1), do: :ok = PropertyStore.put(store, id, %{n: i})

      pid = Process.whereis(store)

      try do
        :ok = :sys.suspend(pid)

        # the write path stays on the mailbox: spawned + monitored, no exit
        # (thus no reply) while the owner is suspended
        writer_id = mint(100)

        {writer, mref} =
          spawn_monitor(fn ->
            :ok = PropertyStore.put(store, writer_id, %{n: 100})
          end)

        # record_entity blocks in put/3's class under suspension: its barrier
        # rides the NORMAL mailbox, never the sys plane (Apollo G-1 / D-6 —
        # a sys-plane barrier returns 0 ms while the cast is still queued)
        entity_id = mint(101)

        {recorder, rref} =
          spawn_monitor(fn ->
            :ok = PropertyStore.record_entity(store, entity_id)
          end)

        refute_receive {:DOWN, ^mref, :process, ^writer, _}, 300
        refute_receive {:DOWN, ^rref, :process, ^recorder, _}, 100

        # every read verb answers its bcs1.1 shape with the owner suspended
        assert {:ok, %{n: 1}} = PropertyStore.get(store, mint(1))
        assert {:ok, listed} = PropertyStore.window(store, mint(1), mint(6))
        assert listed == ids
        assert {:ok, page} = PropertyStore.page_desc(store, 3)
        assert page == [mint(5), mint(4), mint(3)]

        # and the suspended-blocked record_entity is NOT visible yet
        assert {:error, :not_found} = PropertyStore.get(store, entity_id)

        # resume: both blocked writes land and are readable
        :ok = :sys.resume(pid)
        assert_receive {:DOWN, ^mref, :process, ^writer, :normal}, 1_000
        assert_receive {:DOWN, ^rref, :process, ^recorder, :normal}, 1_000
        assert {:ok, %{n: 100}} = PropertyStore.get(store, writer_id)
        assert {:ok, true} = PropertyStore.get(store, entity_id)
      after
        :sys.resume(pid)
      end
    end

    test "edge store: suspended owner blocks a link, every read verb answers" do
      store = :bcs22_es_suspend

      start_supervised!(
        {EdgeStore, name: store, relation: :holds, subject_ns: @sns, object_ns: @ons}
      )

      s1 = mint_s(1)
      s2 = mint_s(2)
      o1 = mint_o(1)
      o2 = mint_o(2)

      :ok = EdgeStore.link(store, s1, o1, %{w: 1})
      :ok = EdgeStore.link(store, s1, o2, %{w: 2})
      :ok = EdgeStore.link(store, s2, o1, %{w: 3})

      pid = Process.whereis(store)

      try do
        :ok = :sys.suspend(pid)

        {writer, mref} =
          spawn_monitor(fn ->
            :ok = EdgeStore.link(store, s2, o2, %{w: 4})
          end)

        refute_receive {:DOWN, ^mref, :process, ^writer, _}, 300

        assert {:ok, %{w: 1}} = EdgeStore.props(store, s1, o1)
        assert {:ok, [{^o1, %{w: 1}}, {^o2, %{w: 2}}]} = EdgeStore.from(store, s1)
        assert {:ok, [{^s1, %{w: 1}}, {^s2, %{w: 3}}]} = EdgeStore.to(store, o1)
        assert {:ok, 2} = EdgeStore.degree(store, s1)

        :ok = :sys.resume(pid)
        assert_receive {:DOWN, ^mref, :process, ^writer, :normal}, 1_000
        assert {:ok, %{w: 4}} = EdgeStore.props(store, s2, o2)
      after
        :sys.resume(pid)
      end
    end
  end

  describe "US2 — the gate rides every read, in the reader's process" do
    test "wrong-namespace and invalid ids answer the bcs1.1 error shapes on a live store" do
      store = :bcs22_ps_gate
      start_supervised!({PropertyStore, name: store, namespace: @ns})
      :ok = PropertyStore.put(store, mint(1), %{n: 1})

      alien = BrandedId.encode!("USR", 1)

      assert {:error, :namespace} = PropertyStore.get(store, alien)
      assert {:error, :namespace} = PropertyStore.window(store, alien, mint(9))
      assert {:error, :namespace} = PropertyStore.window(store, mint(1), alien)
      assert {:error, :invalid} = PropertyStore.get(store, "not-an-id")

      # a valid id absent from the store: shape-identical to bcs1.1
      assert {:error, :not_found} = PropertyStore.get(store, mint(42))
    end

    test "edge store: both ends gated caller-side with the bcs1.1 shapes" do
      store = :bcs22_es_gate

      start_supervised!(
        {EdgeStore, name: store, relation: :holds, subject_ns: @sns, object_ns: @ons}
      )

      :ok = EdgeStore.link(store, mint_s(1), mint_o(1), %{})
      alien = BrandedId.encode!("USR", 1)

      assert {:error, :namespace} = EdgeStore.props(store, alien, mint_o(1))
      assert {:error, :namespace} = EdgeStore.props(store, mint_s(1), alien)
      assert {:error, :namespace} = EdgeStore.from(store, alien)
      assert {:error, :namespace} = EdgeStore.to(store, alien)
      assert {:error, :namespace} = EdgeStore.degree(store, alien)
      assert {:error, :invalid} = EdgeStore.from(store, "not-an-id")
      assert {:error, :not_found} = EdgeStore.props(store, mint_s(9), mint_o(9))
    end

    test "a refusal provably touches no table: it answers even when the table is gone" do
      # construction proof: the gate runs BEFORE any table dereference, so a
      # wrong-namespace read against a store whose projection no longer exists
      # still answers {:error, :namespace} — while a valid-namespace read on the
      # same dead store raises (proving reads do dereference the table, and
      # only after the gate passes).
      store = :bcs22_ps_dead
      pid = start_supervised!({PropertyStore, name: store, namespace: @ns}, restart: :temporary)
      t = Projection.table_name(store)

      mref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^mref, :process, ^pid, :killed}, 1_000
      await(fn -> :ets.info(t) == :undefined end)

      alien = BrandedId.encode!("USR", 1)
      assert {:error, :namespace} = PropertyStore.get(store, alien)
      assert {:error, :invalid} = PropertyStore.get(store, "not-an-id")
      assert_raise ArgumentError, fn -> PropertyStore.get(store, mint(1)) end
    end
  end

  describe "US3 — writes are owner-only by mechanism, visible on return" do
    test "the :protected pin: a reader's insert raises on every projection" do
      ps = :bcs22_ps_pin
      es = :bcs22_es_pin
      start_supervised!({PropertyStore, name: ps, namespace: @ns})

      start_supervised!(
        {EdgeStore, name: es, relation: :holds, subject_ns: @sns, object_ns: @ons}
      )

      assert_raise ArgumentError, fn ->
        :ets.insert(Projection.table_name(ps), {mint(1), :corrupt})
      end

      assert_raise ArgumentError, fn ->
        :ets.insert(Projection.table_name(es), {{mint_s(1), mint_o(1)}, :corrupt})
      end

      assert_raise ArgumentError, fn ->
        :ets.insert(Projection.table_name(es, :rev), {{mint_o(1), mint_s(1)}, :corrupt})
      end
    end

    test "read-your-writes per property-store write verb" do
      store = :bcs22_ps_rw
      start_supervised!({PropertyStore, name: store, namespace: @ns})

      # put/3: visible the instant the call returns
      :ok = PropertyStore.put(store, mint(1), %{n: 1})
      assert {:ok, %{n: 1}} = PropertyStore.get(store, mint(1))

      # put/3 overwrite
      :ok = PropertyStore.put(store, mint(1), %{n: 11})
      assert {:ok, %{n: 11}} = PropertyStore.get(store, mint(1))

      # record_entity/2: visible the instant the wrapper returns — no test-side
      # barrier; the wrapper's own mailbox sync is the guarantee under pin
      :ok = PropertyStore.record_entity(store, mint(2))
      assert {:ok, true} = PropertyStore.get(store, mint(2))

      # window and page_desc see the writes
      assert {:ok, ids} = PropertyStore.window(store, mint(1), mint(9))
      assert ids == [mint(1), mint(2)]
      assert {:ok, [last]} = PropertyStore.page_desc(store, 1)
      assert last == mint(2)
    end

    test "read-your-writes per edge-store write verb, both directions" do
      store = :bcs22_es_rw

      start_supervised!(
        {EdgeStore, name: store, relation: :holds, subject_ns: @sns, object_ns: @ons}
      )

      s1 = mint_s(1)
      o1 = mint_o(1)
      o2 = mint_o(2)

      # link/4: both projections reflect the edge on return
      :ok = EdgeStore.link(store, s1, o1, %{w: 1})
      :ok = EdgeStore.link(store, s1, o2, %{w: 2})
      assert {:ok, %{w: 1}} = EdgeStore.props(store, s1, o1)
      assert {:ok, [{^o1, %{w: 1}}, {^o2, %{w: 2}}]} = EdgeStore.from(store, s1)
      assert {:ok, [{^s1, %{w: 1}}]} = EdgeStore.to(store, o1)
      assert {:ok, 2} = EdgeStore.degree(store, s1)

      # link/4 re-link updates props
      :ok = EdgeStore.link(store, s1, o1, %{w: 10})
      assert {:ok, %{w: 10}} = EdgeStore.props(store, s1, o1)

      # from/3 honors the limit on the projection
      assert {:ok, [{^o1, %{w: 10}}]} = EdgeStore.from(store, s1, 1)

      # unlink/3: both projections are clear on return
      :ok = EdgeStore.unlink(store, s1, o1)
      assert {:error, :not_found} = EdgeStore.props(store, s1, o1)
      assert {:ok, [{^o2, %{w: 2}}]} = EdgeStore.from(store, s1)
      assert {:ok, []} = EdgeStore.to(store, o1)
      assert {:ok, 1} = EdgeStore.degree(store, s1)

      # unlink of an absent edge keeps the bcs1.1 shape
      assert {:error, :not_found} = EdgeStore.unlink(store, s1, o1)
    end
  end

  describe "US4 — the projection's lifetime is declared" do
    test "without :heir the named projection dies with its owner" do
      store = :bcs22_ps_kill
      pid = start_supervised!({PropertyStore, name: store, namespace: @ns}, restart: :temporary)
      t = Projection.table_name(store)

      :ok = PropertyStore.put(store, mint(1), %{n: 1})
      assert :ets.info(t) != :undefined

      mref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^mref, :process, ^pid, :killed}, 1_000
      await(fn -> :ets.info(t) == :undefined end)
    end

    test "edge store without :heir: both projections die with the owner" do
      store = :bcs22_es_kill

      pid =
        start_supervised!(
          {EdgeStore, name: store, relation: :holds, subject_ns: @sns, object_ns: @ons},
          restart: :temporary
        )

      fwd = Projection.table_name(store)
      rev = Projection.table_name(store, :rev)
      :ok = EdgeStore.link(store, mint_s(1), mint_o(1), %{})

      mref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^mref, :process, ^pid, :killed}, 1_000
      await(fn -> :ets.info(fwd) == :undefined and :ets.info(rev) == :undefined end)
    end

    test "with :heir the projection survives at the heir" do
      store = :bcs22_ps_heir

      pid =
        start_supervised!(
          {PropertyStore, name: store, namespace: @ns, heir: {self(), :bcs22_heir}},
          restart: :temporary
        )

      t = Projection.table_name(store)
      :ok = PropertyStore.put(store, mint(1), %{n: 1})

      mref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^mref, :process, ^pid, :killed}, 1_000
      assert_receive {:"ETS-TRANSFER", ^t, ^pid, :bcs22_heir}, 1_000

      # the table lives on at the heir, rows intact and readable
      assert :ets.info(t) != :undefined
      assert :ets.info(t, :owner) == self()
      assert {:ok, %{n: 1}} = PropertyStore.get(store, mint(1))
    end

    test "edge store with :heir: both projections survive at the heir" do
      store = :bcs22_es_heir

      pid =
        start_supervised!(
          {EdgeStore,
           name: store,
           relation: :holds,
           subject_ns: @sns,
           object_ns: @ons,
           heir: {self(), :bcs22_heir}},
          restart: :temporary
        )

      fwd = Projection.table_name(store)
      rev = Projection.table_name(store, :rev)
      s1 = mint_s(1)
      o1 = mint_o(1)
      :ok = EdgeStore.link(store, s1, o1, %{w: 1})

      mref = Process.monitor(pid)
      Process.exit(pid, :kill)
      assert_receive {:DOWN, ^mref, :process, ^pid, :killed}, 1_000
      assert_receive {:"ETS-TRANSFER", ^fwd, ^pid, :bcs22_heir}, 1_000
      assert_receive {:"ETS-TRANSFER", ^rev, ^pid, :bcs22_heir}, 1_000

      assert {:ok, %{w: 1}} = EdgeStore.props(store, s1, o1)
      assert {:ok, [{^s1, %{w: 1}}]} = EdgeStore.to(store, o1)
    end
  end
end
