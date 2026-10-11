defmodule EchoData.ChampNode do
  @moduledoc """
  CHAMP node (Compressed Hash-Array Mapped Prefix-tree), final form.

  Two 32-bit bitmaps per node — `datamap` marks inline `{key, value}` pairs,
  `nodemap` marks children — over a compact tuple `{k1, v1, …, child1, …}`:
  pairs interleaved at the front, children after, both indexed by popcount of
  the bitmap prefix. 5-bit fragments of the 32-bit contract hash give 32-way
  branching across levels 0..6; at depth 7 the hash is exhausted and entries
  fall into a `{:collision, pairs}` list. Deletion maintains canonical form:
  a child reduced to a single pair collapses back inline.

  Differences from the original implementation, per the audit:

    * the hash has one source — `EchoData.BrandedId.hash32/1`; this module
      computes it only on the put-collision path and never defines its own;
    * tuple edits use `:erlang.insert_element/3` and `:erlang.delete_element/2`
      instead of tuple→list→tuple round-trips;
    * `to_list/1` accumulates by prepending and reverses once — linear, where
      `++` accumulation was quadratic at scale;
    * `iterator/1` + `next/1` provide a suspendable traversal, so enumeration
      streams without materializing the structure.
  """

  import Bitwise

  alias EchoData.BrandedId

  @type key :: non_neg_integer()
  @type value :: any()
  @type hash :: non_neg_integer()

  @type t :: %__MODULE__{datamap: non_neg_integer(), nodemap: non_neg_integer(), content: tuple()}

  defstruct datamap: 0, nodemap: 0, content: {}

  @hash_bits 5
  @hash_mask (1 <<< @hash_bits) - 1
  @max_level 7

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec singleton(key(), value(), hash(), non_neg_integer()) :: t()
  def singleton(key, value, hash, level) do
    %__MODULE__{datamap: 1 <<< fragment(hash, level), nodemap: 0, content: {key, value}}
  end

  # ---- fetch -----------------------------------------------------------------

  @spec fetch(t(), key(), hash(), non_neg_integer()) :: {:ok, value()} | :error
  def fetch(%__MODULE__{datamap: 0, nodemap: 0, content: content}, key, _hash, _level) do
    case content do
      {{:collision, pairs}} ->
        case List.keyfind(pairs, key, 0) do
          {^key, value} -> {:ok, value}
          nil -> :error
        end

      {} ->
        :error
    end
  end

  def fetch(%__MODULE__{datamap: datamap, nodemap: nodemap, content: content}, key, hash, level) do
    bit = 1 <<< fragment(hash, level)

    cond do
      (datamap &&& bit) != 0 ->
        idx = data_index(datamap, bit)

        if elem(content, idx * 2) == key do
          {:ok, elem(content, idx * 2 + 1)}
        else
          :error
        end

      (nodemap &&& bit) != 0 ->
        fetch(elem(content, node_index(datamap, nodemap, bit)), key, hash, level + 1)

      true ->
        :error
    end
  end

  # ---- put -------------------------------------------------------------------

  @spec put(t(), key(), value(), hash(), non_neg_integer()) :: t()
  def put(
        %__MODULE__{datamap: 0, nodemap: 0, content: {{:collision, pairs}}},
        key,
        value,
        _hash,
        _level
      ) do
    new_pairs =
      case List.keyfind(pairs, key, 0) do
        nil -> [{key, value} | pairs]
        _ -> List.keyreplace(pairs, key, 0, {key, value})
      end

    %__MODULE__{datamap: 0, nodemap: 0, content: {{:collision, new_pairs}}}
  end

  def put(
        %__MODULE__{datamap: datamap, nodemap: nodemap, content: content} = node,
        key,
        value,
        hash,
        level
      ) do
    bit = 1 <<< fragment(hash, level)

    cond do
      (datamap &&& bit) == 0 and (nodemap &&& bit) == 0 ->
        idx = data_index(datamap, bit)

        c1 = :erlang.insert_element(idx * 2 + 1, content, key)
        new_content = :erlang.insert_element(idx * 2 + 2, c1, value)

        %__MODULE__{node | datamap: datamap ||| bit, content: new_content}

      (datamap &&& bit) != 0 ->
        idx = data_index(datamap, bit)
        stored_key = elem(content, idx * 2)

        if stored_key == key do
          %__MODULE__{node | content: put_elem(content, idx * 2 + 1, value)}
        else
          stored_value = elem(content, idx * 2 + 1)
          stored_hash = BrandedId.hash32(stored_key)

          child =
            merge_into_node(stored_key, stored_value, stored_hash, key, value, hash, level + 1)

          new_datamap = bxor(datamap, bit)
          new_nodemap = nodemap ||| bit
          child_pos = popcount(new_datamap) * 2 + popcount(nodemap &&& bit - 1)

          c1 = :erlang.delete_element(idx * 2 + 1, content)
          c2 = :erlang.delete_element(idx * 2 + 1, c1)
          new_content = :erlang.insert_element(child_pos + 1, c2, child)

          %__MODULE__{node | datamap: new_datamap, nodemap: new_nodemap, content: new_content}
        end

      true ->
        child_idx = node_index(datamap, nodemap, bit)
        new_child = put(elem(content, child_idx), key, value, hash, level + 1)
        %__MODULE__{node | content: put_elem(content, child_idx, new_child)}
    end
  end

  # ---- delete (canonical form maintained) -------------------------------------

  @spec delete(t(), key(), hash(), non_neg_integer()) :: t()
  def delete(
        %__MODULE__{datamap: 0, nodemap: 0, content: {{:collision, pairs}}} = node,
        key,
        _hash,
        _level
      ) do
    case List.keydelete(pairs, key, 0) do
      ^pairs -> node
      [] -> %__MODULE__{}
      remaining -> %__MODULE__{datamap: 0, nodemap: 0, content: {{:collision, remaining}}}
    end
  end

  def delete(
        %__MODULE__{datamap: datamap, nodemap: nodemap, content: content} = node,
        key,
        hash,
        level
      ) do
    bit = 1 <<< fragment(hash, level)

    cond do
      (datamap &&& bit) != 0 ->
        idx = data_index(datamap, bit)

        if elem(content, idx * 2) == key do
          c1 = :erlang.delete_element(idx * 2 + 1, content)
          new_content = :erlang.delete_element(idx * 2 + 1, c1)

          %__MODULE__{node | datamap: bxor(datamap, bit), content: new_content}
        else
          node
        end

      (nodemap &&& bit) != 0 ->
        child_idx = node_index(datamap, nodemap, bit)
        new_child = delete(elem(content, child_idx), key, hash, level + 1)

        case collapse_if_needed(new_child) do
          {:collapse, k, v} ->
            di = data_index(datamap, bit)
            c1 = :erlang.delete_element(child_idx + 1, content)
            c2 = :erlang.insert_element(di * 2 + 1, c1, k)
            new_content = :erlang.insert_element(di * 2 + 2, c2, v)

            %__MODULE__{
              node
              | datamap: datamap ||| bit,
                nodemap: bxor(nodemap, bit),
                content: new_content
            }

          :keep ->
            %__MODULE__{node | content: put_elem(content, child_idx, new_child)}
        end

      true ->
        node
    end
  end

  # ---- traversal ---------------------------------------------------------------

  @doc "Linear `to_list`: prepend-accumulate, reverse once. Hash order, not key order."
  @spec to_list(t()) :: [{key(), value()}]
  def to_list(node), do: node |> reduce([], fn pair, acc -> [pair | acc] end) |> :lists.reverse()

  @doc "Eager fold over all entries, in trie order."
  def reduce(%__MODULE__{datamap: 0, nodemap: 0, content: content}, acc, fun) do
    case content do
      {{:collision, pairs}} -> Enum.reduce(pairs, acc, fun)
      {} -> acc
    end
  end

  def reduce(%__MODULE__{datamap: datamap, nodemap: nodemap, content: content}, acc, fun) do
    data_count = popcount(datamap)
    node_count = popcount(nodemap)

    acc =
      Enum.reduce(0..(data_count - 1)//1, acc, fn i, a ->
        fun.({elem(content, i * 2), elem(content, i * 2 + 1)}, a)
      end)

    Enum.reduce(0..(node_count - 1)//1, acc, fn i, a ->
      reduce(elem(content, data_count * 2 + i), a, fun)
    end)
  end

  @doc "Suspendable iterator: `iterator/1` then `next/1` → `{key, value, iter} | :done`."
  def iterator(%__MODULE__{} = node), do: [{node, 0, 0}]

  def next([]), do: :done

  def next([{%__MODULE__{datamap: 0, nodemap: 0, content: content}, ei, _ci} | rest]) do
    case content do
      {{:collision, pairs}} ->
        case Enum.at(pairs, ei) do
          {k, v} ->
            {k, v, [{%__MODULE__{datamap: 0, nodemap: 0, content: content}, ei + 1, 0} | rest]}

          nil ->
            next(rest)
        end

      {} ->
        next(rest)
    end
  end

  def next([
        {%__MODULE__{datamap: datamap, nodemap: nodemap, content: content} = n, ei, ci} | rest
      ]) do
    data_count = popcount(datamap)

    cond do
      ei < data_count ->
        {elem(content, ei * 2), elem(content, ei * 2 + 1), [{n, ei + 1, ci} | rest]}

      ci < popcount(nodemap) ->
        child = elem(content, data_count * 2 + ci)
        next([{child, 0, 0}, {n, ei, ci + 1} | rest])

      true ->
        next(rest)
    end
  end

  @spec size(t()) :: non_neg_integer()
  def size(node), do: reduce(node, 0, fn _, n -> n + 1 end)

  # ---- internals ----------------------------------------------------------------

  defp fragment(hash, level), do: hash >>> (@hash_bits * level) &&& @hash_mask

  defp data_index(datamap, bit), do: popcount(datamap &&& bit - 1)

  defp node_index(datamap, nodemap, bit) do
    popcount(datamap) * 2 + popcount(nodemap &&& bit - 1)
  end

  defp popcount(n), do: do_popcount(n, 0)
  defp do_popcount(0, acc), do: acc
  defp do_popcount(n, acc), do: do_popcount(n &&& n - 1, acc + 1)

  defp merge_into_node(key1, value1, hash1, key2, value2, hash2, level) when level < @max_level do
    frag1 = fragment(hash1, level)
    frag2 = fragment(hash2, level)

    if frag1 == frag2 do
      child = merge_into_node(key1, value1, hash1, key2, value2, hash2, level + 1)
      %__MODULE__{datamap: 0, nodemap: 1 <<< frag1, content: {child}}
    else
      if frag1 < frag2 do
        %__MODULE__{
          datamap: 1 <<< frag1 ||| 1 <<< frag2,
          nodemap: 0,
          content: {key1, value1, key2, value2}
        }
      else
        %__MODULE__{
          datamap: 1 <<< frag1 ||| 1 <<< frag2,
          nodemap: 0,
          content: {key2, value2, key1, value1}
        }
      end
    end
  end

  defp merge_into_node(key1, value1, _h1, key2, value2, _h2, _level) do
    %__MODULE__{datamap: 0, nodemap: 0, content: {{:collision, [{key1, value1}, {key2, value2}]}}}
  end

  defp collapse_if_needed(%__MODULE__{datamap: 0, nodemap: 0, content: {{:collision, [{k, v}]}}}),
    do: {:collapse, k, v}

  defp collapse_if_needed(%__MODULE__{datamap: datamap, nodemap: 0, content: content}) do
    if popcount(datamap) == 1 do
      {:collapse, elem(content, 0), elem(content, 1)}
    else
      :keep
    end
  end

  defp collapse_if_needed(_node), do: :keep
end
