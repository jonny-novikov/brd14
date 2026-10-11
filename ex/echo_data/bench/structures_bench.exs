# structures_bench.exs — the branded structures against their plain baselines (bench/README.md).
#
#   cd ex/echo_data && TMPDIR=/tmp MIX_ENV=prod mix run bench/structures_bench.exs [--quick]
#
# Writes ../../bench/results/structures/elixir-<variant>-otp-<otp>.json (variant: nif when the NIF
# is loaded, else pure). Corpus: vectors/valid.tsv rows 1..4096. Each op is sampled >= 10 times,
# each sample >= 50 ms (--quick: 3 samples, 10 ms — a smoke run, never committed); ns_per_op is
# the median sample, mad_ns its median absolute deviation, cv = stdev / mean.

alias EchoData.{BrandedChamp, BrandedId, BrandedMap, BrandedTree, Buckets, NativeChamp}

defmodule Bench do
  def measure(name, ops_per_call, fun, opts) do
    {samples, min_ms} = if opts[:quick], do: {3, 10}, else: {10, 50}
    for _ <- 1..3, do: fun.()
    # calls per sample so that one sample lasts at least min_ms
    {us, _} = :timer.tc(fun)
    calls = max(1, ceil(min_ms * 1000 / max(us, 1)))

    times =
      for _ <- 1..samples do
        {us, _} = :timer.tc(fn -> for _ <- 1..calls, do: fun.() end)
        us * 1000 / (calls * ops_per_call)
      end

    sorted = Enum.sort(times)
    median = Enum.at(sorted, div(samples, 2))
    mad = times |> Enum.map(&abs(&1 - median)) |> Enum.sort() |> Enum.at(div(samples, 2))
    mean = Enum.sum(times) / samples
    sd = :math.sqrt(Enum.sum(Enum.map(times, &((&1 - mean) ** 2))) / samples)

    line = :io_lib.format("~10.1f ns/op  (cv ~.3f)", [median, sd / mean])
    IO.puts(String.pad_trailing(name, 46) <> IO.iodata_to_binary(line))

    %{
      op: name,
      ns_per_op: Float.round(median, 2),
      mad_ns: Float.round(mad, 2),
      samples: samples,
      cv: Float.round(sd / mean, 4)
    }
  end
end

# Elixir 1.14 has no JSON module and the library takes no dependencies: a minimal encoder for
# the result schema (maps, lists, strings, numbers, booleans).
defmodule BenchJSON do
  def encode(m) when is_map(m) do
    body = m |> Enum.sort() |> Enum.map(fn {k, v} -> encode(to_string(k)) <> ":" <> encode(v) end)
    "{" <> Enum.join(body, ",") <> "}"
  end

  def encode(l) when is_list(l), do: "[" <> Enum.map_join(l, ",", &encode/1) <> "]"
  def encode(b) when is_boolean(b), do: to_string(b)
  def encode(n) when is_number(n), do: to_string(n)
  def encode(s) when is_binary(s), do: inspect(s, printable_limit: :infinity)
end

quick = "--quick" in System.argv()
opts = [quick: quick]
root = Path.expand("../../..", __DIR__)

rows =
  Path.join(root, "vectors/valid.tsv")
  |> File.stream!()
  |> Stream.reject(&String.starts_with?(&1, "#"))
  |> Enum.take(4096)
  |> Enum.map(fn line ->
    [ns, snow, id | _] = String.split(String.trim_trailing(line, "\n"), "\t")
    {ns, String.to_integer(snow), id}
  end)

n = length(rows)
ids = Enum.map(rows, &elem(&1, 2))
pairs = for {_ns, _s, id} <- rows, do: {id, id}
nif = NativeChamp.available?()

IO.puts(
  "echo_data structures bench: #{n} ids, NIF #{if nif, do: "loaded", else: "absent"}#{if quick, do: " (quick)"}"
)

plain = Map.new(pairs)
bmap = BrandedMap.new(pairs)
champ = BrandedChamp.new(pairs)
native = if nif, do: NativeChamp.new(pairs)
lookup = fn get -> fn -> Enum.each(ids, get) end end

