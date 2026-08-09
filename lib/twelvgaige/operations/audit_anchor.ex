defmodule Twelvgaige.Operations.AuditAnchor do
  @moduledoc """
  Periodic signed anchor for the retained operations audit chain.

  Checkpoints form an append-only, independently signed chain outside the
  operations database. Health verification checks the checkpoint chain, the
  latest retained audit suffix, file ownership/permissions, and checkpoint age.
  The signing key remains in the host operations control plane.
  """

  use GenServer

  alias Twelvgaige.Operations.{LocalIdentity, Store}

  @schema_version 1
  @genesis String.duplicate("0", 64)

  defstruct [
    :store,
    :path,
    :external_path,
    :signing_key,
    :owner_uid,
    :now_fun,
    :timer,
    :last_result,
    interval_ms: 3_600_000,
    max_age_seconds: 7_200
  ]

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    if is_nil(name),
      do: GenServer.start_link(__MODULE__, opts),
      else: GenServer.start_link(__MODULE__, opts, name: name)
  end

  def run(opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :run, :infinity)

  def status(opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :status, :infinity)

  def verify(path, signing_key, opts \\ [])
      when is_binary(path) and is_binary(signing_key) and byte_size(signing_key) >= 32 do
    owner_uid = Keyword.get(opts, :owner_uid)

    with :ok <- private_regular_file(path, owner_uid),
         {:ok, records} <- read_records(path),
         :ok <- verify_records(records, signing_key, owner_uid) do
      {:ok, records}
    end
  end

  def verify_store(path, signing_key, opts \\ []) do
    with {:ok, records} <- verify(path, signing_key, opts),
         {:ok, snapshot} <- Store.audit_snapshot(server: Keyword.get(opts, :store, Store)),
         :ok <- consistent_with_audit(records, snapshot) do
      :ok
    end
  end

  @impl true
  def init(opts) do
    with signing_key when is_binary(signing_key) <- Keyword.fetch!(opts, :signing_key),
         true <- byte_size(signing_key) >= 32,
         owner_uid when is_integer(owner_uid) <- Keyword.fetch!(opts, :owner_uid),
         path when is_binary(path) <- Keyword.fetch!(opts, :path),
         interval_ms when is_integer(interval_ms) and interval_ms > 0 <-
           Keyword.get(opts, :interval_ms, 3_600_000),
         max_age_seconds when is_integer(max_age_seconds) and max_age_seconds > 0 <-
           Keyword.get(opts, :max_age_seconds, 7_200) do
      state = %__MODULE__{
        store: Keyword.get(opts, :store, Store),
        path: Path.expand(path),
        external_path: expand_optional(Keyword.get(opts, :external_path)),
        signing_key: signing_key,
        owner_uid: owner_uid,
        now_fun: Keyword.get(opts, :now_fun, &DateTime.utc_now/0),
        interval_ms: interval_ms,
        max_age_seconds: max_age_seconds
      }

      if Keyword.get(opts, :checkpoint_on_start?, true), do: send(self(), :checkpoint)
      {:ok, state}
    else
      false -> {:stop, :audit_anchor_signing_key_invalid}
      _other -> {:stop, :audit_anchor_configuration_invalid}
    end
  end

  @impl true
  def handle_call(:run, _from, state) do
    {result, state} = checkpoint(state)
    {:reply, result, schedule(state)}
  end

  def handle_call(:status, _from, state) do
    {:reply, health(state), state}
  end

  @impl true
  def handle_info(:checkpoint, state) do
    {_result, state} = checkpoint(state)
    {:noreply, schedule(state)}
  end

  defp checkpoint(state) do
    result =
      with {:ok, snapshot} <- Store.audit_snapshot(server: state.store),
           {:ok, records} <- existing_records(state),
           {:ok, records} <- synchronize_external(state, records),
           :ok <- consistent_with_audit(records, snapshot),
           record <- build_record(records, snapshot, state),
           :ok <- append_record(state.path, record, state.owner_uid),
           :ok <- append_external(state.external_path, record, state.owner_uid) do
        {:ok, public_record(record)}
      end

    {result, %{state | last_result: result}}
  end

  defp health(state) do
    result =
      with {:ok, records} <- verify(state.path, state.signing_key, owner_uid: state.owner_uid),
           :ok <- verify_external_consistency(state, records),
           {:ok, snapshot} <- Store.audit_snapshot(server: state.store),
           :ok <- consistent_with_audit(records, snapshot),
           latest <- List.last(records),
           {:ok, created, _offset} <- DateTime.from_iso8601(latest["created_at"]),
           age_seconds <- max(DateTime.diff(state.now_fun.(), created, :second), 0) do
        %{
          status: if(age_seconds > state.max_age_seconds, do: :stale, else: :healthy),
          path: state.path,
          external_path: state.external_path,
          checkpoint_count: length(records),
          latest_sequence: latest["sequence"],
          latest_at: created,
          age_seconds: age_seconds,
          audit_position: latest["audit_position"],
          audit_chain_head: latest["audit_chain_head"],
          last_result: result_view(state.last_result)
        }
      else
        {:error, :audit_checkpoint_missing} ->
          unhealthy_view(:missing, state, :audit_checkpoint_missing)

        {:error, reason} ->
          unhealthy_view(:invalid, state, reason)
      end

    result
  end

  defp existing_records(state) do
    case verify(state.path, state.signing_key, owner_uid: state.owner_uid) do
      {:ok, records} -> {:ok, records}
      {:error, :audit_checkpoint_missing} -> {:ok, []}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_record(records, snapshot, state) do
    previous = List.last(records)
    sequence = length(records) + 1
    now = state.now_fun.() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    body = %{
      "schema_version" => @schema_version,
      "sequence" => sequence,
      "owner_uid" => state.owner_uid,
      "created_at" => now,
      "audit_position" => snapshot.pruned_through_sequence + snapshot.event_count,
      "retained_base_hash" => snapshot.base_hash,
      "pruned_through_sequence" => snapshot.pruned_through_sequence,
      "retained_event_count" => snapshot.event_count,
      "audit_chain_head" => snapshot.chain_head,
      "previous_checkpoint_hash" => if(previous, do: previous["checkpoint_hash"], else: @genesis)
    }

    checkpoint_hash = sha256(canonical_json(body))
    signed = Map.put(body, "checkpoint_hash", checkpoint_hash)
    Map.put(signed, "signature", sign(state.signing_key, canonical_json(signed)))
  end

  defp verify_records([], _key, _owner_uid), do: {:error, :audit_checkpoint_missing}

  defp verify_records(records, key, owner_uid) do
    records
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, @genesis, -1}, fn {record, sequence},
                                                 {:ok, previous_hash, previous_position} ->
      body = Map.drop(record, ["checkpoint_hash", "signature"])
      signed = Map.delete(record, "signature")
      position = record["audit_position"]

      valid_owner? = is_nil(owner_uid) or record["owner_uid"] == owner_uid

      cond do
        record["schema_version"] != @schema_version ->
          {:halt, {:error, :audit_checkpoint_schema_invalid}}

        record["sequence"] != sequence ->
          {:halt, {:error, :audit_checkpoint_sequence_invalid}}

        not valid_owner? ->
          {:halt, {:error, :audit_checkpoint_owner_invalid}}

        record["previous_checkpoint_hash"] != previous_hash ->
          {:halt, {:error, :audit_checkpoint_previous_hash_invalid}}

        record["checkpoint_hash"] != sha256(canonical_json(body)) ->
          {:halt, {:error, :audit_checkpoint_hash_invalid}}

        not secure_equal?(record["signature"], sign(key, canonical_json(signed))) ->
          {:halt, {:error, :audit_checkpoint_signature_invalid}}

        not is_integer(position) or position < previous_position ->
          {:halt, {:error, :audit_checkpoint_position_invalid}}

        not valid_hash?(record["audit_chain_head"]) or
            not valid_hash?(record["retained_base_hash"]) ->
          {:halt, {:error, :audit_checkpoint_audit_hash_invalid}}

        true ->
          {:cont, {:ok, record["checkpoint_hash"], position}}
      end
    end)
    |> case do
      {:ok, _hash, _position} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp consistent_with_audit([], _snapshot), do: :ok

  defp consistent_with_audit(records, snapshot) do
    latest = List.last(records)
    current_position = snapshot.pruned_through_sequence + snapshot.event_count
    checkpoint_position = latest["audit_position"]

    cond do
      checkpoint_position > current_position ->
        {:error, :audit_checkpoint_ahead_of_store}

      checkpoint_position <= snapshot.pruned_through_sequence ->
        :ok

      true ->
        index = checkpoint_position - snapshot.pruned_through_sequence - 1

        case Enum.at(snapshot.events, index) do
          nil ->
            {:error, :audit_checkpoint_position_missing}

          event ->
            if audit_hash(event) == latest["audit_chain_head"],
              do: :ok,
              else: {:error, :audit_checkpoint_store_mismatch}
        end
    end
  end

  defp append_external(nil, _record, _owner_uid), do: :ok
  defp append_external(path, record, owner_uid), do: append_record(path, record, owner_uid)

  defp synchronize_external(%{external_path: nil}, records), do: {:ok, records}

  defp synchronize_external(state, local_records) do
    case verify(state.external_path, state.signing_key, owner_uid: state.owner_uid) do
      {:ok, external_records} ->
        cond do
          external_records == local_records ->
            {:ok, local_records}

          prefix?(external_records, local_records) ->
            with :ok <-
                   append_records(
                     state.external_path,
                     Enum.drop(local_records, length(external_records)),
                     state.owner_uid
                   ) do
              {:ok, local_records}
            end

          prefix?(local_records, external_records) ->
            with :ok <-
                   append_records(
                     state.path,
                     Enum.drop(external_records, length(local_records)),
                     state.owner_uid
                   ) do
              {:ok, external_records}
            end

          true ->
            {:error, :audit_checkpoint_external_diverged}
        end

      {:error, :audit_checkpoint_missing} ->
        with :ok <- append_records(state.external_path, local_records, state.owner_uid) do
          {:ok, local_records}
        end

      {:error, reason} ->
        {:error, {:audit_checkpoint_external_invalid, reason}}
    end
  end

  defp verify_external_consistency(%{external_path: nil}, _records), do: :ok

  defp verify_external_consistency(state, records) do
    case verify(state.external_path, state.signing_key, owner_uid: state.owner_uid) do
      {:ok, ^records} -> :ok
      {:ok, _other} -> {:error, :audit_checkpoint_external_diverged}
      {:error, reason} -> {:error, {:audit_checkpoint_external_invalid, reason}}
    end
  end

  defp append_records(path, records, owner_uid) do
    Enum.reduce_while(records, :ok, fn record, :ok ->
      case append_record(path, record, owner_uid) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp prefix?(prefix, records), do: Enum.take(records, length(prefix)) == prefix

  defp append_record(path, record, owner_uid) do
    with :ok <- prepare_parent(path, owner_uid),
         :ok <- appendable_path(path, owner_uid),
         :ok <- write_and_sync(path, [Jason.encode!(record), "\n"]),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} -> {:error, {:audit_checkpoint_append_failed, path, reason}}
    end
  end

  defp prepare_parent(path, owner_uid) do
    parent = Path.dirname(path)

    case File.lstat(parent) do
      {:error, :enoent} ->
        with :ok <- File.mkdir_p(parent),
             :ok <- File.chmod(parent, 0o700),
             :ok <- LocalIdentity.private_path(parent, owner_uid) do
          :ok
        end

      {:ok, %{type: :directory}} ->
        LocalIdentity.private_path(parent, owner_uid)

      {:ok, _stat} ->
        {:error, :audit_checkpoint_parent_not_directory}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp write_and_sync(path, contents) do
    case :file.open(String.to_charlist(path), [:append, :binary, :raw]) do
      {:ok, file} ->
        try do
          with :ok <- :file.write(file, contents),
               :ok <- :file.sync(file) do
            :ok
          end
        after
          :file.close(file)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp appendable_path(path, owner_uid) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %{type: :regular}} -> LocalIdentity.private_path(path, owner_uid)
      {:ok, _stat} -> {:error, :audit_checkpoint_path_not_regular}
      {:error, reason} -> {:error, reason}
    end
  end

  defp private_regular_file(path, owner_uid) do
    case File.lstat(path) do
      {:error, :enoent} ->
        {:error, :audit_checkpoint_missing}

      {:ok, %{type: :regular}} ->
        if is_nil(owner_uid), do: :ok, else: LocalIdentity.private_path(path, owner_uid)

      {:ok, _stat} ->
        {:error, :audit_checkpoint_path_not_regular}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_records(path) do
    with {:ok, encoded} <- File.read(path) do
      encoded
      |> String.split("\n", trim: true)
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, acc} ->
        case Jason.decode(line) do
          {:ok, record} when is_map(record) -> {:cont, {:ok, [record | acc]}}
          _other -> {:halt, {:error, :audit_checkpoint_json_invalid}}
        end
      end)
      |> case do
        {:ok, []} -> {:error, :audit_checkpoint_missing}
        {:ok, records} -> {:ok, Enum.reverse(records)}
        {:error, _reason} = error -> error
      end
    end
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :checkpoint, state.interval_ms)}
  end

  defp unhealthy_view(status, state, reason) do
    %{
      status: status,
      path: state.path,
      external_path: state.external_path,
      reason: public_reason(reason),
      last_result: result_view(state.last_result)
    }
  end

  defp result_view(nil), do: nil
  defp result_view({:ok, record}), do: %{status: :ok, sequence: record.sequence}
  defp result_view({:error, reason}), do: %{status: :error, reason: inspect(reason)}

  defp public_reason(reason) when is_atom(reason) or is_binary(reason), do: reason
  defp public_reason(reason), do: inspect(reason)

  defp public_record(record) do
    %{
      sequence: record["sequence"],
      created_at: record["created_at"],
      audit_position: record["audit_position"],
      audit_chain_head: record["audit_chain_head"],
      checkpoint_hash: record["checkpoint_hash"]
    }
  end

  defp audit_hash(event),
    do: Map.get(event, :audit_chain_hash, Map.get(event, "audit_chain_hash"))

  defp valid_hash?(value), do: is_binary(value) and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp sign(key, encoded),
    do: :crypto.mac(:hmac, :sha256, key, encoded) |> Base.url_encode64(padding: false)

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right),
    do: Twelvgaige.Security.secure_equal?(left, right)

  defp secure_equal?(_left, _right), do: false

  defp canonical_json(value), do: Jason.encode!(sort_maps(value))

  defp sort_maps(%{} = map) do
    map
    |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
    |> Map.new(fn {key, value} -> {to_string(key), sort_maps(value)} end)
  end

  defp sort_maps(values) when is_list(values), do: Enum.map(values, &sort_maps/1)
  defp sort_maps(value), do: value

  defp expand_optional(nil), do: nil
  defp expand_optional(path), do: Path.expand(path)
end
