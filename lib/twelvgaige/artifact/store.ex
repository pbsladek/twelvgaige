defmodule Twelvgaige.Artifact.Store do
  @moduledoc """
  Local encrypted artifact store with explicit retention classes.

  Payloads are encrypted with AES-256-GCM before touching disk. The caller owns
  key custody; the key is never written into an artifact or its reference.
  """

  use GenServer

  alias Twelvgaige.Artifact.Ref

  @aad_prefix "twelvgaige.artifact.v1"
  @raw_retention_days 30
  @security_retention_days 90

  defstruct [
    :root,
    :key,
    :current_key_id,
    :keyring,
    :raw_retention_days,
    :security_retention_days,
    holds: %{}
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.delete(opts, :name), name: name)
  end

  @spec put(term(), keyword()) :: {:ok, Ref.t()} | {:error, term()}
  def put(payload, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:put, payload, opts})
  end

  @spec get(Ref.t(), keyword()) :: {:ok, term()} | {:error, term()}
  def get(%Ref{} = ref, opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:get, ref})
  end

  @spec prune(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def prune(opts \\ []) do
    server = Keyword.get(opts, :server, __MODULE__)
    GenServer.call(server, {:prune, Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())})
  end

  @spec hold(String.t(), DateTime.t() | :indefinite, keyword()) :: :ok | {:error, term()}
  def hold(artifact_id, until, opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:hold, artifact_id, until})
  end

  @spec release_hold(String.t(), keyword()) :: :ok | {:error, term()}
  def release_hold(artifact_id, opts \\ []) do
    GenServer.call(Keyword.get(opts, :server, __MODULE__), {:release_hold, artifact_id})
  end

  @spec rotate_key(binary(), keyword()) :: {:ok, map()} | {:error, term()}
  def rotate_key(new_key, opts \\ []) do
    GenServer.call(
      Keyword.get(opts, :server, __MODULE__),
      {:rotate_key, new_key, Keyword.get(opts, :key_id)},
      :infinity
    )
  end

  def inventory(opts \\ []),
    do: GenServer.call(Keyword.get(opts, :server, __MODULE__), :inventory)

  @impl true
  def init(opts) do
    root = opts |> Keyword.fetch!(:root) |> Path.expand()
    key = Keyword.fetch!(opts, :key)
    key_id = Keyword.get(opts, :key_id, key_id(key))

    with :ok <- validate_key(key),
         :ok <- File.mkdir_p(root),
         :ok <- File.chmod(root, 0o700),
         {:ok, holds} <- load_holds(root) do
      previous_keys = Keyword.get(opts, :previous_keys, %{})

      {:ok,
       %__MODULE__{
         root: root,
         key: key,
         current_key_id: key_id,
         keyring: Map.put(previous_keys, key_id, key),
         raw_retention_days: Keyword.get(opts, :raw_retention_days, @raw_retention_days),
         security_retention_days:
           Keyword.get(opts, :security_retention_days, @security_retention_days),
         holds: holds
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:put, payload, opts}, _from, state) do
    reply = write_artifact(payload, opts, state)
    {:reply, reply, state}
  end

  def handle_call({:get, %Ref{} = ref}, _from, state) do
    {:reply, read_artifact(ref, state), state}
  end

  def handle_call({:prune, %DateTime{} = now}, _from, state) do
    {:reply, prune_expired(now, state), state}
  end

  def handle_call({:hold, artifact_id, until}, _from, state) do
    if valid_hold?(until) do
      holds = Map.put(state.holds, artifact_id, until)

      case persist_holds(state.root, holds) do
        :ok -> {:reply, :ok, %{state | holds: holds}}
        {:error, reason} -> {:reply, {:error, reason}, state}
      end
    else
      {:reply, {:error, :artifact_hold_invalid}, state}
    end
  end

  def handle_call({:release_hold, artifact_id}, _from, state) do
    holds = Map.delete(state.holds, artifact_id)

    case persist_holds(state.root, holds) do
      :ok -> {:reply, :ok, %{state | holds: holds}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:rotate_key, new_key, requested_key_id}, _from, state) do
    reply = rotate_artifacts(new_key, requested_key_id || key_id(new_key), state)

    case reply do
      {:ok, report, next} -> {:reply, {:ok, report}, next}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:inventory, _from, state) do
    files = artifact_files(state.root)

    {:reply,
     {:ok,
      %{
        artifacts: length(files),
        current_key_id: state.current_key_id,
        readable_key_ids: state.keyring |> Map.keys() |> Enum.sort(),
        holds: state.holds
      }}, state}
  end

  defp write_artifact(payload, opts, state) do
    id = Twelvgaige.ID.new(:artifact)
    now = Keyword.get(opts, :now, Twelvgaige.Clock.utc_now())
    retention_class = Keyword.get(opts, :retention_class, :raw)
    plaintext = :erlang.term_to_binary(payload, [:compressed])
    digest = sha256(plaintext)
    ref = build_ref(id, digest, byte_size(plaintext), retention_class, now, opts, state)
    nonce = :crypto.strong_rand_bytes(12)
    aad = aad(ref)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, state.key, nonce, plaintext, aad, true)

    envelope = %{
      "schema_version" => 1,
      "encoding_version" => 1,
      "algorithm" => "AES-256-GCM",
      "key_id" => state.current_key_id,
      "nonce" => Base.encode64(nonce),
      "tag" => Base.encode64(tag),
      "ciphertext" => Base.encode64(ciphertext),
      "ref" => encode_ref(ref)
    }

    path = artifact_path(state.root, id)
    temporary = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(temporary, Jason.encode!(envelope), [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      {:ok, ref}
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, reason}
    end
  rescue
    error -> {:error, {:artifact_write_failed, Exception.message(error)}}
  end

  # Authenticated AES-GCM plaintext is decoded with the restricted external
  # term decoder. Sobelow cannot see either protection from syntax alone.
  # sobelow_skip ["Misc.BinToTerm"]
  defp read_artifact(%Ref{} = expected_ref, state) do
    with {:ok, encoded} <- File.read(artifact_path(state.root, expected_ref.id)),
         {:ok, envelope} <- Jason.decode(encoded),
         :ok <- verify_envelope_header(envelope),
         {:ok, stored_ref} <- decode_ref(envelope["ref"]),
         :ok <- verify_ref(expected_ref, stored_ref),
         {:ok, nonce} <- Base.decode64(envelope["nonce"]),
         {:ok, tag} <- Base.decode64(envelope["tag"]),
         {:ok, ciphertext} <- Base.decode64(envelope["ciphertext"]),
         {:ok, key} <- envelope_key(envelope, state),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             aad(stored_ref),
             tag,
             false
           ),
         :ok <- verify_plaintext(plaintext, stored_ref) do
      {:ok, :erlang.binary_to_term(plaintext, [:safe])}
    else
      :error -> {:error, :artifact_authentication_failed}
      {:error, reason} -> {:error, reason}
    end
  rescue
    _error -> {:error, :artifact_invalid}
  end

  defp prune_expired(now, state) do
    with {:ok, names} <- File.ls(state.root) do
      removed =
        Enum.count(names, fn name ->
          path = Path.join(state.root, name)

          case artifact_expired?(path, now, state.holds) do
            true -> File.rm(path) == :ok
            false -> false
          end
        end)

      {:ok, removed}
    end
  end

  defp artifact_expired?(path, now, holds) do
    with {:ok, encoded} <- File.read(path),
         {:ok, %{"ref" => encoded_ref}} <- Jason.decode(encoded),
         {:ok, %Ref{id: id, expires_at: %DateTime{} = expires_at}} <- decode_ref(encoded_ref) do
      not held?(Map.get(holds, id), now) and DateTime.compare(expires_at, now) in [:lt, :eq]
    else
      _other -> false
    end
  end

  defp build_ref(id, digest, bytes, retention_class, now, opts, state) do
    %Ref{
      id: id,
      round_id: Keyword.get(opts, :round_id),
      session_id: Keyword.get(opts, :session_id),
      media_type: Keyword.get(opts, :media_type, "application/x-erlang-term"),
      digest: digest,
      bytes: bytes,
      retention_class: retention_class,
      created_at: now,
      expires_at: expires_at(retention_class, now, state)
    }
  end

  defp expires_at(:raw, now, state),
    do: DateTime.add(now, state.raw_retention_days * 86_400, :second)

  defp expires_at(:security, now, state),
    do: DateTime.add(now, state.security_retention_days * 86_400, :second)

  defp expires_at(:permanent, _now, _state), do: nil

  defp expires_at(other, _now, _state),
    do: raise(ArgumentError, "invalid retention class #{other}")

  defp validate_key(key) when is_binary(key) and byte_size(key) == 32, do: :ok
  defp validate_key(_key), do: {:error, :artifact_key_must_be_32_bytes}

  defp verify_envelope_header(%{
         "schema_version" => 1,
         "encoding_version" => 1,
         "algorithm" => "AES-256-GCM"
       }),
       do: :ok

  defp verify_envelope_header(_envelope), do: {:error, :artifact_unsupported_encoding}

  defp verify_ref(expected, actual) do
    if expected == actual, do: :ok, else: {:error, :artifact_reference_mismatch}
  end

  defp verify_plaintext(plaintext, %Ref{digest: digest, bytes: bytes}) do
    if byte_size(plaintext) == bytes and sha256(plaintext) == digest,
      do: :ok,
      else: {:error, :artifact_digest_mismatch}
  end

  defp aad(ref), do: @aad_prefix <> "\n" <> Jason.encode!(encode_ref(ref))

  defp encode_ref(%Ref{} = ref) do
    ref
    |> Map.from_struct()
    |> Map.update!(:retention_class, &Atom.to_string/1)
    |> Map.update!(:created_at, &DateTime.to_iso8601/1)
    |> Map.update!(:expires_at, fn
      nil -> nil
      value -> DateTime.to_iso8601(value)
    end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp decode_ref(%{} = encoded) do
    with {:ok, created_at, _offset} <- DateTime.from_iso8601(encoded["created_at"]),
         {:ok, expires_at} <- decode_time(encoded["expires_at"]),
         {:ok, retention_class} <- decode_retention(encoded["retention_class"]) do
      {:ok,
       struct!(Ref, %{
         id: encoded["id"],
         round_id: encoded["round_id"],
         session_id: encoded["session_id"],
         media_type: encoded["media_type"],
         digest: encoded["digest"],
         bytes: encoded["bytes"],
         retention_class: retention_class,
         created_at: created_at,
         expires_at: expires_at,
         schema_version: encoded["schema_version"],
         encoding_version: encoded["encoding_version"],
         encrypted: encoded["encrypted"]
       })}
    else
      _other -> {:error, :artifact_invalid_reference}
    end
  end

  defp decode_ref(_encoded), do: {:error, :artifact_invalid_reference}

  defp decode_time(nil), do: {:ok, nil}

  defp decode_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, time, _offset} -> {:ok, time}
      _other -> {:error, :invalid_time}
    end
  end

  defp decode_retention("raw"), do: {:ok, :raw}
  defp decode_retention("security"), do: {:ok, :security}
  defp decode_retention("permanent"), do: {:ok, :permanent}
  defp decode_retention(_value), do: {:error, :invalid_retention_class}

  defp artifact_path(root, id), do: Path.join(root, id <> ".artifact")
  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp rotate_artifacts(new_key, new_key_id, state) do
    with :ok <- validate_key(new_key),
         true <- is_binary(new_key_id) and byte_size(new_key_id) > 0,
         {:ok, staged} <- stage_rotation(new_key, new_key_id, state),
         :ok <- commit_rotation(staged) do
      next = %{
        state
        | key: new_key,
          current_key_id: new_key_id,
          keyring: %{new_key_id => new_key}
      }

      {:ok,
       %{
         artifacts_rotated: length(staged),
         old_key_id: state.current_key_id,
         new_key_id: new_key_id
       }, next}
    else
      false -> {:error, :artifact_key_id_invalid}
      {:error, reason} -> {:error, reason}
    end
  end

  defp stage_rotation(new_key, new_key_id, state) do
    rotation_id = Integer.to_string(System.unique_integer([:positive]))

    Enum.reduce_while(artifact_files(state.root), {:ok, []}, fn path, {:ok, acc} ->
      with {:ok, plaintext, ref} <- decrypt_plaintext(path, state),
           envelope <- encrypt_envelope(plaintext, ref, new_key, new_key_id),
           temp = path <> ".rotation-" <> rotation_id,
           backup = path <> ".rotation-backup-" <> rotation_id,
           :ok <- File.write(temp, Jason.encode!(envelope), [:binary, :exclusive]),
           :ok <- File.chmod(temp, 0o600) do
        {:cont, {:ok, [{path, temp, backup} | acc]}}
      else
        {:error, reason} ->
          Enum.each(acc, fn {_path, temp, _backup} -> File.rm(temp) end)
          {:halt, {:error, {:artifact_rotation_stage_failed, reason}}}
      end
    end)
    |> case do
      {:ok, staged} -> {:ok, Enum.reverse(staged)}
      error -> error
    end
  end

  defp commit_rotation(staged) do
    case Enum.reduce_while(staged, {:ok, []}, fn {path, temp, backup} = entry, {:ok, committed} ->
           with :ok <- File.rename(path, backup),
                :ok <- File.rename(temp, path) do
             {:cont, {:ok, [entry | committed]}}
           else
             {:error, reason} -> {:halt, {:error, reason, committed, entry}}
           end
         end) do
      {:ok, committed} ->
        Enum.each(committed, fn {_path, _temp, backup} -> File.rm(backup) end)
        :ok

      {:error, reason, committed, {path, temp, backup}} ->
        File.rm(temp)

        if File.exists?(backup) do
          File.rm(path)
          File.rename(backup, path)
        end

        Enum.each(committed, fn {path, _temp, backup} ->
          File.rm(path)
          File.rename(backup, path)
        end)

        Enum.each(staged, fn {_path, remaining_temp, _backup} -> File.rm(remaining_temp) end)
        {:error, {:artifact_rotation_commit_failed, reason}}
    end
  end

  defp decrypt_plaintext(path, state) do
    with {:ok, encoded} <- File.read(path),
         {:ok, envelope} <- Jason.decode(encoded),
         :ok <- verify_envelope_header(envelope),
         {:ok, ref} <- decode_ref(envelope["ref"]),
         {:ok, nonce} <- Base.decode64(envelope["nonce"]),
         {:ok, tag} <- Base.decode64(envelope["tag"]),
         {:ok, ciphertext} <- Base.decode64(envelope["ciphertext"]),
         {:ok, key} <- envelope_key(envelope, state),
         plaintext when is_binary(plaintext) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             key,
             nonce,
             ciphertext,
             aad(ref),
             tag,
             false
           ),
         :ok <- verify_plaintext(plaintext, ref) do
      {:ok, plaintext, ref}
    else
      :error -> {:error, :artifact_authentication_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  defp encrypt_envelope(plaintext, ref, key, key_id) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, nonce, plaintext, aad(ref), true)

    %{
      "schema_version" => 1,
      "encoding_version" => 1,
      "algorithm" => "AES-256-GCM",
      "key_id" => key_id,
      "nonce" => Base.encode64(nonce),
      "tag" => Base.encode64(tag),
      "ciphertext" => Base.encode64(ciphertext),
      "ref" => encode_ref(ref)
    }
  end

  defp envelope_key(%{"key_id" => key_id}, state) when is_binary(key_id) do
    case Map.fetch(state.keyring, key_id) do
      {:ok, key} -> {:ok, key}
      :error -> {:error, {:artifact_key_unavailable, key_id}}
    end
  end

  defp envelope_key(_legacy_envelope, state), do: {:ok, state.key}

  defp artifact_files(root) do
    case File.ls(root) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".artifact"))
        |> Enum.map(&Path.join(root, &1))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp valid_hold?(:indefinite), do: true
  defp valid_hold?(%DateTime{}), do: true
  defp valid_hold?(_until), do: false
  defp held?(:indefinite, _now), do: true
  defp held?(%DateTime{} = until, now), do: DateTime.compare(until, now) == :gt
  defp held?(_until, _now), do: false

  defp holds_path(root), do: Path.join(root, ".retention-holds.json")

  defp load_holds(root) do
    case File.read(holds_path(root)) do
      {:ok, encoded} ->
        with {:ok, holds} <- Jason.decode(encoded) do
          {:ok,
           Map.new(holds, fn {id, value} ->
             until =
               if value == "indefinite",
                 do: :indefinite,
                 else: value |> DateTime.from_iso8601() |> elem(1)

             {id, until}
           end)}
        end

      {:error, :enoent} ->
        {:ok, %{}}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _error -> {:error, :artifact_holds_invalid}
  end

  defp persist_holds(root, holds) do
    encoded =
      Map.new(holds, fn
        {id, :indefinite} -> {id, "indefinite"}
        {id, %DateTime{} = until} -> {id, DateTime.to_iso8601(until)}
      end)
      |> Jason.encode!()

    path = holds_path(root)
    temp = path <> ".tmp-" <> Integer.to_string(System.unique_integer([:positive]))

    with :ok <- File.write(temp, encoded, [:binary, :exclusive]),
         :ok <- File.chmod(temp, 0o600),
         :ok <- File.rename(temp, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temp)
        {:error, reason}
    end
  end

  defp key_id(key), do: "key_" <> String.slice(sha256(key), 0, 16)
end
