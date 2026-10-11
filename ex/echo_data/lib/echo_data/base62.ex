defmodule EchoData.Base62 do
  @moduledoc """
  Fixed-width base62 codec for snowflake payloads: alphabet `0-9A-Za-z`,
  width 11, left-padded with `0`. Lexicographic order equals numeric order,
  which the decoder uses as its overflow guard.

      iex> EchoData.Base62.encode(274557032793636864)
      "0KHTOWnGLuC"
      iex> EchoData.Base62.decode("0KHTOWnGLuC")
      {:ok, 274557032793636864}
      iex> EchoData.Base62.decode("zzzzzzzzzzz")
      :error
  """

  @alphabet ~c"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
  # base62(2^63 - 1): the largest valid payload, used as a lexicographic range guard.
  @max_payload "AzL8n0Y58m7"
  @default_width 11

  @spec encode(non_neg_integer()) :: binary()
  def encode(n) when is_integer(n) and n >= 0 and n <= 9_223_372_036_854_775_807 do
    digits(n, 11, <<>>)
  end

  @doc """
  Width-parameterized encode (back-compat). `width: 11` (the default) routes
  through the strict 11-char `encode/1`, so the wire format is byte-identical;
  other widths left-pad to that width with `pad` (default `"0"`).

  ## Options

    * `:width` — output width, default 11;
    * `:pad` — single-character pad, default `"0"`.
  """
  @spec encode(non_neg_integer(), keyword()) :: binary()
  def encode(n, opts) when is_integer(n) and n >= 0 and is_list(opts) do
    width = Keyword.get(opts, :width, @default_width)
    pad = Keyword.get(opts, :pad, "0")

    if width == @default_width and pad == "0" and n <= 9_223_372_036_854_775_807 do
      encode(n)
    else
      n |> digits_min(<<>>) |> String.pad_leading(width, pad)
    end
  end

  defp digits(_n, 0, acc), do: acc

  defp digits(n, k, acc) do
    digits(div(n, 62), k - 1, <<char(rem(n, 62)), acc::binary>>)
  end

  # Minimal-width digits (no fixed length) for the non-default `encode/2` path.
  defp digits_min(0, <<>>), do: <<char(0)>>
  defp digits_min(0, acc), do: acc
  defp digits_min(n, acc), do: digits_min(div(n, 62), <<char(rem(n, 62)), acc::binary>>)

  @spec decode(binary()) :: {:ok, non_neg_integer()} | :error
  def decode(<<payload::binary-size(11)>>) when payload <= @max_payload do
    acc(payload, 0)
  end

  def decode(_), do: :error

  @doc "Decodes an 11-char payload, raising `ArgumentError` on an invalid string."
  @spec decode!(binary()) :: non_neg_integer()
  def decode!(payload) do
    case decode(payload) do
      {:ok, n} -> n
      :error -> raise ArgumentError, "invalid Base62 string: #{inspect(payload)}"
    end
  end

  @doc "True for a well-formed, in-range 11-char payload."
  @spec valid?(term()) :: boolean()
  def valid?(payload), do: decode(payload) != :error

  @doc "The 62-character alphabet as a binary."
  @spec alphabet() :: binary()
  def alphabet, do: List.to_string(@alphabet)

  defp acc(<<>>, n), do: {:ok, n}

  defp acc(<<c, rest::binary>>, n) do
    case value(c) do
      :error -> :error
      d -> acc(rest, n * 62 + d)
    end
  end

  # Compile-time generated function-head dispatch: one clause per byte.
  for {c, i} <- Enum.with_index(@alphabet) do
    defp char(unquote(i)), do: unquote(c)
    defp value(unquote(c)), do: unquote(i)
  end

  defp value(_), do: :error
end
