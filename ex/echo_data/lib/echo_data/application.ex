defmodule EchoData.Application do
  @moduledoc false
  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    :ok = EchoData.Snowflake.start()
    {:ok, mode} = EchoData.BrandedId.self_check!()
    Logger.info("EchoData: contract self-check passed, codec=#{mode}")
    Supervisor.start_link([], strategy: :one_for_one, name: EchoData.Supervisor)
  end
end
