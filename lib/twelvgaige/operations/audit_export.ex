defmodule Twelvgaige.Operations.AuditExport do
  @moduledoc "Authenticated, signed export and verification for the operations audit chain."

  alias Twelvgaige.Audit.Chain
  alias Twelvgaige.Operations.Store

  def export(destination, signing_key, opts \\ [])
      when is_binary(signing_key) and byte_size(signing_key) >= 32 do
    with :ok <- authorize(opts),
         {:ok, snapshot} <- Store.audit_snapshot(server: Keyword.get(opts, :store, Store)),
         :ok <- Chain.verify_from(snapshot.base_hash, snapshot.events),
         payload <- export_payload(snapshot, opts),
         encoded <- canonical_json(payload),
         signature <- sign(signing_key, encoded),
         envelope <- Jason.encode!(%{"payload" => payload, "signature" => signature}),
         :ok <- atomic_write(Path.expand(destination), envelope) do
      {:ok,
       %{
         destination: Path.expand(destination),
         events: length(snapshot.events),
         signature: signature
       }}
    end
  end

  def verify(path, signing_key) when is_binary(signing_key) do
    with {:ok, encoded} <- File.read(path),
         {:ok, %{"payload" => payload, "signature" => signature}} <- Jason.decode(encoded),
         true <-
           Twelvgaige.Security.secure_equal?(
             sign(signing_key, canonical_json(payload)),
             signature
           ),
         events when is_list(events) <- payload["events"],
         atomized <- Enum.map(events, &atomize_chain_keys/1),
         base_hash when is_binary(base_hash) <- payload["base_hash"],
         :ok <- Chain.verify_from(base_hash, atomized) do
      {:ok, payload}
    else
      false -> {:error, :audit_export_signature_invalid}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :audit_export_invalid}
    end
  end

  defp authorize(opts) do
    case Keyword.get(opts, :authorize, fn -> :ok end).() do
      :ok -> :ok
      {:error, _reason} = error -> error
      _other -> {:error, :audit_export_unauthorized}
    end
  end

  defp export_payload(snapshot, opts) do
    %{
      "schema_version" => 1,
      "owner_uid" => Keyword.get(opts, :owner_uid),
      "exported_at" => DateTime.to_iso8601(Keyword.get(opts, :now, DateTime.utc_now())),
      "base_hash" => snapshot.base_hash,
      "pruned_through_sequence" => snapshot.pruned_through_sequence,
      "events" => Enum.map(snapshot.events, &Twelvgaige.Audit.Event.to_map/1),
      "chain_head" => snapshot.chain_head
    }
  end

  defp atomic_write(path, contents) do
    temp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(temp, contents, [:binary, :exclusive]),
         :ok <- File.chmod(temp, 0o600),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temp)
        {:error, reason}
    end
  end

  defp canonical_json(value), do: Jason.encode!(sort_maps(value))

  defp sort_maps(%{} = map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Map.new(fn {key, value} -> {to_string(key), sort_maps(value)} end)
  end

  defp sort_maps(values) when is_list(values), do: Enum.map(values, &sort_maps/1)
  defp sort_maps(value), do: value

  defp sign(key, encoded),
    do: :crypto.mac(:hmac, :sha256, key, encoded) |> Base.url_encode64(padding: false)

  defp atomize_chain_keys(event) do
    event
    |> Map.put(:audit_chain_algorithm, event["audit_chain_algorithm"])
    |> Map.put(:audit_previous_hash, event["audit_previous_hash"])
    |> Map.put(:audit_chain_hash, event["audit_chain_hash"])
  end
end
