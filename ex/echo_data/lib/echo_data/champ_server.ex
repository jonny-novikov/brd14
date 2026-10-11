defmodule EchoData.ChampServer do
  @moduledoc """
  GenServer wrapper for `EchoData.BrandedChamp` providing stateful access.

  This module wraps a `BrandedChamp` in a GenServer process for cases where
  you need centralized state management, named process access, or want to
  add features like persistence or expiration. Re-homed atop the unified,
  audited `BrandedChamp` (the hash single-sourced through `BrandedId.hash32`);
  the GenServer API is unchanged.

  ## Usage

      # Start a named server
      {:ok, _pid} = ChampServer.start_link(name: :players)

      # Or start with initial data
      {:ok, _pid} = ChampServer.start_link(
        name: :rooms,
        initial: [{"ROM3QR5T7V9W2X4", %{code: "XYZZY"}}]
      )

      # Operations
      ChampServer.put(:players, "PLR7FXC4K8M9N2P", %{name: "Alice"})
      {:ok, player} = ChampServer.fetch(:players, "PLR7FXC4K8M9N2P")
      player = ChampServer.get(:players, "PLR7FXC4K8M9N2P")
      ChampServer.delete(:players, "PLR7FXC4K8M9N2P")

      # Bulk operations
      players = ChampServer.get_namespace(:players, "PLR")
      count = ChampServer.size(:players)
      all = ChampServer.to_list(:players)

  ## Supervision

  Add to your supervision tree:

      children = [
        {EchoData.ChampServer, name: :players},
        {EchoData.ChampServer, name: :rooms, initial: initial_rooms}
      ]

  ## Performance Notes

  - All operations are serialized through the GenServer
  - For high-read workloads, consider using the pure BrandedChamp directly
  - The GenServer is suitable for moderate throughput state management
  """

  use GenServer
  require Logger

  alias EchoData.BrandedChamp

  @type server :: GenServer.server()
  @type id :: EchoData.BrandedId.t()
  @type value :: any()
  @type namespace :: binary()

  # Client API

  @doc """
  Starts a ChampServer process.

  ## Options

  - `:name` - Registers the server with a name (atom or via tuple)
  - `:initial` - List of `{id, value}` pairs to initialize with
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name)

    gen_opts =
      if name do
        [name: name]
      else
        []
      end

    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Fetches a value from the CHAMP server.
  """
  @spec fetch(server(), id()) :: {:ok, value()} | :error
  def fetch(server, id) do
    GenServer.call(server, {:fetch, id})
  end

  @doc """
  Gets a value from the CHAMP server with optional default.
  """
  @spec get(server(), id(), value()) :: value()
  def get(server, id, default \\ nil) do
    case fetch(server, id) do
      {:ok, value} -> value
      :error -> default
    end
  end

  @doc """
  Puts a value into the CHAMP server.
  """
  @spec put(server(), id(), value()) :: :ok
  def put(server, id, value) do
    GenServer.call(server, {:put, id, value})
  end

  @doc """
  Puts a value into the CHAMP server asynchronously.
  """
  @spec put_async(server(), id(), value()) :: :ok
  def put_async(server, id, value) do
    GenServer.cast(server, {:put, id, value})
  end

  @doc """
  Deletes an entry from the CHAMP server.
  """
  @spec delete(server(), id()) :: :ok
  def delete(server, id) do
    GenServer.call(server, {:delete, id})
  end

  @doc """
  Deletes an entry from the CHAMP server asynchronously.
  """
  @spec delete_async(server(), id()) :: :ok
  def delete_async(server, id) do
    GenServer.cast(server, {:delete, id})
  end

  @doc """
  Checks if an ID exists in the CHAMP server.
  """
  @spec has_key?(server(), id()) :: boolean()
  def has_key?(server, id) do
    GenServer.call(server, {:has_key?, id})
  end

  @doc """
  Returns the size of the CHAMP.
  """
  @spec size(server()) :: non_neg_integer()
  def size(server) do
    GenServer.call(server, :size)
  end

  @doc """
  Returns all entries for a namespace.
  """
  @spec get_namespace(server(), namespace()) :: [{id(), value()}]
  def get_namespace(server, namespace) do
    GenServer.call(server, {:get_namespace, namespace})
  end

  @doc """
  Returns the count for a namespace.
  """
  @spec namespace_size(server(), namespace()) :: non_neg_integer()
  def namespace_size(server, namespace) do
    GenServer.call(server, {:namespace_size, namespace})
  end

  @doc """
  Returns all namespaces with entries.
  """
  @spec namespaces(server()) :: [namespace()]
  def namespaces(server) do
    GenServer.call(server, :namespaces)
  end

  @doc """
  Converts the CHAMP to a list.
  """
  @spec to_list(server()) :: [{id(), value()}]
  def to_list(server) do
    GenServer.call(server, :to_list)
  end

  @doc """
  Converts the CHAMP to a map.
  """
  @spec to_map(server()) :: %{optional(id()) => value()}
  def to_map(server) do
    GenServer.call(server, :to_map)
  end

  @doc """
  Returns all keys.
  """
  @spec keys(server()) :: [id()]
  def keys(server) do
    GenServer.call(server, :keys)
  end

  @doc """
  Returns all values.
  """
  @spec values(server()) :: [value()]
  def values(server) do
    GenServer.call(server, :values)
  end

  @doc """
  Updates a value using a function.
  """
  @spec update(server(), id(), value(), (value() -> value())) :: :ok
  def update(server, id, default, fun) do
    GenServer.call(server, {:update, id, default, fun})
  end

  @doc """
  Clears all entries.
  """
  @spec clear(server()) :: :ok
  def clear(server) do
    GenServer.call(server, :clear)
  end

  @doc """
  Replaces the entire CHAMP with a new one.
  """
  @spec replace(server(), BrandedChamp.t() | [{id(), value()}]) :: :ok
  def replace(server, champ_or_list) do
    GenServer.call(server, {:replace, champ_or_list})
  end

  @doc """
  Gets the underlying BrandedChamp struct.

  Useful for read-heavy operations where you want to avoid GenServer calls.
  """
  @spec get_champ(server()) :: BrandedChamp.t()
  def get_champ(server) do
    GenServer.call(server, :get_champ)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    initial = Keyword.get(opts, :initial, [])

    champ =
      case initial do
        %BrandedChamp{} = c -> c
        list when is_list(list) -> BrandedChamp.new(list)
      end

    Logger.debug("ChampServer started with #{BrandedChamp.size(champ)} entries")
    {:ok, champ}
  end

  @impl true
  def handle_call({:fetch, id}, _from, champ) do
    {:reply, BrandedChamp.fetch(champ, id), champ}
  end

  def handle_call({:put, id, value}, _from, champ) do
    {:reply, :ok, BrandedChamp.put(champ, id, value)}
  end

  def handle_call({:delete, id}, _from, champ) do
    {:reply, :ok, BrandedChamp.delete(champ, id)}
  end

  def handle_call({:has_key?, id}, _from, champ) do
    {:reply, BrandedChamp.has_key?(champ, id), champ}
  end

  def handle_call(:size, _from, champ) do
    {:reply, BrandedChamp.size(champ), champ}
  end

  def handle_call({:get_namespace, ns}, _from, champ) do
    {:reply, BrandedChamp.get_namespace(champ, ns), champ}
  end

  def handle_call({:namespace_size, ns}, _from, champ) do
    {:reply, BrandedChamp.namespace_size(champ, ns), champ}
  end

  def handle_call(:namespaces, _from, champ) do
    {:reply, BrandedChamp.namespaces(champ), champ}
  end

  def handle_call(:to_list, _from, champ) do
    {:reply, BrandedChamp.to_list(champ), champ}
  end

  def handle_call(:to_map, _from, champ) do
    {:reply, BrandedChamp.to_map(champ), champ}
  end

  def handle_call(:keys, _from, champ) do
    {:reply, BrandedChamp.keys(champ), champ}
  end

  def handle_call(:values, _from, champ) do
    {:reply, BrandedChamp.values(champ), champ}
  end

  def handle_call({:update, id, default, fun}, _from, champ) do
    {:reply, :ok, BrandedChamp.update(champ, id, default, fun)}
  end

  def handle_call(:clear, _from, _champ) do
    {:reply, :ok, BrandedChamp.new()}
  end

  def handle_call({:replace, champ_or_list}, _from, _champ) do
    new_champ =
      case champ_or_list do
        %BrandedChamp{} = c -> c
        list when is_list(list) -> BrandedChamp.new(list)
      end

    {:reply, :ok, new_champ}
  end

  def handle_call(:get_champ, _from, champ) do
    {:reply, champ, champ}
  end

  @impl true
  def handle_cast({:put, id, value}, champ) do
    {:noreply, BrandedChamp.put(champ, id, value)}
  end

  def handle_cast({:delete, id}, champ) do
    {:noreply, BrandedChamp.delete(champ, id)}
  end
end
