defmodule Twelvgaige.Audit.Checkpoint do
  @moduledoc """
  Tamper-evident checkpoint projection for audit/event exports.

  This does not make the live local store append-only or immutable. It gives
  operators a deterministic export artifact whose event payloads can be verified
  later: each event hash includes the previous chain hash plus a canonical JSON
  representation of the event.
  """

  alias Twelvgaige.Audit.Event, as: AuditEvent

  @schema_version 1
  @algorithm "sha256-chain-v1"
  @signature_algorithm "hmac-sha256-v1"
  @genesis String.duplicate("0", 64)

  @type checkpoint :: map()

  @spec export([map()], keyword()) :: checkpoint()
  def export(events, opts \\ []) when is_list(events) do
    normalized = Enum.map(events, &normalize_event/1)
    {chain_events, root_hash} = chain_events(normalized)

    %{
      "kind" => "twelvgaige.audit.checkpoint",
      "schema_version" => @schema_version,
      "algorithm" => @algorithm,
      "scope" => opts |> Keyword.get(:scope, :audit) |> to_string(),
      "round_id" => Keyword.get(opts, :round_id) || infer_round_id(normalized),
      "event_count" => length(chain_events),
      "first_seq" => seq_value(List.first(normalized)),
      "last_seq" => seq_value(List.last(normalized)),
      "root_hash" => root_hash,
      "generated_at" => DateTime.to_iso8601(Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())),
      "events" => chain_events
    }
  end

  @spec verify(checkpoint()) :: :ok | {:error, term()}
  def verify(%{} = checkpoint) do
    with :ok <- verify_shape(checkpoint),
         {:ok, events} <- fetch_events(checkpoint),
         {:ok, recomputed} <- recompute(events),
         :ok <- compare_checkpoint(checkpoint, recomputed) do
      :ok
    end
  end

  def verify(_checkpoint), do: {:error, :invalid_checkpoint}

  @spec sign_hmac(checkpoint(), binary(), keyword()) :: {:ok, checkpoint()} | {:error, term()}
  def sign_hmac(checkpoint, key, opts \\ [])

  def sign_hmac(%{} = checkpoint, key, opts) when is_binary(key) and key != "" do
    with :ok <- verify(checkpoint) do
      signed_at = DateTime.to_iso8601(Keyword.get(opts, :now, Twelvgaige.Clock.utc_now()))
      key_ref = Keyword.get(opts, :key_ref)

      signature =
        checkpoint
        |> unsigned_checkpoint()
        |> signature_payload()
        |> hmac(key)

      {:ok,
       Map.put(checkpoint, "signature", %{
         "algorithm" => @signature_algorithm,
         "signature" => "base64:" <> Base.encode64(signature),
         "key_ref" => key_ref,
         "signed_at" => signed_at
       })}
    end
  end

  def sign_hmac(_checkpoint, _key, _opts), do: {:error, :hmac_key_required}

  @spec verify_hmac(checkpoint(), binary()) :: :ok | {:error, term()}
  def verify_hmac(%{} = checkpoint, key) when is_binary(key) and key != "" do
    with :ok <- verify(checkpoint),
         {:ok, signature} <- fetch_signature(checkpoint),
         {:ok, actual} <- decode_signature(signature["signature"]) do
      expected =
        checkpoint
        |> unsigned_checkpoint()
        |> signature_payload()
        |> hmac(key)

      if Twelvgaige.Security.secure_equal?(actual, expected) do
        :ok
      else
        {:error, :hmac_signature_mismatch}
      end
    end
  end

  def verify_hmac(_checkpoint, _key), do: {:error, :hmac_key_required}

  @spec verify!(checkpoint()) :: checkpoint()
  def verify!(%{} = checkpoint) do
    case verify(checkpoint) do
      :ok -> checkpoint
      {:error, reason} -> raise ArgumentError, "invalid audit checkpoint: #{inspect(reason)}"
    end
  end

  defp chain_events(events) do
    Enum.map_reduce(events, @genesis, fn event, previous_hash ->
      event_hash = hash_event(previous_hash, event)

      event =
        event
        |> Map.put("previous_hash", previous_hash)
        |> Map.put("event_hash", event_hash)

      {event, event_hash}
    end)
  end

  defp verify_shape(%{
         "kind" => "twelvgaige.audit.checkpoint",
         "schema_version" => @schema_version,
         "algorithm" => @algorithm
       }),
       do: :ok

  defp verify_shape(_checkpoint), do: {:error, :invalid_checkpoint_header}

  defp fetch_signature(%{
         "signature" =>
           %{
             "algorithm" => @signature_algorithm,
             "signature" => signature
           } = signature_block
       })
       when is_binary(signature),
       do: {:ok, signature_block}

  defp fetch_signature(%{"signature" => _signature}), do: {:error, :invalid_signature_block}
  defp fetch_signature(_checkpoint), do: {:error, :missing_signature}

  defp decode_signature("base64:" <> encoded), do: Base.decode64(encoded)
  defp decode_signature(_signature), do: {:error, :invalid_signature}

  defp fetch_events(%{"events" => events}) when is_list(events), do: {:ok, events}
  defp fetch_events(_checkpoint), do: {:error, :missing_events}

  defp recompute(events) do
    Enum.reduce_while(events, {:ok, [], @genesis}, fn event, {:ok, acc, expected_previous} ->
      with {:ok, previous_hash} <- fetch_hash(event, "previous_hash"),
           {:ok, event_hash} <- fetch_hash(event, "event_hash"),
           true <- previous_hash == expected_previous,
           bare_event <- Map.drop(event, ["previous_hash", "event_hash"]),
           ^event_hash <- hash_event(previous_hash, bare_event) do
        {:cont, {:ok, [event | acc], event_hash}}
      else
        false -> {:halt, {:error, {:previous_hash_mismatch, seq_value(event)}}}
        _other -> {:halt, {:error, {:event_hash_mismatch, seq_value(event)}}}
      end
    end)
    |> case do
      {:ok, verified_reversed, root_hash} ->
        {:ok, %{events: Enum.reverse(verified_reversed), root_hash: root_hash}}

      {:error, _reason} = error ->
        error
    end
  end

  defp compare_checkpoint(checkpoint, %{events: events, root_hash: root_hash}) do
    cond do
      checkpoint["event_count"] != length(events) ->
        {:error, :event_count_mismatch}

      checkpoint["root_hash"] != root_hash ->
        {:error, :root_hash_mismatch}

      checkpoint["first_seq"] != seq_value(List.first(events)) ->
        {:error, :first_seq_mismatch}

      checkpoint["last_seq"] != seq_value(List.last(events)) ->
        {:error, :last_seq_mismatch}

      true ->
        :ok
    end
  end

  defp fetch_hash(event, key) do
    case Map.get(event, key) do
      hash when is_binary(hash) and byte_size(hash) == 64 -> {:ok, hash}
      _other -> {:error, {:missing_hash, key}}
    end
  end

  defp hash_event(previous_hash, event) do
    [previous_hash, "\n", canonical_json(event)]
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp normalize_event(%{} = event), do: AuditEvent.to_map(event)

  defp infer_round_id([%{"round_id" => round_id} | _events]), do: round_id
  defp infer_round_id(_events), do: nil

  defp seq_value(nil), do: nil
  defp seq_value(event), do: Map.get(event, "seq")

  defp canonical_json(%{} = map) do
    inner =
      map
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map(fn {key, value} ->
        [Jason.encode!(to_string(key)), ":", canonical_json(value)]
      end)
      |> Enum.intersperse(",")

    ["{", inner, "}"]
  end

  defp canonical_json(values) when is_list(values) do
    ["[", values |> Enum.map(&canonical_json/1) |> Enum.intersperse(","), "]"]
  end

  defp canonical_json(value), do: Jason.encode!(value)

  defp unsigned_checkpoint(checkpoint), do: Map.delete(checkpoint, "signature")

  defp signature_payload(checkpoint) do
    ["twelvgaige.audit.checkpoint.signature.v1", "\n", canonical_json(checkpoint)]
    |> IO.iodata_to_binary()
  end

  defp hmac(payload, key), do: :crypto.mac(:hmac, :sha256, key, payload)
end
