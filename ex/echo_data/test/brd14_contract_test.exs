defmodule EchoData.Brd14ContractTest do
  @moduledoc """
  The brd14 contract vectors, pinned in the Elixir sibling.

  Source of every literal: `github.com/jonny-novikov/brd14` v0.1.0 (commit `8e8b7b0`),
  files `contract_test.go`, `epoch_test.go` and `snowflake_node_test.go`. The family ids
  (V-n, T-n, E-n) are the Go suite's own, and the C# suite in devops-tools uses the same ids,
  so a search for `V-7` across the three trees reads out the conformance matrix. The contract
  travels as test vectors, not as a shared object.

  Deliberately not ported:

    * N-1, the `nodeFrom(host, pid)` golden vectors: this app derives its node from
      `phash2(node(), 1024)` by design (awk-nodeid §3.2), so there is no counterpart to pin.
    * The PCG-seeded random draws of T-1, T-2 and T-4 and the V-7 shuffle: their seeds are
      specific to Go's `math/rand/v2`. The fixed boundary sets are ported instead.
    * Generator-behaviour vectors (first sequence, borrow, regression): the generator reads
      `System.system_time/1` directly, and this suite leaves `lib/` untouched.
  """
  use ExUnit.Case, async: true

  import Bitwise

  alias EchoData.{BrandedId, Snowflake}

  @epoch_literal 1_704_067_200_000
  @v1_id "USR0KHTOWnGLuC"
  @v1_snow 274_557_032_793_636_864
  @v2_id "USR0NgWEfAEJfs"
  @v2_snow 320_636_799_581_945_856
  # 2^63 - 1: the largest encodable snowflake.
  @max_snow 9_223_372_036_854_775_807
  @max_payload "AzL8n0Y58m7"

  describe "V-1..V-6: the cross-language byte-equal vectors" do
    test "V-1 encodes the reference snowflake, and parse inverts it" do
      assert BrandedId.encode!("USR", @v1_snow) == @v1_id
      assert BrandedId.parse(@v1_id) == {:ok, "USR", @v1_snow}
    end

    test "V-2 parses the second reference id" do
      assert BrandedId.parse(@v2_id) == {:ok, "USR", @v2_snow}
    end

    # V-3 and V-4 claim the payload, whatever the brand. The Go suite brands them "ABC";
    # here they carry "USR", because the census audit (bcs2.1 R2) requires every code
    # minted in this umbrella to be an active row of EchoData.Namespace.
    test "V-3 the zero snowflake's payload is eleven zeros at full width" do
      zero = BrandedId.encode!("USR", 0)

      assert zero == "USR00000000000"
      assert byte_size(zero) == 14
    end

    test "V-4 base62(2^63-1) is the max payload" do
      assert binary_part(BrandedId.encode!("USR", @max_snow), 3, 11) == @max_payload
    end

    test "V-5 rejects each reject class" do
      for {class, bad} <- [
            {"payload above 2^63-1", "USRzzzzzzzzzzz"},
            {"lowercase namespace", "usr0KHTOWnGLuC"},
            {"length below 14", "USR0KHTOWnGLu"},
            {"length above 14", "USR0KHTOWnGLuCC"}
          ] do
        refute BrandedId.valid?(bad), "V-5 #{class}: #{inspect(bad)} accepted"
      end
    end

    test "V-6 the trie-placement hash" do
      assert BrandedId.hash32(@v1_snow) == 234_878_118
    end
  end

  describe "V-7: a byte-wise sort reproduces mint order" do
    test "V-7 sorting the encoded SES set restores its mint order" do
      # 0..61 put every alphabet index in the low digit, so any transposition of two
      # alphabet positions reorders the set; the rest are the carry boundaries, a populated
      # node and sequence, the maximum ts and the max-payload edge.
      mint_order =
        Enum.to_list(0..61) ++
          [
            62,
            3843,
            3844,
            1 <<< 22,
            1 <<< 22 ||| 613 <<< 12 ||| 7,
            2 <<< 22,
            1_234_567 <<< 22,
            ((1 <<< 41) - 1) <<< 22,
            @max_snow
          ]

      assert mint_order == Enum.sort(mint_order) and mint_order == Enum.uniq(mint_order),
             "the vector set is not strictly increasing; V-7's premise is broken"

      encoded = Enum.map(mint_order, &BrandedId.encode!("SES", &1))

      # Binaries compare byte-wise in Erlang term order: no decoding, no comparator.
      assert Enum.sort(Enum.reverse(encoded)) == encoded
    end
  end

  describe "T-1: parse is total over the fixed inputs" do
    test "T-1 every fixed input yields a value or :error, and valid?/decode agree" do
      inputs = [
        "",
        "A",
        "AB",
        "ABC",
        "USR",
        "USR0KHTOWnGLu",
        "USR0KHTOWnGLuC",
        "USR0KHTOWnGLuCX",
        "日本語のテスト文字列",
        "ÄÖÜ0KHTOWnGLuC",
        <<0, 1, 2>>,
        :binary.copy(<<0xFF>>, 14)
      ]

      for input <- inputs do
        parsed = BrandedId.parse(input)

        assert parsed == :error or match?({:ok, _, _}, parsed)
        assert BrandedId.valid?(input) == (parsed != :error)

        case parsed do
          {:ok, _ns, snow} -> assert BrandedId.decode(input) == {:ok, snow}
          :error -> assert BrandedId.decode(input) == :error
        end
      end

      assert Enum.filter(inputs, &BrandedId.valid?/1) == [@v1_id]
    end
  end

  describe "T-2: round trip over the boundary set" do
    test "T-2 parse(encode(ns, snow)) returns (ns, snow) at every boundary" do
      for snow <- [
            0,
            1,
            61,
            62,
            3843,
            3844,
            1 <<< 22,
            (1 <<< 41) - 1,
            ((1 <<< 41) - 1) <<< 22,
            @max_snow - 1,
            @max_snow
          ] do
        id = BrandedId.encode!("USR", snow)

        assert byte_size(id) == 14
        assert BrandedId.parse(id) == {:ok, "USR", snow}
      end
    end
  end

  describe "T-3: the domain guards" do
    test "T-3 encode refuses a snowflake outside int64" do
      for snow <- [1 <<< 63, (1 <<< 63) + 1, (1 <<< 64) - 1] do
        assert BrandedId.encode("USR", snow) == :error
      end
    end

    test "T-3 encode refuses every namespace outside 3 x [A-Z]" do
      for ns <- ["", "U", "US", "USRR", "usr", "UsR", "US1", "US ", "US-", "ÄÖÜ"] do
        assert BrandedId.encode(ns, 1) == :error, "T-3 encode accepted #{inspect(ns)}"
      end
    end

    test "T-3 the range guard is exact at the max payload" do
      assert BrandedId.parse("USR" <> @max_payload) == {:ok, "USR", @max_snow}
      assert BrandedId.parse("USRAzL8n0Y58m8") == :error
    end

    test "T-3 parse refuses the namespace, alphabet and length classes" do
      for {class, bad} <- [
            {"lowercase ns", "usr00000000000"},
            {"digit in ns", "US100000000000"},
            {"payload above max", "USRzzzzzzzzzzz"},
            {"non-alphabet byte", "USR0KHTOWnGLu!"},
            {"non-alphabet space", "USR0KHTOWnGLu "},
            {"length 13", "USR0000000000"},
            {"length 15", "USR000000000000"},
            {"length 0", ""}
          ] do
        assert BrandedId.parse(bad) == :error, "T-3 #{class}: #{inspect(bad)} accepted"
      end
    end
  end

  describe "E-1..E-3: the epoch is pinned absolutely" do
    test "E-1 the epoch is 2024-01-01T00:00:00Z as a literal" do
      assert Snowflake.epoch_ms() == @epoch_literal

      assert @epoch_literal |> DateTime.from_unix!(:millisecond) |> DateTime.to_iso8601() ==
               "2024-01-01T00:00:00.000Z"
    end

    test "E-2 the V-1 and V-2 snowflakes decode to their literal instants" do
      for {id, snow, ms, utc} <- [
            {@v1_id, @v1_snow, 1_769_526_697_641, "2026-01-27T15:11:37.641Z"},
            {@v2_id, @v2_snow, 1_780_512_970_164, "2026-06-03T18:56:10.164Z"}
          ] do
        assert BrandedId.parse(id) == {:ok, "USR", snow}
        assert Snowflake.unix_ms(snow) == ms
        assert snow |> Snowflake.to_datetime() |> DateTime.to_iso8601() == utc
      end
    end

    test "E-3 min_for at the V-1 instant is the tight half-open bound" do
      at = DateTime.from_unix!(1_769_526_697_641, :millisecond)
      want = (1_769_526_697_641 - @epoch_literal) <<< 22

      assert Snowflake.min_for(at) == want
      # V-1 carries node 0 and sequence 0, so the bound is V-1's own snowflake.
      assert Snowflake.min_for(at) == @v1_snow
      assert Snowflake.min_for(DateTime.add(at, -1, :millisecond)) < want
    end
  end

  describe "T-5: layout and epoch boundaries" do
    test "T-5 unix_ms, to_datetime and min_for at the epoch instants" do
      assert Snowflake.unix_ms(0) == @epoch_literal
      assert Snowflake.unix_ms(1 <<< 22) == @epoch_literal + 1
      # The node and sequence fields never leak into the extracted instant.
      assert Snowflake.unix_ms(1 <<< 22 ||| 1023 <<< 12 ||| 4095) == @epoch_literal + 1

      epoch = DateTime.from_unix!(@epoch_literal, :millisecond)

      assert Snowflake.min_for(epoch) == 0
      assert Snowflake.min_for(DateTime.add(epoch, 1, :millisecond)) == 1 <<< 22

      assert Snowflake.to_datetime(1 <<< 22) ==
               DateTime.from_unix!(@epoch_literal + 1, :millisecond)
    end

    test "T-5 a per-call node lands in its field, and ts|node|seq partitions the value" do
      snows = for _ <- 1..10_000, do: Snowflake.next(613)

      for snow <- snows do
        assert Snowflake.node_id(snow) == 613

        assert (snow >>> 22 <<< 22 ||| Snowflake.node_id(snow) <<< 12 ||| Snowflake.sequence(snow)) ==
                 snow
      end

      # Strictly increasing for a fixed node: the cell is shared with every concurrent
      # minter in the VM, and each of these calls observes a strictly greater cell.
      assert snows == Enum.sort(snows) and snows == Enum.uniq(snows)
    end
  end
end
