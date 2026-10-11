defmodule EchoData.Web do
  @moduledoc """
  Web-layer helpers. A branded ID is already a well-behaved DOM id: it begins
  with an uppercase letter and contains only `[A-Za-z0-9]`, so it is valid as
  an HTML `id`, safe in CSS selectors (`#USR0NgWEfAEJfs`), and unique across
  entity types by construction — the namespace does the disambiguation a
  `"user-" <> id` prefix usually exists to provide.
  """

  alias EchoData.BrandedId

  @doc "Validated DOM id passthrough; raises on a non-branded value at render time."
  def dom_id(id) do
    BrandedId.parse(id) != :error || raise ArgumentError, "not a branded id: #{inspect(id)}"
    id
  end

  @doc "For LiveView streams: `stream(socket, :courses, items, dom_id: &EchoData.Web.stream_dom_id/1)`."
  def stream_dom_id(%{id: id}), do: dom_id(id)
  def stream_dom_id(%{"id" => id}), do: dom_id(id)
end
