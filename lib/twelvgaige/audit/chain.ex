defmodule Twelvgaige.Audit.Chain do
  @moduledoc "Tamper-evident digest chaining for durable audit events."

  alias Twelvgaige.Audit.Event

  @algorithm "sha256-chain-v1"
  @genesis String.duplicate("0", 64)

  @spec append([map()], [map()]) :: [map()]
  def append(existing, events) when is_list(existing) and is_list(events) do
    extend(last_hash(existing), events)
  end

  @spec extend(String.t(), [map()]) :: [map()]
  def extend(previous_hash, events) when is_binary(previous_hash) and is_list(events) do
    {events, _last_hash} =
      Enum.map_reduce(events, previous_hash, fn event, previous ->
        event = event |> Event.sanitize() |> drop_chain_fields()
        hash = digest(previous, event)

        chained =
          event
          |> Map.put(:audit_chain_algorithm, @algorithm)
          |> Map.put(:audit_previous_hash, previous)
          |> Map.put(:audit_chain_hash, hash)

        {chained, hash}
      end)

    events
  end

  @spec verify([map()]) :: :ok | {:error, term()}
  def verify(events) when is_list(events), do: verify_from(@genesis, events)

  @doc "Verifies a retained suffix against its previously anchored chain head."
  @spec verify_from(String.t(), [map()]) :: :ok | {:error, term()}
  def verify_from(previous_hash, events)
      when is_binary(previous_hash) and is_list(events) do
    Enum.reduce_while(events, {:ok, previous_hash}, fn event, {:ok, expected_previous} ->
      previous = value(event, :audit_previous_hash)
      actual = value(event, :audit_chain_hash)
      bare = drop_chain_fields(event)

      cond do
        value(event, :audit_chain_algorithm) != @algorithm ->
          {:halt, {:error, :unsupported_chain_algorithm}}

        previous != expected_previous ->
          {:halt, {:error, :previous_hash_mismatch}}

        actual != digest(previous, bare) ->
          {:halt, {:error, :chain_hash_mismatch}}

        true ->
          {:cont, {:ok, actual}}
      end
    end)
    |> case do
      {:ok, _hash} -> :ok
      {:error, _reason} = error -> error
    end
  end

  def genesis, do: @genesis

  defp last_hash([]), do: @genesis

  defp last_hash(events) do
    case events |> List.last() |> value(:audit_chain_hash) do
      hash when is_binary(hash) -> hash
      _other -> @genesis
    end
  end

  defp digest(previous, event) do
    :crypto.hash(:sha256, previous <> "\n" <> canonical_json(Event.to_map(event)))
    |> Base.encode16(case: :lower)
  end

  defp drop_chain_fields(event) do
    Map.drop(event, [
      :seq,
      :audit_chain_algorithm,
      :audit_previous_hash,
      :audit_chain_hash,
      "seq",
      "audit_chain_algorithm",
      "audit_previous_hash",
      "audit_chain_hash"
    ])
  end

  defp canonical_json(%{} = map) do
    inner =
      map
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} ->
        [Jason.encode!(to_string(key)), ":", canonical_json(value)]
      end)
      |> Enum.intersperse(",")

    ["{", inner, "}"] |> IO.iodata_to_binary()
  end

  defp canonical_json(values) when is_list(values) do
    ["[", values |> Enum.map(&canonical_json/1) |> Enum.intersperse(","), "]"]
    |> IO.iodata_to_binary()
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))
end
