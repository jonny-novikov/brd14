# verify.exs — production package verification, adapted to the echo umbrella.
# The modules are already compiled by the umbrella (no Code.require_file); run via
#   ASDF_ERLANG_VERSION=28.1 ASDF_ELIXIR_VERSION=1.18.4 mix run apps/echo_data/verify.exs
# Exercises both codec paths (native when the .so is present, pure otherwise).

alias EchoData.{BrandedChamp, BrandedId, BrandedMap, Snowflake}

defmodule V do
  def best_ms(times, fun) do
    runs = Enum.map(1..times, fn _ -> :timer.tc(fun) end)
    {us, res} = Enum.min_by(runs, &elem(&1, 0))
    {Float.round(us / 1000, 1), res}
  end

  def ns_per_op(n, fun) do
    {us, _} = :timer.tc(fun)
    Float.round(us * 1000 / n, 1)
  end
end

IO.puts("== 1. contract self-check (pure + native agreement) ==")
{:ok, mode} = BrandedId.self_check!()
IO.puts("self_check! -> codec=#{mode}  (native loaded: #{EchoData.Native.loaded?()})")

IO.puts(
  "encode!(USR, 274557032793636864) -> #{BrandedId.encode!("USR", 274_557_032_793_636_864)}"
)

IO.puts("parse(USR0NgWEfAEJfs)            -> #{inspect(BrandedId.parse("USR0NgWEfAEJfs"))}")
IO.puts("hash32(274557032793636864)       -> #{BrandedId.hash32(274_557_032_793_636_864)}")

IO.puts(
  "parse(USRzzzzzzzzzzz)            -> #{inspect(BrandedId.parse("USRzzzzzzzzzzz"))}  (range)"
)

IO.puts(
  "parse(usr0KHTOWnGLuC)            -> #{inspect(BrandedId.parse("usr0KHTOWnGLuC"))}  (namespace)"
)

IO.puts("\n== 2. snowflake generator ==")
# The umbrella's EchoData.Application already called Snowflake.start/0 at boot;
# start/1 is idempotent (a no-op once started), so this keeps the boot node.
:ok = Snowflake.start(7)
s1 = Snowflake.next()

IO.puts(
  "next() -> #{s1}  node_id=#{Snowflake.node_id(s1)}  branded=#{Snowflake.next_branded("EVT")}"
)

IO.puts("to_datetime -> #{Snowflake.to_datetime(s1)}  (now: #{DateTime.utc_now()})")

n_gen = 200_000

{ms, results} =
  V.best_ms(1, fn ->
    1..4
    |> Task.async_stream(
      fn _ -> Enum.map(1..div(n_gen, 4), fn _ -> Snowflake.next() end) end,
      max_concurrency: 4,
      ordered: false
    )
    |> Enum.flat_map(fn {:ok, ids} -> ids end)
  end)

unique = MapSet.size(MapSet.new(results))

IO.puts(
  "#{n_gen} ids across 4 concurrent tasks: unique=#{unique} (#{unique == n_gen}), " <>
    "#{Float.round(n_gen / ms * 1000 / 1.0e6, 2)} M ids/s"
)

rate = V.ns_per_op(100_000, fn -> Enum.each(1..100_000, fn _ -> Snowflake.next() end) end)
IO.puts("single-process mint: #{rate} ns/op")

IO.puts("\n== 3. CHAMP model check: 20k interleaved ops vs Map ==")
:rand.seed(:exsss, {7, 11, 13})
range = 4096

{model, champ} =
  Enum.reduce(1..20_000, {%{}, BrandedChamp.new()}, fn i, {model, champ} ->
    snow = 274_557_032_793_636_864 + :rand.uniform(range) * 4_194_304
    id = BrandedId.encode!("USR", snow)

    if rem(i, 5) == 4 do
      {Map.delete(model, id), BrandedChamp.delete(champ, id)}
    else
      {Map.put(model, id, i), BrandedChamp.put!(champ, id, i)}
    end
  end)

agree =
  Enum.all?(model, fn {id, v} -> BrandedChamp.fetch(champ, id) == {:ok, v} end) and
    BrandedChamp.size(champ) == map_size(model) and
    Enum.sort(BrandedChamp.to_list(champ)) == Enum.sort(Map.to_list(model))

