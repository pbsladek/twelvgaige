defmodule Twelvgaige.DelegatedSession.Codex.Approval do
  @moduledoc "Digest-bound action intents and receipts for native Codex approvals."

  @decisions [:accept, :accept_for_session, :decline, :cancel]

  def intent(attrs, signing_key) when is_binary(signing_key) do
    body = %{
      id: fetch!(attrs, :id),
      method: fetch!(attrs, :method),
      session_id: fetch!(attrs, :session_id),
      thread_id: fetch!(attrs, :thread_id),
      turn_id: fetch!(attrs, :turn_id),
      native_request_id: fetch!(attrs, :native_request_id),
      params: fetch!(attrs, :params),
      expires_at: fetch!(attrs, :expires_at)
    }

    digest = digest(body)
    Map.merge(body, %{action_digest: digest, intent_mac: mac(signing_key, digest)})
  end

  def receipt(intent, decision, principal, signing_key, opts \\ [])
      when decision in @decisions and is_binary(signing_key) do
    body = %{
      intent_id: intent.id,
      action_digest: intent.action_digest,
      decision: decision,
      principal: principal,
      decided_at: Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
    }

    Map.put(body, :receipt_mac, mac(signing_key, digest(body)))
  end

  def verify(intent, receipt, signing_key, opts \\ []) do
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
    receipt_body = Map.delete(receipt, :receipt_mac)

    cond do
      not Twelvgaige.Security.secure_equal?(
        decode_mac(intent.intent_mac),
        decode_mac(mac(signing_key, intent.action_digest))
      ) ->
        {:error, :approval_intent_invalid}

      receipt.action_digest != intent.action_digest or receipt.intent_id != intent.id ->
        {:error, :approval_digest_mismatch}

      receipt.decision not in @decisions ->
        {:error, :approval_decision_invalid}

      DateTime.compare(now, intent.expires_at) != :lt ->
        {:error, :approval_expired}

      not Twelvgaige.Security.secure_equal?(
        decode_mac(receipt.receipt_mac),
        decode_mac(mac(signing_key, digest(receipt_body)))
      ) ->
        {:error, :approval_receipt_invalid}

      true ->
        :ok
    end
  end

  def native_decision(:accept), do: "accept"
  def native_decision(:accept_for_session), do: "acceptForSession"
  def native_decision(:decline), do: "decline"
  def native_decision(:cancel), do: "cancel"

  defp digest(term),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(canonical(term)))
      |> Base.encode16(case: :lower)

  defp mac(key, data),
    do: :crypto.mac(:hmac, :sha256, key, data) |> Base.url_encode64(padding: false)

  defp decode_mac(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, decoded} -> decoded
      :error -> <<>>
    end
  end

  defp decode_mac(_value), do: <<>>

  defp canonical(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp canonical(map) when is_map(map),
    do: map |> Enum.map(fn {key, value} -> {to_string(key), canonical(value)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value

  defp fetch!(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(map, Atom.to_string(key))
    end
  end
end
