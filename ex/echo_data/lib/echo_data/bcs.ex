defmodule EchoData.Bcs do
  @moduledoc """
  Boundary discipline for BCS systems. Rung bcs1.1.

  The gate admits ids of one namespace and refuses everything else. It adds
  no second parser: classification beyond the namespace collapses to
  `:invalid`, exactly as `EchoData.BrandedId.parse/1` reports it.
  """

  alias EchoData.BrandedId

  defmodule NamespaceError do
    defexception [:message]
  end

  @type gate_error :: :namespace | :invalid

  @spec gate(binary(), binary()) :: {:ok, non_neg_integer()} | {:error, gate_error()}
  def gate(id, ns) when is_binary(id) and is_binary(ns) do
    case BrandedId.parse(id) do
      {:ok, ^ns, snow} -> {:ok, snow}
      {:ok, _other, _snow} -> {:error, :namespace}
      :error -> {:error, :invalid}
    end
  end

  @spec gate!(binary(), binary()) :: non_neg_integer()
  def gate!(id, ns) do
    case gate(id, ns) do
      {:ok, snow} ->
        snow

      {:error, :namespace} ->
        raise NamespaceError, message: "expected namespace #{ns}, got #{BrandedId.namespace(id)}"

      {:error, :invalid} ->
        raise ArgumentError, "invalid branded id"
    end
  end
end
