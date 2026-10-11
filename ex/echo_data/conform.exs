# conform.exs — the parity shim for echo_data (docs/contract.md, "Parity shim protocol").
#
# First stdout line: `HELLO ex <pure|nif> <ops>`; then one response line per request. All of
# stdin is read at once and all responses are written in one write. The shim answers from the
# library and cross-checks the library against itself: a D request goes through validate/1,
# parse/1, parse_hash/1 and valid?/1, an E request through validate_encode/2, encode/2 and a
# parse round trip. Any disagreement answers `ERR DISAGREE`, which never matches the oracle, and
# is described on stderr.
#
# Run from the repository root, after `make -C ex conform`:
#   ECHO_DATA_NATIVE=0 elixir -pa ex/echo_data/_build/prod/lib/echo_data/ebin ex/echo_data/conform.exs
# `ECHO_DATA_NATIVE=0` forces the pure path (shim ex-pure). Without it the NIF must be loaded, or
# the shim refuses to start (shim ex-nif): a silent fallback would prove the wrong code.

defmodule EchoData.Conform do
  import Bitwise
  alias EchoData.{BrandedId, Snowflake}

  @ops "EDHUFN"

  def main do
    variant = if EchoData.Native.loaded?(), do: "nif", else: "pure"

    if variant == "pure" and System.get_env("ECHO_DATA_NATIVE") != "0" do
      IO.puts(:stderr, "conform: the NIF is not loaded; set ECHO_DATA_NATIVE=0 for the pure shim")
      System.halt(2)
    end

    input = IO.binread(:stdio, :eof)
    input = if is_binary(input), do: input, else: ""

    lines =
      for line <- String.split(input, "\n", trim: true) do
        [answer(String.split(line, " ")), ?\n]
      end

    IO.binwrite(:stdio, ["HELLO ex ", variant, " ", @ops, ?\n | lines])
  end

  defp answer(["E", ns_hex, snow]), do: encode(unhex(ns_hex), String.to_integer(snow))
  defp answer(["D", id_hex]), do: decode(unhex(id_hex))
  defp answer(["H", k]), do: "OK #{BrandedId.hash32(String.to_integer(k))}"
  defp answer(["U", snow]), do: "OK #{Snowflake.unix_ms(String.to_integer(snow))}"

  defp answer(["F", snow]) do
    s = String.to_integer(snow)
    "OK #{s >>> 22} #{Snowflake.node_id(s)} #{Snowflake.sequence(s)}"
  end

  defp answer(["N", host_hex, pid]),
    do: "OK #{Snowflake.node_from(unhex(host_hex), String.to_integer(pid))}"

  defp answer(other), do: complain("unsupported request #{inspect(Enum.join(other, " "))}")

  defp encode(ns, snow) do
    case {BrandedId.validate_encode(ns, snow), BrandedId.encode(ns, snow)} do
      {:ok, {:ok, id}} ->
        if BrandedId.parse(id) == {:ok, ns, snow},
          do: "OK #{id}",
          else: complain("encode(#{inspect(ns)}, #{snow}) = #{inspect(id)} does not round-trip")

      {{:error, class}, :error} ->
        err(class)

      {verdict, result} ->
        complain("validate_encode -> #{inspect(verdict)} but encode -> #{inspect(result)}")
    end
  end

  defp decode(id) do
    verdict = BrandedId.validate(id)
    parsed = BrandedId.parse(id)

    cond do
      verdict == :ok and match?({:ok, _, _}, parsed) ->
        {:ok, ns, snow} = parsed

        cond do
          BrandedId.parse_hash(id) != {:ok, ns, snow, BrandedId.hash32(snow)} ->
            complain("parse_hash disagrees with parse for #{inspect(id)}")

          not BrandedId.valid?(id) ->
            complain("valid? disagrees with validate for #{inspect(id)}")

          true ->
            "OK #{ns} #{snow}"
        end

      match?({:error, _}, verdict) and parsed == :error and not BrandedId.valid?(id) ->
        {:error, class} = verdict
        err(class)

      true ->
        complain("validate -> #{inspect(verdict)} but parse -> #{inspect(parsed)}")
    end
  end

  defp err(class), do: "ERR " <> String.upcase(Atom.to_string(class))

  defp complain(what) do
    IO.puts(:stderr, "conform: " <> what)
    "ERR DISAGREE"
  end

  defp unhex("-"), do: ""
  defp unhex(hex), do: Base.decode16!(hex, case: :lower)
end

EchoData.Conform.main()
