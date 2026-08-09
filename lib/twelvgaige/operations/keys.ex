defmodule Twelvgaige.Operations.Keys do
  @moduledoc "OS-protected operational master key and wrapped artifact data-key persistence."

  alias Twelvgaige.Crypto.KeyManager

  alias Twelvgaige.Crypto.KeyManager.{
    LinuxSecretServiceBackend,
    MacOSKeychainBackend,
    WindowsDPAPIBackend
  }

  alias Twelvgaige.Operations.Paths

  @schema_version 1
  @master_id "twelvgaige.operations.master"

  def resolve(opts \\ []) do
    with {:ok, master} <- resolve_master(opts),
         key_file <- Keyword.get(opts, :artifact_key_file, artifact_key_file(opts)),
         {:ok, artifact} <- load_or_create_artifact_keys(master.bytes, key_file) do
      {:ok,
       %{
         master_id: master.id,
         master_key: master.bytes,
         master_backend: master.backend,
         artifact_key_file: key_file,
         artifact_key: artifact.active.key,
         artifact_key_id: artifact.active.id,
         artifact_previous_keys: Map.new(artifact.previous, &{&1.id, &1.key}),
         session_signing_key: derive(master.bytes, "session-control"),
         audit_export_key: derive(master.bytes, "audit-export")
       }}
    end
  end

  def rotate_artifact(keys, artifact_store, opts \\ []) when is_map(keys) do
    next = %{
      id: Keyword.get(opts, :key_id, "artifact-" <> unique_id()),
      key: :crypto.strong_rand_bytes(32)
    }

    current = %{id: keys.artifact_key_id, key: keys.artifact_key}
    previous = [current]

    with :ok <-
           write_artifact_keys(
             keys.master_key,
             keys.artifact_key_file,
             next,
             previous
           ),
         {:ok, report} <-
           Twelvgaige.Artifact.Store.rotate_key(next.key,
             server: artifact_store,
             key_id: next.id
           ) do
      {:ok, report,
       %{
         keys
         | artifact_key: next.key,
           artifact_key_id: next.id,
           artifact_previous_keys: %{current.id => current.key}
       }}
    else
      {:error, reason} ->
        _ =
          write_artifact_keys(
            keys.master_key,
            keys.artifact_key_file,
            current,
            Enum.map(keys.artifact_previous_keys, fn {id, key} -> %{id: id, key: key} end)
          )

        {:error, reason}
    end
  end

  def metadata(keys) do
    %{
      master_id: keys.master_id,
      master_backend: keys.master_backend,
      artifact_key_id: keys.artifact_key_id,
      artifact_previous_key_ids: keys.artifact_previous_keys |> Map.keys() |> Enum.sort(),
      artifact_key_file: keys.artifact_key_file
    }
  end

  def artifact_key_file(opts \\ []),
    do: Path.join([Paths.data_root(opts), "keys", "artifact-key.json"])

  defp resolve_master(opts) do
    case Keyword.get(opts, :operations_master_key) do
      key when is_binary(key) and byte_size(key) == 32 ->
        {:ok,
         %{
           id: Keyword.get(opts, :operations_master_key_id, "injected-master"),
           bytes: key,
           backend: :injected
         }}

      nil ->
        backend = Keyword.get(opts, :key_manager, default_backend())
        key_id = Keyword.get(opts, :operations_master_key_id, @master_id)
        backend_opts = Keyword.get(opts, :key_manager_opts, [])

        case KeyManager.fetch_key(backend, key_id, backend_opts) do
          {:ok, key} ->
            {:ok, %{id: key.id, bytes: first_32(key.material.bytes), backend: key.backend}}

          {:error, :key_not_found} ->
            with {:ok, key} <-
                   KeyManager.create_key(backend, Keyword.put(backend_opts, :id, key_id)) do
              {:ok, %{id: key.id, bytes: first_32(key.material.bytes), backend: key.backend}}
            end

          {:error, reason} ->
            {:error, {:operations_master_key_unavailable, reason}}
        end

      _invalid ->
        {:error, :operations_master_key_invalid}
    end
  end

  defp load_or_create_artifact_keys(master, path) do
    case File.read(path) do
      {:ok, encoded} -> decode_key_file(master, encoded)
      {:error, :enoent} -> create_artifact_key_file(master, path)
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_artifact_key_file(master, path) do
    active = %{id: "artifact-" <> unique_id(), key: :crypto.strong_rand_bytes(32)}

    with :ok <- write_artifact_keys(master, path, active, []) do
      {:ok, %{active: active, previous: []}}
    end
  end

  defp write_artifact_keys(master, path, active, previous) do
    payload = %{
      "schema_version" => @schema_version,
      "active" => wrap(master, active),
      "previous" => Enum.map(previous, &wrap(master, &1))
    }

    atomic_private_write(path, Jason.encode!(payload))
  end

  defp decode_key_file(master, encoded) do
    with {:ok, %{"schema_version" => @schema_version} = payload} <- Jason.decode(encoded),
         {:ok, active} <- unwrap(master, payload["active"]),
         {:ok, previous} <- unwrap_many(master, payload["previous"] || []) do
      {:ok, %{active: active, previous: previous}}
    else
      {:error, reason} -> {:error, {:operations_artifact_key_file_invalid, reason}}
      _other -> {:error, :operations_artifact_key_file_invalid}
    end
  end

  defp wrap(master, %{id: id, key: key}) do
    nonce = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, master, nonce, key, aad(id), true)

    %{
      "id" => id,
      "algorithm" => "AES-256-GCM",
      "nonce" => Base.encode64(nonce),
      "tag" => Base.encode64(tag),
      "ciphertext" => Base.encode64(ciphertext)
    }
  end

  defp unwrap(
         master,
         %{
           "id" => id,
           "algorithm" => "AES-256-GCM",
           "nonce" => nonce,
           "tag" => tag,
           "ciphertext" => ciphertext
         }
       ) do
    with {:ok, nonce} <- Base.decode64(nonce),
         {:ok, tag} <- Base.decode64(tag),
         {:ok, ciphertext} <- Base.decode64(ciphertext),
         key when is_binary(key) <-
           :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             master,
             nonce,
             ciphertext,
             aad(id),
             tag,
             false
           ),
         true <- byte_size(key) == 32 do
      {:ok, %{id: id, key: key}}
    else
      _other -> {:error, :artifact_key_authentication_failed}
    end
  end

  defp unwrap(_master, _value), do: {:error, :artifact_key_envelope_invalid}

  defp unwrap_many(master, values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case unwrap(master, value) do
        {:ok, key} -> {:cont, {:ok, [key | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, keys} -> {:ok, Enum.reverse(keys)}
      error -> error
    end
  end

  defp unwrap_many(_master, _values), do: {:error, :artifact_key_previous_invalid}

  defp atomic_private_write(path, encoded) do
    temporary = path <> ".tmp-" <> unique_id()

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.chmod(Path.dirname(path), 0o700),
         :ok <- File.write(temporary, encoded, [:binary, :exclusive]),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(temporary)
        {:error, reason}
    end
  end

  defp derive(master, purpose), do: :crypto.mac(:hmac, :sha256, master, "twelvgaige/" <> purpose)
  defp aad(id), do: "twelvgaige.operations.artifact-key.v1\n" <> id
  defp first_32(bytes), do: binary_part(bytes, 0, 32)
  defp unique_id, do: :crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false)

  defp default_backend do
    case :os.type() do
      {:unix, :darwin} -> MacOSKeychainBackend
      {:win32, _name} -> WindowsDPAPIBackend
      _other -> LinuxSecretServiceBackend
    end
  end
end
