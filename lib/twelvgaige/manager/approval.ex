defmodule Twelvgaige.Manager.Approval do
  @moduledoc "Digest-bound, independently signed approval for exact manager authority expansion."

  def intent(plan_digest, reasons, manager_principal, signing_key, opts \\ [])
      when is_binary(signing_key) do
    body = %{
      id: Keyword.get(opts, :id, Twelvgaige.ID.new(:event)),
      plan_digest: plan_digest,
      reasons: Enum.sort(reasons),
      manager_principal: manager_principal,
      expires_at: Keyword.get(opts, :expires_at, DateTime.add(DateTime.utc_now(), 900))
    }

    digest = digest(body)
    Map.merge(body, %{action_digest: digest, intent_mac: mac(signing_key, digest)})
  end

  def receipt(intent, principal, signing_key, opts \\ []) when is_binary(signing_key) do
    body = %{
      intent_id: intent.id,
      action_digest: intent.action_digest,
      plan_digest: intent.plan_digest,
      decision: Keyword.get(opts, :decision, :accept),
      principal: principal,
      decided_at: Keyword.get(opts, :now, DateTime.utc_now())
    }

    Map.put(body, :receipt_mac, mac(signing_key, digest(body)))
  end

  def verify(intent, receipt, manager_principal, signing_key, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    receipt_body = Map.delete(receipt, :receipt_mac)

    cond do
      not secure?(intent.intent_mac, mac(signing_key, intent.action_digest)) ->
        {:error, :manager_approval_intent_invalid}

      receipt.intent_id != intent.id or receipt.action_digest != intent.action_digest or
          receipt.plan_digest != intent.plan_digest ->
        {:error, :manager_approval_digest_mismatch}

      receipt.decision != :accept ->
        {:error, :manager_approval_declined}

      receipt.principal == manager_principal ->
        {:error, :manager_cannot_self_approve}

      DateTime.compare(now, intent.expires_at) != :lt ->
        {:error, :manager_approval_expired}

      not secure?(receipt.receipt_mac, mac(signing_key, digest(receipt_body))) ->
        {:error, :manager_approval_receipt_invalid}

      true ->
        :ok
    end
  end

  defp digest(term),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(canonical(term)))
      |> Base.encode16(case: :lower)

  defp mac(key, value),
    do: :crypto.mac(:hmac, :sha256, key, value) |> Base.url_encode64(padding: false)

  defp secure?(left, right) when is_binary(left) and is_binary(right) do
    with {:ok, left} <- Base.url_decode64(left, padding: false),
         {:ok, right} <- Base.url_decode64(right, padding: false) do
      Twelvgaige.Security.secure_equal?(left, right)
    else
      _error -> false
    end
  end

  defp secure?(_left, _right), do: false

  defp canonical(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp canonical(map) when is_map(map),
    do: map |> Enum.map(fn {key, val} -> {to_string(key), canonical(val)} end) |> Enum.sort()

  defp canonical(list) when is_list(list), do: Enum.map(list, &canonical/1)
  defp canonical(value), do: value
end
