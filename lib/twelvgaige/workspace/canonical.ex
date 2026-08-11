defmodule Twelvgaige.Workspace.Canonical do
  @moduledoc """
  Canonical encoding and domain-separated digests for portable workspace records.

  Contract maps use string keys, integer numbers, and raw repository paths encoded
  as unpadded base64url. The encoder deliberately rejects floats and ambiguous map
  keys so a digest never depends on a runtime's map iteration or number formatting.
  """

  @type contract :: String.t() | atom()
  @max_safe_integer 9_007_199_254_740_991

  @spec encode(term()) :: {:ok, binary()} | {:error, term()}
  def encode(value) do
    try do
      {:ok, IO.iodata_to_binary(encode_value(value))}
    rescue
      error in ArgumentError -> {:error, {:canonical_encoding_invalid, error.message}}
    end
  end

  @spec encode!(term()) :: binary()
  def encode!(value) do
    case encode(value) do
      {:ok, encoded} -> encoded
      {:error, reason} -> raise ArgumentError, inspect(reason)
    end
  end

  @spec digest(contract(), pos_integer(), term()) :: {:ok, String.t()} | {:error, term()}
  def digest(contract, version, value) when is_integer(version) and version > 0 do
    with {:ok, encoded} <- encode(value) do
      domain = [
        "twelvgaige",
        <<0>>,
        to_string(contract),
        <<0>>,
        Integer.to_string(version),
        <<0>>
      ]

      digest = :crypto.hash(:sha256, [domain, encoded]) |> Base.encode16(case: :lower)
      {:ok, "sha256:" <> digest}
    end
  end

  def digest(_contract, _version, _value), do: {:error, :canonical_digest_version_invalid}

  @spec digest_bytes(contract(), pos_integer(), binary()) ::
          {:ok, String.t()} | {:error, term()}
  def digest_bytes(contract, version, bytes)
      when is_integer(version) and version > 0 and is_binary(bytes) do
    domain = ["twelvgaige", <<0>>, to_string(contract), <<0>>, Integer.to_string(version), <<0>>]
    digest = :crypto.hash(:sha256, [domain, bytes]) |> Base.encode16(case: :lower)
    {:ok, "sha256:" <> digest}
  end

  def digest_bytes(_contract, _version, _bytes),
    do: {:error, :canonical_digest_bytes_invalid}

  @spec path(binary()) :: map()
  def path(raw) when is_binary(raw) do
    %{
      "encoding" => "base64url",
      "bytes" => Base.url_encode64(raw, padding: false)
    }
  end

  @spec decode_path(map()) :: {:ok, binary()} | {:error, term()}
  def decode_path(%{"encoding" => "base64url", "bytes" => encoded}) when is_binary(encoded) do
    case Base.url_decode64(encoded, padding: false) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:error, :canonical_path_invalid}
    end
  end

  def decode_path(_encoded), do: {:error, :canonical_path_invalid}

  defp encode_value(nil), do: "null"
  defp encode_value(true), do: "true"
  defp encode_value(false), do: "false"

  defp encode_value(value)
       when is_integer(value) and value >= -@max_safe_integer and value <= @max_safe_integer,
       do: Integer.to_string(value)

  defp encode_value(value) when is_integer(value),
    do: invalid!("integer is outside the interoperable JSON range")

  defp encode_value(value) when is_float(value),
    do: invalid!("floating-point values are forbidden")

  defp encode_value(value) when is_binary(value), do: Jason.encode!(value)

  defp encode_value(%DateTime{} = value),
    do: value |> DateTime.to_iso8601() |> encode_value()

  defp encode_value(value) when is_atom(value),
    do: value |> Atom.to_string() |> encode_value()

  defp encode_value(value) when is_list(value) do
    ["[", value |> Enum.map(&encode_value/1) |> Enum.intersperse(","), "]"]
  end

  defp encode_value(%_{} = struct),
    do: struct |> Map.from_struct() |> encode_value()

  defp encode_value(%{} = value) do
    entries =
      Enum.map(value, fn {key, child} ->
        key = canonical_key(key)
        {key, child}
      end)

    keys = Enum.map(entries, &elem(&1, 0))

    if length(keys) != length(Enum.uniq(keys)),
      do: invalid!("map keys collide after string conversion")

    body =
      entries
      |> Enum.sort_by(fn {key, _child} -> utf16_sort_key(key) end)
      |> Enum.map(fn {key, child} -> [Jason.encode!(key), ":", encode_value(child)] end)
      |> Enum.intersperse(",")

    ["{", body, "}"]
  end

  defp encode_value(value),
    do: invalid!("unsupported value: #{inspect(value, limit: 3, printable_limit: 80)}")

  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)
  defp canonical_key(_key), do: invalid!("map keys must be strings or atoms")

  # RFC 8785 compares property names as UTF-16 code units. Big-endian UTF-16
  # gives ordinary binary comparison the same ordering.
  defp utf16_sort_key(value), do: :unicode.characters_to_binary(value, :utf8, {:utf16, :big})

  @spec invalid!(String.t()) :: no_return()
  defp invalid!(message), do: raise(ArgumentError, message)
end
