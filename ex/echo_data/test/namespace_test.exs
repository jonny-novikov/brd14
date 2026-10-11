defmodule EchoData.NamespaceTest do
  @moduledoc """
  bcs2.1 R3 + R4: the totality property, the appendix's example block as literal
  assertions, the census invariants, and the pinned developer-space seam.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias EchoData.{BrandedId, Namespace}

  doctest EchoData.Namespace

  # -- R3 (a): totality -------------------------------------------------------

  property "classify/1 is total: an arbitrary binary never raises and always answers one of the four shapes" do
    check all bin <- StreamData.binary() do
      result = Namespace.classify(bin)

      assert result in [:reserved, :developer, :invalid] or
               match?({:platform, tag} when is_atom(tag), result)
    end
  end

  property "classify/1 answers well-formed uppercase codes by width: 3 → platform-or-reserved, 4 → developer" do
    check all code <- StreamData.string(?A..?Z, min_length: 3, max_length: 4) do
      case byte_size(code) do
        3 ->
          assert Namespace.classify(code) == :reserved or
                   match?({:platform, tag} when is_atom(tag), Namespace.classify(code))

        4 ->
          assert Namespace.classify(code) == :developer
      end
    end
  end

  test "classify/1 and the read surface are total over non-binary terms" do
    for input <- [nil, :JOB, 42, 3.14, [], %{}, {:a, :b}, self()] do
      assert Namespace.classify(input) == :invalid
      assert Namespace.status(input) == :unregistered
      assert Namespace.program(input) == nil
      assert Namespace.semantics(input) == nil
      refute Namespace.active?(input)
    end
  end

  # -- R3 (b): the appendix's example block, literally ------------------------
  # docs/echo/bcs/appendixes/bcs.namespaces.md — assertions, not inspiration.

  test "the appendix's classify example block holds literally" do
    assert Namespace.classify("LOG") == {:platform, :log}
    assert Namespace.classify("TRC") == {:platform, :trace}
    assert Namespace.classify("COR") == {:platform, :correlation}
    assert Namespace.classify("USR") == {:platform, :user}
    assert Namespace.classify("SES") == {:platform, :session}
    assert Namespace.classify("XYZ") == :reserved
    assert Namespace.classify("SHOP") == :developer
    assert Namespace.classify("TEAM") == :developer
    assert Namespace.classify("LO") == :invalid
    assert Namespace.classify("LOGGG") == :invalid
  end

  # -- R3 (c): census invariants ----------------------------------------------

  test "census invariants: codes unique, statuses valid, active rows carry program + semantics" do
    rows = Namespace.all()
    codes = for {code, _, _, _, _} <- rows, do: code

    assert Enum.uniq(codes) == codes, "the census carries a duplicate code"

    for {code, space, _program, _semantics, status} = row <- rows do
      assert space == :platform, "row #{code} is outside the platform space: #{inspect(row)}"
      assert status in [:active, :reserved, :parked, :retired],
             "row #{code} carries an invalid status: #{inspect(status)}"
    end

    for {code, _space, program, semantics, :active} <- rows do
      assert is_binary(program) and program != "", "active row #{code} lacks a program"
      assert is_binary(semantics) and semantics != "", "active row #{code} lacks semantics"
    end
  end

  test "the seeded census matches bcs2.1 + the awk.1 APP row + the awk.4a TRC activation + the awk.6 REQ addition and COR flip: 30 active codes; LOG the sole reserved; OBX parked; TUN absent" do
    assert Enum.sort(Namespace.active_codes()) ==
             ~w(APP ARC AST BAT CFG CMT COR EMS EVT GAM GES GRP JOB MSG NOT ORD
                OTX PKG PLR PRT REQ ROM RVL SEG SES TRC TXN USR VOL WFL)

    # LOG is now the SOLE row reserved by decision — TRC activated by the awk.4a
    # F1 ruling, REQ added active by the awk.6 census act, COR flipped active by
    # the awk.6 Phase B act — vs parked by ruling (mq4.3 ADR-B) vs the
    # unregistered default (US3: status/1 distinguishes what classify/1 folds).
    assert Namespace.status("LOG") == :reserved
    assert Namespace.status("TRC") == :active
    assert Namespace.status("COR") == :active
    assert Namespace.status("OBX") == :parked

    # awk.6 §8.1 (a′): the REQ addition — census-active, classifying as the
    # :request kind. The entity is the api.anthropic.com request/response
    # exchange (req-proxy-design D-1), minted once per proxied exchange.
    assert Namespace.status("REQ") == :active
    assert Namespace.classify("REQ") == {:platform, :request}
    assert Namespace.active?("REQ")
    assert Namespace.program("REQ") == "observability"
    assert Namespace.semantics("REQ") == "api request/response"
    assert Namespace.classify("OBX") == :reserved
    assert Namespace.status("TUN") == :unregistered
    assert Namespace.status("ZZZ") == :unregistered
    refute Namespace.active?("LOG")
    refute Namespace.active?("OBX")
  end

  # -- awk.1 R1 (AS1): the RATIFIED APP row — dual-app identity, census-active --
  # docs/awkernel/specs/awk.1/awk.1.md D1 (D-2, Operator-ratified verbatim).

  test "awk.1: the APP row classifies {:platform, :app} and is census-active" do
    # An APP-branded id: the census governs it by its 3-byte code prefix.
    app_id = BrandedId.encode!("APP", 274_557_032_793_636_864)
    <<code::binary-size(3), _payload::binary>> = app_id

    assert code == "APP"
    assert Namespace.classify(code) == {:platform, :app}
    assert Namespace.classify("APP") == {:platform, :app}
    assert Namespace.active?("APP") == true
    assert Namespace.status("APP") == :active
    assert Namespace.program("APP") == "awkernel"
    assert Namespace.semantics("APP") == "dual-app identity"
  end

  # -- awk.6 §8.1: the REQ census ADDITION — the round-trip proof, owner side --
  # docs/awkernel/specs/awk.6/awk.6.md §8.1 (the awk.4a D-5 bar, carried): a
  # census-active brand must survive encode → parse → RE-ENCODE BYTE-EQUAL. The
  # mirror-side assertion lives in go/awk/census (TestMintAcceptsActiveREQ) and
  # go/echo-core/internal/awkapp (TestVendoredCensus_REQActive); both sides pin
  # the ONE authority file priv/census.vectors, so a single-side edit reds the
  # stale side rather than passing silently.

  test "awk.6: the REQ row classifies {:platform, :request} and round-trips byte-equal" do
    snow = 274_557_032_793_636_864
    id = BrandedId.encode!("REQ", snow)

    assert byte_size(id) == 14
    assert BrandedId.valid?(id)

    # encode → parse → re-encode, byte-equal on the artifact.
    assert {:ok, "REQ", ^snow} = BrandedId.parse(id)
    assert BrandedId.encode!("REQ", snow) == id

    # The census governs the id by its 3-byte brand prefix.
    <<code::binary-size(3), _payload::binary>> = id
    assert code == "REQ"
    assert Namespace.classify(code) == {:platform, :request}
    assert Namespace.active?(code)
  end

  # -- awk.6 §8.2: the COR census FLIP — the round-trip proof, owner side ------
  # A SEPARATE test from the REQ one: an ADDITION and a FLIP are independent
  # fault classes, and each should be killed by exactly one named test.
  #
  # The discriminator that makes this load-bearing: COR was ALREADY a registered
  # row whose classify/1 resolved to {:platform, :correlation} before the flip
  # (only a :parked row folds to :reserved), so classify is UNCHANGED by Phase B
  # and the appendix example block at the top of this file still holds verbatim.
  # The only thing the flip moves is STATUS — which is what active?/1 keys on,
  # and what the mint gate on both Go sides keys on.

  test "awk.6: the COR row is census-active after the Phase B flip and round-trips byte-equal" do
    snow = 274_557_032_793_636_864
    id = BrandedId.encode!("COR", snow)

    assert byte_size(id) == 14
    assert BrandedId.valid?(id)

    assert {:ok, "COR", ^snow} = BrandedId.parse(id)
    assert BrandedId.encode!("COR", snow) == id

    <<code::binary-size(3), _payload::binary>> = id
    assert code == "COR"
    assert Namespace.active?(code)
    assert Namespace.status(code) == :active

    # classify is status-independent for a non-parked row — unchanged by the flip.
    assert Namespace.classify(code) == {:platform, :correlation}

    # LOG is the SOLE remaining reserved row; the flip must not carry it along.
    assert Namespace.status("LOG") == :reserved
    refute Namespace.active?("LOG")

    assert Enum.count(Namespace.all(), fn {_, _, _, _, s} -> s == :reserved end) == 1
  end

  # -- awk.1 R3a (AS2): the cross-language drift gate, owner side --------------
  # The committed vector file `priv/census.vectors` is the ONE authority both the
  # Elixir census and the vendored Go table pin to (docs/awkernel/specs/awk.1/
  # awk.1.md D3 · ADR-awk.1-1). This pin reconstructs the vector rows from the
  # PUBLIC census enumeration `Namespace.all/0` (no new census surface) and the
  # public `classify/1` projection — asserting the compiled census equals the
  # committed vectors byte-for-byte, raw statuses (parked stays distinct even
  # though classify/1 folds it to :reserved). An ABSENT file is a FAILURE, never
  # a skip; the row-count assertion (32) forbids a vacuous empty-vs-empty pass.

  @census_vectors_path Path.join([__DIR__, "..", "priv", "census.vectors"])

  defp census_rows_from_authority do
    EchoData.Namespace.all()
    |> Enum.map(fn {code, _space, _program, _semantics, status} ->
      tag =
        case EchoData.Namespace.classify(code) do
          {:platform, t} -> Atom.to_string(t)
          :reserved -> "reserved"
        end

      "#{code}\t#{status}\t#{tag}"
    end)
    |> Enum.sort()
  end

  test "awk.1: the compiled census equals the committed census.vectors (drift gate, owner side)" do
    assert File.exists?(@census_vectors_path),
           "census.vectors is absent — the drift gate FAILS loud, never skips"

    committed = File.read!(@census_vectors_path)
    derived = Enum.join(census_rows_from_authority(), "\n") <> "\n"

    # Liveness: the comparison must exercise the full census, never empty-vs-empty.
    assert length(census_rows_from_authority()) == 32,
           "expected 32 census rows (30 active + 1 reserved + 1 parked) post-awk.6 REQ addition + COR flip"

    assert committed == derived,
           "census drift: priv/census.vectors is stale vs EchoData.Namespace.all/0 — re-derive it"
  end

  # -- R4: the pinned seam — classified, not admitted --------------------------
  # Both assertions live in ONE test so a future wire change cannot flip one
  # without consciously editing the other (US4).

  test "R4: the developer space is classified while the wire still refuses it" do
    assert Namespace.classify("SHOP") == :developer
    assert BrandedId.parse("SHOP" <> "0KHTOWnGLuC") == :error
  end
end
