defmodule EchoData.Bcs.Supervisor do
  @moduledoc "one_for_one over named property stores. Rung bcs1.1."

  use Supervisor

  def start_link(stores), do: Supervisor.start_link(__MODULE__, stores, name: __MODULE__)

  @impl true
  def init(stores) do
    children =
      for {name, ns} <- stores do
        Supervisor.child_spec({EchoData.Bcs.PropertyStore, [name: name, namespace: ns]},
          id: name
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end
end
