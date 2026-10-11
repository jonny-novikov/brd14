defmodule EchoData.NativeChamp do
  @moduledoc """
  The branded champ held off the process heap: a `brd14_data::Champ` (Rust) behind a NIF
  resource, shape-identical to `EchoData.BrandedChamp` — the same operations in the same order
  build the same trie, so the same `shape_digest/2` and the same iteration order.

  Value semantics, like a map: every write returns a new `%NativeChamp{}` and the old one stays
  valid, the trie shared between versions. What the BEAM gains:

    * a large champ costs the owning process a reference, not heap — garbage collection never
      copies or scans it;
    * sending it to another process copies the reference, not the entries;
    * values are stored as external term format, so any term goes in and an equal term comes out.

  What it costs: a value is encoded on `put` and decoded on `fetch`, so point reads of large
  values are slower than `BrandedChamp`'s. Measure before choosing (docs/benchmarks.md); the
  default map remains `EchoData.BrandedMap`.

  Requires the NIF (`EchoData.Native.loaded?/0`); without it every call raises.
  """

  alias EchoData.Native

  @enforce_keys [:ref]
  defstruct [:ref]

  @type t :: %__MODULE__{ref: reference()}

  @doc "True when the NIF is loaded and this module can be used."
  def available?, do: Native.loaded?()

  @spec new() :: t()
  def new, do: %__MODULE__{ref: Native.champ_new()}

  @doc "From `{branded_id, value}` pairs; raises `ArgumentError` on an invalid id."
  def new(entries) when is_list(entries),
    do: Enum.reduce(entries, new(), fn {id, v}, c -> put!(c, id, v) end)

  @doc "Puts by branded id; raises `ArgumentError` naming the contract class on an invalid id."
  @spec put!(t(), binary(), term()) :: t()
  def put!(%__MODULE__{ref: ref}, id, value) when is_binary(id) do
    case Native.champ_put(ref, id, value) do
      {:ok, next} -> %__MODULE__{ref: next}
      {:error, class} -> raise ArgumentError, "invalid branded id (#{class}): #{inspect(id)}"
    end
  end

  def put(c, id, value), do: put!(c, id, value)

  @spec put_by_snowflake(t(), binary(), non_neg_integer(), term()) :: t()
  def put_by_snowflake(%__MODULE__{ref: ref}, ns, snow, value)
      when is_binary(ns) and is_integer(snow) and snow >= 0 do
    case Native.champ_put_snow(ref, ns, snow, value) do
      {:ok, next} ->
        %__MODULE__{ref: next}

      {:error, class} ->
        raise ArgumentError, "invalid namespace or snowflake (#{class}): #{inspect({ns, snow})}"
    end
  end

  @doc "`{:ok, value}` or `:error` — an invalid id reads as absent."
  @spec fetch(t(), term()) :: {:ok, term()} | :error
  def fetch(%__MODULE__{ref: ref}, id) when is_binary(id), do: Native.champ_get(ref, id)
  def fetch(%__MODULE__{}, _id), do: :error

  def get(c, id, default \\ nil) do
    case fetch(c, id) do
      {:ok, v} -> v
      :error -> default
    end
  end

  def fetch_by_snowflake(%__MODULE__{ref: ref}, ns, snow)
      when is_binary(ns) and is_integer(snow) and snow >= 0 and snow < 0x10000000000000000,
      do: Native.champ_get_snow(ref, ns, snow)

  def fetch_by_snowflake(%__MODULE__{}, _ns, _snow), do: :error

  @doc "Deletes by branded id; raises `ArgumentError` on an invalid id (writes are loud)."
  @spec delete(t(), binary()) :: t()
  def delete(%__MODULE__{ref: ref}, id) when is_binary(id) do
    case Native.champ_delete(ref, id) do
      {:ok, next} -> %__MODULE__{ref: next}
      {:error, class} -> raise ArgumentError, "invalid branded id (#{class}): #{inspect(id)}"
    end
  end

  def delete_by_snowflake(%__MODULE__{ref: ref}, ns, snow)
      when is_binary(ns) and is_integer(snow) and snow >= 0,
      do: %__MODULE__{ref: Native.champ_delete_snow(ref, ns, snow)}

  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{ref: ref}), do: Native.champ_size(ref)

  @spec namespace_size(t(), binary()) :: non_neg_integer()
  def namespace_size(%__MODULE__{ref: ref}, ns) when is_binary(ns),
    do: Native.champ_namespace_size(ref, ns)

  @doc "Namespaces in ascending byte order."
  def namespaces(%__MODULE__{ref: ref}), do: Native.champ_namespaces(ref)

  @doc "The shape digest of one namespace's trie (docs/structures/spec.md)."
  @spec shape_digest(t(), binary()) :: non_neg_integer()
  def shape_digest(%__MODULE__{ref: ref}, ns), do: Native.champ_digest(ref, ns)

  @doc "`[{ns, snowflake, value}]`: namespaces ascending, each trie in traversal order."
  def to_snowflake_list(%__MODULE__{ref: ref}), do: Native.champ_to_list(ref)

  def to_list(c),
    do: for({ns, snow, v} <- to_snowflake_list(c), do: {EchoData.BrandedId.encode!(ns, snow), v})

  @doc "Copies a `BrandedChamp` (or any `{ns, snow, value}` enumerable) off-heap."
  def from_champ(entries) do
    case Native.champ_from_list(Enum.to_list(entries)) do
      {:ok, ref} -> %__MODULE__{ref: ref}
      {:error, class} -> raise ArgumentError, "invalid entry (#{class})"
    end
  end
end

defimpl Enumerable, for: EchoData.NativeChamp do
  # Streams {ns, snowflake, value}; the list is built by one dirty NIF call.
  def count(c), do: {:ok, EchoData.NativeChamp.size(c)}

  def member?(c, {ns, snow, value}) do
    {:ok, EchoData.NativeChamp.fetch_by_snowflake(c, ns, snow) == {:ok, value}}
  end

  def member?(_c, _), do: {:ok, false}
  def slice(_c), do: {:error, __MODULE__}

  def reduce(c, acc, fun),
    do: Enumerable.List.reduce(EchoData.NativeChamp.to_snowflake_list(c), acc, fun)
end

defimpl Inspect, for: EchoData.NativeChamp do
  def inspect(c, _opts) do
    if EchoData.NativeChamp.available?() do
      "#NativeChamp<size: #{EchoData.NativeChamp.size(c)}, namespaces: #{inspect(EchoData.NativeChamp.namespaces(c))}>"
    else
      "#NativeChamp<unloaded>"
    end
  end
end