IO.puts(
  "sizes: champ=#{BrandedChamp.size(champ)} model=#{map_size(model)}  full agreement: #{agree}"
)

IO.puts("\n== 4. forced collision path (two snowflakes, one 32-bit hash) ==")

{a, b} =
  Stream.iterate(0x6A09E667F3BCC909, fn s ->
    import Bitwise
    s = bxor(s, bsl(s, 13) |> band(0xFFFFFFFFFFFFFFFF))
    s = bxor(s, bsr(s, 7))
    bxor(s, bsl(s, 17) |> band(0xFFFFFFFFFFFFFFFF))
  end)
  |> Stream.map(&Bitwise.band(&1, 0x7FFFFFFFFFFFFFFF))
  |> Enum.reduce_while(%{}, fn k, seen ->
    h = BrandedId.hash32(k)

    case seen do
      %{^h => prev} when prev != k -> {:halt, {prev, k}}
      _ -> {:cont, Map.put(seen, h, k)}
    end
  end)

IO.puts("hash32(#{a}) == hash32(#{b}): #{BrandedId.hash32(a) == BrandedId.hash32(b)}")

cc =
  BrandedChamp.new()
  |> BrandedChamp.put_by_snowflake("CRS", a, :a)
  |> BrandedChamp.put_by_snowflake("CRS", b, :b)

cc2 = BrandedChamp.delete_by_snowflake(cc, "CRS", a)

IO.puts(
  "both stored: #{BrandedChamp.fetch_by_snowflake(cc, "CRS", a) == {:ok, :a} and BrandedChamp.fetch_by_snowflake(cc, "CRS", b) == {:ok, :b}}, " <>
    "after delete: a=#{inspect(BrandedChamp.fetch_by_snowflake(cc2, "CRS", a))} b=#{inspect(BrandedChamp.fetch_by_snowflake(cc2, "CRS", b))}"
)

IO.puts("\n== 5. structures at 100k (ns/op best of 5; ms best of 3) ==")
ref = 274_557_032_793_636_864
n = 100_000
snows = Enum.map(0..(n - 1), fn i -> ref + i * 4_194_304 end)
big = Enum.reduce(snows, BrandedChamp.new(), &BrandedChamp.put_by_snowflake(&2, "USR", &1, :ok))
bmap = Enum.reduce(snows, BrandedMap.new(), &BrandedMap.put_by_snowflake(&2, "USR", &1, :ok))
shuffled = Enum.shuffle(snows)
branded = Enum.map(shuffled, &BrandedId.encode!("USR", &1))
best5 = fn fun -> Enum.min(Enum.map(1..5, fn _ -> V.ns_per_op(n, fun) end)) end

IO.puts(
  "BrandedChamp.fetch (branded)        : #{best5.(fn -> Enum.each(branded, &BrandedChamp.fetch(big, &1)) end)} ns/op"
)

IO.puts(
  "BrandedChamp.fetch_by_snowflake     : #{best5.(fn -> Enum.each(shuffled, &BrandedChamp.fetch_by_snowflake(big, "USR", &1)) end)} ns/op"
)

IO.puts(
  "BrandedMap.fetch (branded)          : #{best5.(fn -> Enum.each(branded, &BrandedMap.fetch(bmap, &1)) end)} ns/op"
)

{ms, l} = V.best_ms(3, fn -> BrandedChamp.to_list(big) end)

IO.puts(
  "BrandedChamp.to_list                : #{ms} ms (#{length(l)} pairs; linear accumulate + reverse)"
)

{ms, l2} = V.best_ms(3, fn -> BrandedChamp.to_snowflake_list(big) end)
IO.puts("BrandedChamp.to_snowflake_list      : #{ms} ms (#{length(l2)})")
{ms, c} = V.best_ms(3, fn -> Enum.reduce(big, 0, fn _, acc -> acc + 1 end) end)
IO.puts("BrandedChamp streaming Enumerable   : #{ms} ms (count=#{c})")
{ms, c2} = V.best_ms(3, fn -> Enum.reduce(bmap, 0, fn _, acc -> acc + 1 end) end)
IO.puts("BrandedMap streaming Enumerable     : #{ms} ms (count=#{c2})")
halted = Enum.take(big, 3)
IO.puts("Enumerable halt (Enum.take/2 of 3)  : #{length(halted)} items, no full pass")
