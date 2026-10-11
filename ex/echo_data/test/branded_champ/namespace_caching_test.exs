defmodule EchoData.BrandedChamp.NamespaceCachingTest do
  @moduledoc """
  Comprehensive tests for namespace caching in BrandedChamp.

  BrandedChamp maintains O(1) namespace counts via `namespace_sizes` map.
  These tests verify cache consistency across all operations.

  ## Key Invariants

  1. `namespace_size(champ, ns) == length(get_namespace(champ, ns))`
  2. `size(champ) == sum(namespace_sizes)`
  3. Empty namespaces are fully removed (both from `namespaces` and `namespace_sizes`)
  4. Updates to existing keys don't change counts
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias EchoData.{Base62, Snowflake, BrandedChamp}

  # =============================================================================
  # HELPERS
  # =============================================================================

  defp generate_id(ns) when byte_size(ns) == 3 do
    ns <> Base62.encode(Snowflake.generate())
  end

  defp generate_ids(ns, count) do
    for _ <- 1..count, do: generate_id(ns)
  end

  # Verify the fundamental cache invariant
  defp assert_cache_consistent(champ) do
    # Invariant 1: namespace_size matches actual count for each namespace
    for ns <- BrandedChamp.namespaces(champ) do
      cached_count = BrandedChamp.namespace_size(champ, ns)
      actual_count = length(BrandedChamp.get_namespace(champ, ns))

      assert cached_count == actual_count,
             "Cache inconsistency for #{ns}: cached=#{cached_count}, actual=#{actual_count}"
    end

    # Invariant 2: total size equals sum of namespace sizes
    total_from_cache =
      champ
      |> BrandedChamp.namespaces()
      |> Enum.map(&BrandedChamp.namespace_size(champ, &1))
      |> Enum.sum()

    assert BrandedChamp.size(champ) == total_from_cache,
           "Total size mismatch: size=#{BrandedChamp.size(champ)}, sum=#{total_from_cache}"

    # Invariant 3: empty namespaces should not exist in the map
    assert Enum.all?(BrandedChamp.namespaces(champ), fn ns ->
             BrandedChamp.namespace_size(champ, ns) > 0
           end),
           "Found empty namespace in namespaces list"
  end

  # =============================================================================
  # O(1) COMPLEXITY TESTS
  # =============================================================================

  describe "O(1) namespace_size complexity" do
    test "namespace_size is O(1) regardless of namespace population" do
      # Build a CHAMP with 10,000 entries in one namespace
      champ =
        Enum.reduce(1..10_000, BrandedChamp.new(), fn _, acc ->
          BrandedChamp.put(acc, generate_id("PLR"), %{test: true})
        end)

      # Measure time for namespace_size (should be constant)
      {time_10k, count_10k} = :timer.tc(fn -> BrandedChamp.namespace_size(champ, "PLR") end)

      assert count_10k == 10_000

      # O(1) operation should complete in < 100 microseconds
      # (being generous to account for GC and system variance)
      assert time_10k < 100,
             "namespace_size took #{time_10k}μs - should be O(1)"
    end

    test "namespace_size stays O(1) with multiple namespaces" do
      # Create CHAMP with 5 namespaces, 1000 entries each
      namespaces = ["PLR", "ROM", "SES", "SCR", "ADM"]

      champ =
        Enum.reduce(namespaces, BrandedChamp.new(), fn ns, acc ->
          Enum.reduce(1..1000, acc, fn _, inner_acc ->
            BrandedChamp.put(inner_acc, generate_id(ns), %{ns: ns})
          end)
        end)

      # Each namespace_size should be O(1)
      for ns <- namespaces do
        {time, count} = :timer.tc(fn -> BrandedChamp.namespace_size(champ, ns) end)

        assert count == 1000
        assert time < 100, "namespace_size for #{ns} took #{time}μs"
      end
    end

    test "namespace_size comparison: cached vs computed" do
      champ =
        Enum.reduce(1..5000, BrandedChamp.new(), fn _, acc ->
          BrandedChamp.put(acc, generate_id("JOB"), %{})
        end)

      # Cached version (O(1))
      {cached_time, cached_count} =
        :timer.tc(fn -> BrandedChamp.namespace_size(champ, "JOB") end)

      # Computed version (O(n) - actually counting)
      {computed_time, computed_count} =
        :timer.tc(fn -> length(BrandedChamp.get_namespace(champ, "JOB")) end)

      assert cached_count == computed_count

      # Cached should be at least 10x faster
      ratio = computed_time / max(cached_time, 1)

      assert ratio > 10,
             "Cached (#{cached_time}μs) should be much faster than computed (#{computed_time}μs), ratio: #{ratio}"
    end
  end

  # =============================================================================
  # CACHE CONSISTENCY - PUT OPERATIONS
  # =============================================================================

  describe "cache consistency on put" do
    test "put increments namespace count for new key" do
      champ = BrandedChamp.new()
      assert BrandedChamp.namespace_size(champ, "PLR") == 0

      id = generate_id("PLR")
      champ = BrandedChamp.put(champ, id, %{name: "Alice"})

      assert BrandedChamp.namespace_size(champ, "PLR") == 1
      assert_cache_consistent(champ)
    end

    test "put does not increment count for existing key (update)" do
      id = generate_id("PLR")

      champ =
        BrandedChamp.new()
        |> BrandedChamp.put(id, %{name: "Alice"})

      assert BrandedChamp.namespace_size(champ, "PLR") == 1

      # Update same key
      champ = BrandedChamp.put(champ, id, %{name: "Alice Updated"})

      # Count should remain 1
      assert BrandedChamp.namespace_size(champ, "PLR") == 1
      assert {:ok, %{name: "Alice Updated"}} = BrandedChamp.fetch(champ, id)
      assert_cache_consistent(champ)
    end

    test "sequential puts maintain accurate counts" do
      ids = generate_ids("PLR", 100)

      champ =
        Enum.reduce(ids, BrandedChamp.new(), fn id, acc ->
          new_champ = BrandedChamp.put(acc, id, %{id: id})
          assert_cache_consistent(new_champ)
          new_champ
        end)

      assert BrandedChamp.namespace_size(champ, "PLR") == 100
    end

    test "puts across multiple namespaces maintain independent counts" do
      champ =
        BrandedChamp.new()
        |> BrandedChamp.put(generate_id("PLR"), %{type: :player})
        |> BrandedChamp.put(generate_id("PLR"), %{type: :player})
        |> BrandedChamp.put(generate_id("ROM"), %{type: :room})
        |> BrandedChamp.put(generate_id("SES"), %{type: :session})
        |> BrandedChamp.put(generate_id("SES"), %{type: :session})
        |> BrandedChamp.put(generate_id("SES"), %{type: :session})

      assert BrandedChamp.namespace_size(champ, "PLR") == 2
      assert BrandedChamp.namespace_size(champ, "ROM") == 1
      assert BrandedChamp.namespace_size(champ, "SES") == 3
      assert BrandedChamp.size(champ) == 6
      assert_cache_consistent(champ)
    end

    test "put_by_snowflake maintains cache consistency" do
      champ = BrandedChamp.new()

      # Insert using snowflake API
      snowflake1 = Snowflake.generate()
      snowflake2 = Snowflake.generate()

      champ =
        champ
        |> BrandedChamp.put_by_snowflake("PLR", snowflake1, %{name: "Alice"})
        |> BrandedChamp.put_by_snowflake("PLR", snowflake2, %{name: "Bob"})

      assert BrandedChamp.namespace_size(champ, "PLR") == 2
      assert_cache_consistent(champ)

      # Update existing snowflake
      champ = BrandedChamp.put_by_snowflake(champ, "PLR", snowflake1, %{name: "Alice Updated"})

      assert BrandedChamp.namespace_size(champ, "PLR") == 2
      assert_cache_consistent(champ)
    end
  end

  # =============================================================================
  # CACHE CONSISTENCY - DELETE OPERATIONS
  # =============================================================================

  describe "cache consistency on delete" do
    test "delete decrements namespace count" do
      id = generate_id("PLR")

      champ =
        BrandedChamp.new()
        |> BrandedChamp.put(id, %{name: "Alice"})

      assert BrandedChamp.namespace_size(champ, "PLR") == 1

      champ = BrandedChamp.delete(champ, id)

      assert BrandedChamp.namespace_size(champ, "PLR") == 0
      assert_cache_consistent(champ)
    end

    test "delete non-existent key does not change count" do
      existing_id = generate_id("PLR")
      non_existent_id = generate_id("PLR")

      champ =
        BrandedChamp.new()
        |> BrandedChamp.put(existing_id, %{name: "Alice"})

      assert BrandedChamp.namespace_size(champ, "PLR") == 1

      # Delete non-existent key
      champ = BrandedChamp.delete(champ, non_existent_id)

      assert BrandedChamp.namespace_size(champ, "PLR") == 1
      assert_cache_consistent(champ)
    end

    test "deleting last item in namespace removes namespace entirely" do
      id = generate_id("PLR")

      champ =
        BrandedChamp.new()
        |> BrandedChamp.put(id, %{name: "Alice"})

      assert "PLR" in BrandedChamp.namespaces(champ)

      champ = BrandedChamp.delete(champ, id)

      # Namespace should be completely removed
      refute "PLR" in BrandedChamp.namespaces(champ)
      assert BrandedChamp.namespace_size(champ, "PLR") == 0
      assert BrandedChamp.get_namespace(champ, "PLR") == []
      assert_cache_consistent(champ)
    end

    test "sequential deletes maintain accurate counts" do
      ids = generate_ids("PLR", 50)

      champ =
        Enum.reduce(ids, BrandedChamp.new(), fn id, acc ->
          BrandedChamp.put(acc, id, %{id: id})
        end)

      assert BrandedChamp.namespace_size(champ, "PLR") == 50

      # Delete all one by one
      final_champ =
        Enum.reduce(ids, champ, fn id, acc ->
          new_champ = BrandedChamp.delete(acc, id)
          assert_cache_consistent(new_champ)
          new_champ
        end)

      assert BrandedChamp.namespace_size(final_champ, "PLR") == 0
      assert BrandedChamp.empty?(final_champ)
    end

    test "delete_by_snowflake maintains cache consistency" do
      snowflake1 = Snowflake.generate()
      snowflake2 = Snowflake.generate()

      champ =
        BrandedChamp.new()
        |> BrandedChamp.put_by_snowflake("PLR", snowflake1, %{name: "Alice"})
        |> BrandedChamp.put_by_snowflake("PLR", snowflake2, %{name: "Bob"})

      assert BrandedChamp.namespace_size(champ, "PLR") == 2

      champ = BrandedChamp.delete_by_snowflake(champ, "PLR", snowflake1)

      assert BrandedChamp.namespace_size(champ, "PLR") == 1
      assert_cache_consistent(champ)

      champ = BrandedChamp.delete_by_snowflake(champ, "PLR", snowflake2)

      assert BrandedChamp.namespace_size(champ, "PLR") == 0
      refute "PLR" in BrandedChamp.namespaces(champ)
      assert_cache_consistent(champ)
    end

    test "deletes across multiple namespaces maintain independent counts" do
      plr_ids = generate_ids("PLR", 3)
      rom_ids = generate_ids("ROM", 2)

      champ =
        BrandedChamp.new()
        |> then(fn c -> Enum.reduce(plr_ids, c, &BrandedChamp.put(&2, &1, %{})) end)
        |> then(fn c -> Enum.reduce(rom_ids, c, &BrandedChamp.put(&2, &1, %{})) end)

      assert BrandedChamp.namespace_size(champ, "PLR") == 3
      assert BrandedChamp.namespace_size(champ, "ROM") == 2

      # Delete one from PLR
      champ = BrandedChamp.delete(champ, hd(plr_ids))

      assert BrandedChamp.namespace_size(champ, "PLR") == 2
      assert BrandedChamp.namespace_size(champ, "ROM") == 2
      assert_cache_consistent(champ)

      # Delete all from ROM
      champ =
        rom_ids
        |> Enum.reduce(champ, &BrandedChamp.delete(&2, &1))

      assert BrandedChamp.namespace_size(champ, "PLR") == 2
      assert BrandedChamp.namespace_size(champ, "ROM") == 0
      refute "ROM" in BrandedChamp.namespaces(champ)
      assert_cache_consistent(champ)
    end
  end

  # =============================================================================
  # EDGE CASES
  # =============================================================================

  describe "edge cases" do
    test "namespace_size for non-existent namespace returns 0" do
      champ = BrandedChamp.new()
      assert BrandedChamp.namespace_size(champ, "ZZZ") == 0
    end

    test "namespace_size for empty champ returns 0" do
      champ = BrandedChamp.new()
      assert BrandedChamp.namespace_size(champ, "PLR") == 0
      assert BrandedChamp.namespace_size(champ, "ROM") == 0
    end

    test "invalid namespace length returns 0 or raises" do
      champ = BrandedChamp.new()

      # 3-byte namespace required
      assert_raise FunctionClauseError, fn ->
        BrandedChamp.namespace_size(champ, "AB")
      end

      assert_raise FunctionClauseError, fn ->
        BrandedChamp.namespace_size(champ, "ABCD")
      end
    end

    test "put with invalid ID raises ArgumentError" do
      champ =
        BrandedChamp.new()
        |> BrandedChamp.put(generate_id("PLR"), %{valid: true})

      assert BrandedChamp.namespace_size(champ, "PLR") == 1

      # The audited BrandedChamp is loud at the boundary: an invalid branded id
      # raises ArgumentError (put/3 delegates to put!/3).
      assert_raise ArgumentError, fn ->
        BrandedChamp.put(champ, "invalid", %{invalid: true})
      end

      # Original champ unchanged
      assert BrandedChamp.namespace_size(champ, "PLR") == 1
      assert BrandedChamp.size(champ) == 1
      assert_cache_consistent(champ)
    end

    test "delete with invalid ID raises ArgumentError" do
      champ =
        BrandedChamp.new()
        |> BrandedChamp.put(generate_id("PLR"), %{valid: true})

      assert BrandedChamp.namespace_size(champ, "PLR") == 1

      # The audited BrandedChamp raises ArgumentError on an invalid branded id.
      assert_raise ArgumentError, fn ->
        BrandedChamp.delete(champ, "invalid")
      end

      # Original champ unchanged
      assert BrandedChamp.namespace_size(champ, "PLR") == 1
      assert_cache_consistent(champ)
    end

    test "repeated put-delete cycles maintain consistency" do
      id = generate_id("PLR")
      champ = BrandedChamp.new()

      # Cycle through put-delete 10 times
      final_champ =
        Enum.reduce(1..10, champ, fn i, acc ->
          acc = BrandedChamp.put(acc, id, %{iteration: i})
          assert BrandedChamp.namespace_size(acc, "PLR") == 1

          acc = BrandedChamp.delete(acc, id)
          assert BrandedChamp.namespace_size(acc, "PLR") == 0

          acc
        end)

      assert BrandedChamp.empty?(final_champ)
      assert_cache_consistent(final_champ)
    end

    test "merge preserves cache consistency" do
      champ1 =
        BrandedChamp.new()
        |> BrandedChamp.put(generate_id("PLR"), %{from: :champ1})
        |> BrandedChamp.put(generate_id("PLR"), %{from: :champ1})

      champ2 =
        BrandedChamp.new()
        |> BrandedChamp.put(generate_id("ROM"), %{from: :champ2})
        |> BrandedChamp.put(generate_id("PLR"), %{from: :champ2})

      merged = BrandedChamp.merge(champ1, champ2)

      assert BrandedChamp.namespace_size(merged, "PLR") == 3
      assert BrandedChamp.namespace_size(merged, "ROM") == 1
      assert BrandedChamp.size(merged) == 4
      assert_cache_consistent(merged)
    end

    test "rebuilding from a filtered to_list preserves cache consistency" do
      ids = generate_ids("PLR", 10)

      champ =
        ids
        |> Enum.with_index()
        |> Enum.reduce(BrandedChamp.new(), fn {id, i}, acc ->
          BrandedChamp.put(acc, id, %{index: i, even: rem(i, 2) == 0})
        end)

      # The audited BrandedChamp drops the convenience `filter/2`; rebuild from a
      # filtered to_list (the streaming Enumerable over the unified structure).
      filtered =
        champ
        |> BrandedChamp.to_list()
        |> Enum.filter(fn {_id, data} -> data.even end)
        |> BrandedChamp.new()

      assert BrandedChamp.namespace_size(filtered, "PLR") == 5
      assert_cache_consistent(filtered)
    end
  end

  # =============================================================================
  # PROPERTY-BASED TESTS
  # =============================================================================

  describe "property-based tests" do
    property "namespace_size always equals actual count" do
      check all(operations <- list_of(operation_generator(), min_length: 1, max_length: 100)) do
        champ =
          Enum.reduce(operations, BrandedChamp.new(), fn op, acc ->
            apply_operation(acc, op)
          end)

        assert_cache_consistent(champ)
      end
    end

    property "total size equals sum of namespace sizes" do
      check all(entries <- list_of(entry_generator(), min_length: 0, max_length: 50)) do
        champ = BrandedChamp.new(entries)

        total_from_namespaces =
          champ
          |> BrandedChamp.namespaces()
          |> Enum.map(&BrandedChamp.namespace_size(champ, &1))
          |> Enum.sum()

        assert BrandedChamp.size(champ) == total_from_namespaces
      end
    end

    property "put followed by delete returns to original count" do
      check all({ns, initial_count} <- tuple({namespace_generator(), integer(0..20)})) do
        # Build initial champ with explicit range handling for count=0
        ids =
          if initial_count > 0 do
            for _ <- 1..initial_count, do: generate_id(ns)
          else
            []
          end

        champ =
          Enum.reduce(ids, BrandedChamp.new(), fn id, acc ->
            BrandedChamp.put(acc, id, %{})
          end)

        original_size = BrandedChamp.namespace_size(champ, ns)
        assert original_size == initial_count

        # Add one and delete it
        new_id = generate_id(ns)
        champ = BrandedChamp.put(champ, new_id, %{})
        assert BrandedChamp.namespace_size(champ, ns) == initial_count + 1

        champ = BrandedChamp.delete(champ, new_id)
        assert BrandedChamp.namespace_size(champ, ns) == initial_count
      end
    end
  end

  # =============================================================================
  # STRESS TESTS
  # =============================================================================

  describe "stress tests" do
    @tag :slow
    test "handles large number of entries with consistent caching" do
      namespaces = ["PLR", "ROM", "SES", "SCR", "ADM", "JOB", "EVT", "WKR"]
      entries_per_ns = 1000

      champ =
        Enum.reduce(namespaces, BrandedChamp.new(), fn ns, acc ->
          Enum.reduce(1..entries_per_ns, acc, fn i, inner_acc ->
            BrandedChamp.put(inner_acc, generate_id(ns), %{ns: ns, index: i})
          end)
        end)

      # Verify all counts
      for ns <- namespaces do
        assert BrandedChamp.namespace_size(champ, ns) == entries_per_ns
      end

      assert BrandedChamp.size(champ) == length(namespaces) * entries_per_ns
      assert_cache_consistent(champ)
    end

    @tag :slow
    test "interleaved put/delete operations maintain consistency" do
      # Create a mix of operations
      operations =
        Enum.flat_map(1..500, fn i ->
          ns = Enum.random(["PLR", "ROM", "SES"])
          id = generate_id(ns)

          if rem(i, 3) == 0 do
            # Sometimes just add
            [{:put, id, %{i: i}}]
          else
            # Add then delete
            [{:put, id, %{i: i}}, {:delete, id}]
          end
        end)
        |> List.flatten()

      champ =
        Enum.reduce(operations, BrandedChamp.new(), fn
          {:put, id, value}, acc -> BrandedChamp.put(acc, id, value)
          {:delete, id}, acc -> BrandedChamp.delete(acc, id)
        end)

      assert_cache_consistent(champ)
    end
  end

  # =============================================================================
  # PROPERTY TEST GENERATORS
  # =============================================================================

  defp namespace_generator do
    member_of(["PLR", "ROM", "SES", "SCR", "ADM", "JOB", "EVT", "WKR"])
  end

  defp entry_generator do
    gen all(
          ns <- namespace_generator(),
          value <- map_of(atom(:alphanumeric), term(), max_length: 3)
        ) do
      {generate_id(ns), value}
    end
  end

  defp operation_generator do
    frequency([
      {3, put_operation()},
      {1, delete_operation()}
    ])
  end

  defp put_operation do
    gen all(
          ns <- namespace_generator(),
          value <- map_of(atom(:alphanumeric), term(), max_length: 3)
        ) do
      {:put, generate_id(ns), value}
    end
  end

  defp delete_operation do
    gen all(ns <- namespace_generator()) do
      {:delete, generate_id(ns)}
    end
  end

  defp apply_operation(champ, {:put, id, value}) do
    BrandedChamp.put(champ, id, value)
  end

  defp apply_operation(champ, {:delete, id}) do
    BrandedChamp.delete(champ, id)
  end
end