results =
  [
    Bench.measure("get map[id] (baseline)", n, lookup.(&Map.get(plain, &1)), opts),
    Bench.measure("get BrandedMap", n, lookup.(&BrandedMap.fetch(bmap, &1)), opts),
    Bench.measure("get BrandedChamp", n, lookup.(&BrandedChamp.fetch(champ, &1)), opts)
  ] ++
    if(nif,
      do: [Bench.measure("get NativeChamp", n, lookup.(&NativeChamp.fetch(native, &1)), opts)],
      else: []
    ) ++
    [
      Bench.measure(
        "put map (baseline)",
        n,
        fn -> Enum.reduce(pairs, %{}, fn {k, v}, m -> Map.put(m, k, v) end) end,
        opts
      ),
      Bench.measure(
        "put BrandedChamp",
        n,
        fn ->
          Enum.reduce(pairs, BrandedChamp.new(), fn {k, v}, c -> BrandedChamp.put!(c, k, v) end)
        end,
        opts
      )
    ] ++
    if(nif,
      do: [
        Bench.measure(
          "put NativeChamp",
          n,
          fn ->
            Enum.reduce(pairs, NativeChamp.new(), fn {k, v}, c -> NativeChamp.put!(c, k, v) end)
          end,
          opts
        )
      ],
      else: []
    )

# Ordered paging: 50 after a cursor in one namespace (the corpus snowflakes, all as ORD ids —
# a feed), tree vs sort-then-take over a map keyed by id.
page_ns = "ORD"
page_rows = for {_, s, _} <- rows, do: {page_ns, s, BrandedId.encode!(page_ns, s)}

tree =
  Enum.reduce(page_rows, BrandedTree.new(), fn {ns, s, id}, t ->
    BrandedTree.put_by_snowflake(t, ns, s, id)
  end)

cursor = page_rows |> Enum.map(&elem(&1, 2)) |> Enum.sort() |> Enum.at(div(length(page_rows), 2))
ns_map = Map.new(for {_, _, id} <- page_rows, do: {id, id})

results =
  results ++
    [
      Bench.measure(
        "page 50 after cursor: sort map (baseline)",
        1,
        fn ->
          ns_map |> Map.keys() |> Enum.sort() |> Enum.drop_while(&(&1 <= cursor)) |> Enum.take(50)
        end,
        opts
      ),
      Bench.measure(
        "page 50 after cursor: BrandedTree",
        1,
        fn -> BrandedTree.page_after(tree, page_ns, cursor, 50) end,
        opts
      )
    ]

# Expiry: drop everything minted before the median instant.
snows = Enum.map(rows, &elem(&1, 1)) |> Enum.sort()
cut_snow = Enum.at(snows, div(n, 2))
cut = DateTime.from_unix!(EchoData.Snowflake.unix_ms(cut_snow), :millisecond)
cut_ms = EchoData.Snowflake.unix_ms(cut_snow)

buckets =
  Enum.reduce(rows, Buckets.new(bucket_bits: 16), fn {_, s, id}, b ->
    Buckets.put_by_snowflake(b, s, id)
  end)

expiring = Map.new(for {_, s, id} <- rows, do: {s, {EchoData.Snowflake.unix_ms(s), id}})

results =
  results ++
    [
      Bench.measure(
        "expire half: Map.filter expires_at (baseline)",
        1,
        fn -> Map.filter(expiring, fn {_, {ms, _}} -> ms >= cut_ms end) end,
        opts
      ),
      Bench.measure(
        "expire half: Buckets",
        1,
        fn -> Buckets.expire_older_than(buckets, cut) end,
        opts
      )
    ]

# Hand a 100k-entry champ to another process and back: heap copy vs a resource reference.
big = for i <- 1..100_000, do: {BrandedId.encode!("BIG", i * 104_729), i}
big_champ = BrandedChamp.new(big)

handoff = fn term ->
  fn ->
    parent = self()
    pid = spawn(fn -> receive do: ({:take, t} -> send(parent, {:size, Enum.count(t)})) end)
    send(pid, {:take, term})
    receive do: ({:size, _} -> :ok)
  end
end

results =
  results ++
    [Bench.measure("hand 100k champ to a process: BrandedChamp", 1, handoff.(big_champ), opts)] ++
    if(nif,
      do: [
        Bench.measure(
          "hand 100k champ to a process: NativeChamp",
          1,
          handoff.(NativeChamp.new(big)),
          opts
        )
      ],
      else: []
    )

unless quick do
  otp = System.otp_release()
  variant = if nif, do: "nif", else: "pure"
  dir = Path.join(root, "bench/results/structures")
  File.mkdir_p!(dir)

  machine =
    case System.cmd("sh", ["-c", "lscpu | sed -n 's/^Model name: *//p'"]) do
      {m, 0} -> String.trim(m)
      _ -> "unknown"
    end

  doc = %{
    impl: "elixir",
    variant: variant,
    runtime: "otp-#{otp}-elixir-#{System.version()}",
    machine: machine,
    pinned: System.get_env("BRD14_PINNED") == "1",
    corpus: "vectors/valid.tsv rows 1..#{n}; handoff: 100000 ids",
    results: results
  }

  path = Path.join(dir, "elixir-#{variant}-otp-#{otp}.json")
  File.write!(path, BenchJSON.encode(doc) <> "\n")
  IO.puts("wrote #{Path.relative_to(path, root)}")
end
