defmodule Twelvgaige.Crypto.KeyManager.FileBackend do
  @moduledoc """
  Explicit JSON-file key backend for CI/headless development.

  This backend is not an OS keychain. It requires explicit insecure-backend
  acceptance and refuses group/world-readable key files on POSIX platforms.
  """

  import Bitwise

  @behaviour Twelvgaige.Crypto.KeyManager

  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyManager
  alias Twelvgaige.Crypto.KeyMaterial
  alias Twelvgaige.Security.FileMode

  @schema_version 1
  @private_file_mask 0o077

  @impl true
  def create_key(opts) do
    with :ok <- KeyManager.require_insecure_acceptance(opts),
         {:ok, path} <- key_path(opts),
         :ok <- ensure_new_key_path(path),
         key_id <- Keyword.get(opts, :id, "file-key"),
         key <- build_key(key_id, 1, :active, KeyManager.random_key_material(), nil),
         :ok <- write_key(path, key) do
      {:ok, key}
    end
  end

  @impl true
  def fetch_key(key_ref, opts) do
    with :ok <- KeyManager.require_insecure_acceptance(opts),
         {:ok, path} <- key_path(opts),
         {:ok, key} <- read_key(path),
         :ok <- match_key_ref(key, key_ref) do
      case key.status do
        :active -> {:ok, key}
        :retired -> {:error, :key_retired}
      end
    end
  end

  @impl true
  def rotate_key(key_ref, opts) do
    with :ok <- KeyManager.require_insecure_acceptance(opts),
         {:ok, path} <- key_path(opts),
         {:ok, key} <- read_key(path),
         :ok <- match_key_ref(key, key_ref),
         :active <- key.status do
      rotated =
        build_key(key.id, key.version + 1, :active, KeyManager.random_key_material(), :rotated)

      :ok = write_key(path, rotated)
      {:ok, rotated}
    else
      :retired -> {:error, :key_retired}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def retire_key(key_ref, opts) do
    with :ok <- KeyManager.require_insecure_acceptance(opts),
         {:ok, path} <- key_path(opts),
         {:ok, key} <- read_key(path),
         :ok <- match_key_ref(key, key_ref) do
      retired = %{key | status: :retired, retired_at: utc_now()}
      :ok = write_key(path, retired)
      {:ok, retired}
    end
  end

  defp key_path(opts) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _missing -> {:error, :key_path_required}
    end
  end

  defp ensure_new_key_path(path) do
    if File.exists?(path) do
      {:error, :key_already_exists}
    else
      FileMode.ensure_private_parent_dir(path)
    end
  end

  defp read_key(path) do
    with :ok <- reject_insecure_key_file(path),
         {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, key} <- decode_key(decoded) do
      {:ok, key}
    else
      {:error, :enoent} -> {:error, :key_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp write_key(path, %Key{} = key) do
    contents = key |> encode_key() |> Jason.encode!()

    with :ok <- FileMode.ensure_private_parent_dir(path),
         :ok <- File.write(path, contents, [:write]),
         :ok <- FileMode.chmod_if_supported(path, 0o600),
         :ok <- reject_insecure_key_file(path) do
      :ok
    end
  end

  defp encode_key(%Key{} = key) do
    %{
      "schema_version" => @schema_version,
      "id" => key.id,
      "backend" => "file",
      "status" => Atom.to_string(key.status),
      "version" => key.version,
      "key_material" => "base64:" <> Base.encode64(key.material.bytes),
      "created_at" => encode_datetime(key.created_at),
      "rotated_at" => encode_datetime(key.rotated_at),
      "retired_at" => encode_datetime(key.retired_at),
      "metadata" => key.metadata
    }
  end

  defp decode_key(
         %{
           "schema_version" => @schema_version,
           "id" => id,
           "status" => status,
           "version" => version,
           "key_material" => "base64:" <> encoded
         } = decoded
       )
       when is_binary(id) and is_integer(version) do
    with {:ok, bytes} <- Base.decode64(encoded),
         {:ok, material} <- KeyMaterial.new(bytes),
         {:ok, status} <- decode_status(status) do
      {:ok,
       %Key{
         id: id,
         backend: :file,
         status: status,
         version: version,
         material: material,
         created_at: decode_datetime(decoded["created_at"]),
         rotated_at: decode_datetime(decoded["rotated_at"]),
         retired_at: decode_datetime(decoded["retired_at"]),
         metadata: decoded["metadata"] || %{}
       }}
    end
  end

  defp decode_key(_decoded), do: {:error, :invalid_key_file}

  defp decode_status("active"), do: {:ok, :active}
  defp decode_status("retired"), do: {:ok, :retired}
  defp decode_status(_status), do: {:error, :invalid_key_status}

  defp match_key_ref(%Key{id: key_id}, key_id), do: :ok
  defp match_key_ref(%Key{}, _key_id), do: {:error, :key_not_found}

  defp reject_insecure_key_file(path) do
    case File.stat(path) do
      {:ok, %{mode: mode}} ->
        if (mode &&& @private_file_mask) == 0 do
          :ok
        else
          {:error, {:insecure_key_file_mode, path}}
        end

      {:error, _reason} = error ->
        error
    end
  end

  defp build_key(key_id, version, status, bytes, lifecycle) do
    {:ok, material} = KeyMaterial.new(bytes)
    now = utc_now()

    %Key{
      id: key_id,
      backend: :file,
      status: status,
      version: version,
      material: material,
      created_at: now,
      rotated_at: if(lifecycle == :rotated, do: now),
      metadata: %{"storage" => "file"}
    }
  end

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(_datetime), do: nil

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp decode_datetime(_value), do: nil

  defp utc_now, do: DateTime.truncate(Twelvgaige.Clock.utc_now(), :second)
end
