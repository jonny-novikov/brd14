defmodule EchoData.LayoutTest do
  use ExUnit.Case, async: true
  import Bitwise

  alias EchoData.{Layout, Snowflake}

  doctest EchoData.Layout

  @dir Path.expand("../../../vectors", __DIR__)

  defp rows(name) do
    Path.join(@dir, name)
    |> File.stream!()
    |> Stream.map(&String.trim_trailing(&1, "\n"))
    |> Stream.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(&String.split(&1, "\t"))
  end

  defp ints(list), do: Enum.map(list, &String.to_integer/1)

  test "the base profile is the base layout, bit for bit" do
    for snow <- [0, 274_557_032_793_636_864, 320_636_799_581_945_856, 9_223_372_036_854_775_807] do
      assert {:ok, {ts, node, seq, 0}} = Layout.fields(Layout.std(), snow)
      assert {ts, node, seq} == {snow >>> 22, Snowflake.node_id(snow), Snowflake.sequence(snow)}
    end
  end

  test "one generator stays strictly increasing whatever meta each id carries" do
    {:ok, layout} = Layout.new(6, 12, 4)
    clock = :counters.new(1, [])
    # The clock advances one millisecond per 9000 mints: bursts past 4096/ms borrow into ts.
    tick = fn ->
      :counters.add(clock, 1, 1)
      1_769_526_697_641 + div(:counters.get(clock, 1), 9000)
    end

    {:ok, gen} = Layout.generator(layout, 33, clock: tick)
    :rand.seed(:exsss, {1, 2, 3})

    snows =
      for _ <- 1..20_000 do
        meta = :rand.uniform(16) - 1
        {:ok, snow} = Layout.next(gen, meta)
        assert {:ok, {_, 33, _, ^meta}} = Layout.fields(layout, snow)
        snow
      end

    assert snows == Enum.sort(snows) and length(Enum.uniq(snows)) == 20_000
    assert Layout.next(gen, 16) == {:error, :range}
    assert Layout.generator(layout, 64) == {:error, :range}
  end

  if File.dir?(@dir) do
    test "layout.tsv: fields and pack invert each other for every valid profile" do
      for [n, s, m, snow, ts, node, seq, meta] <- rows("layout.tsv") do
        [n, s, m, snow, ts, node, seq, meta] = ints([n, s, m, snow, ts, node, seq, meta])
        {:ok, layout} = Layout.new(n, s, m)
        assert Layout.fields(layout, snow) == {:ok, {ts, node, seq, meta}}
        assert Layout.pack(layout, ts, node, seq, meta) == {:ok, snow}
      end
    end

    test "layout_invalid.tsv: LAYOUT before RANGE" do
      for [op, n, s, m, args, class] <- rows("layout_invalid.tsv") do
        args = args |> String.split(",") |> ints()
        want = {:error, class |> String.downcase() |> String.to_existing_atom()}

        got =
          with {:ok, layout} <-
                 Layout.new(String.to_integer(n), String.to_integer(s), String.to_integer(m)) do
            case {op, args} do
              {"L", [snow]} -> Layout.fields(layout, snow)
              {"P", [ts, node, seq, meta]} -> Layout.pack(layout, ts, node, seq, meta)
            end
          end

        assert got == want, "#{op} #{n} #{s} #{m} #{inspect(args)}"
      end
    end
  end
end
