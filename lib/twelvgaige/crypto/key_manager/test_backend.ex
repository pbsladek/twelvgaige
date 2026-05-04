defmodule Twelvgaige.Crypto.KeyManager.TestBackend do
  @moduledoc """
  Process-local key backend for tests.

  State is held in the calling process dictionary to keep the backend dependency
  free and isolated by test process.
  """

  @behaviour Twelvgaige.Crypto.KeyManager

  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyManager
  alias Twelvgaige.Crypto.KeyMaterial

  @store_key {__MODULE__, :keys}

  @impl true
  def create_key(opts) do
    key_id = Keyword.get(opts, :id, "test-key-#{System.unique_integer([:positive])}")
    key = build_key(key_id, 1, :active, KeyManager.random_key_material(), nil)
    put_key(key)
    {:ok, key}
  end

  @impl true
  def fetch_key(key_id, _opts) do
    case get_key(key_id) do
      %Key{status: :active} = key -> {:ok, key}
      %Key{status: :retired} -> {:error, :key_retired}
      nil -> {:error, :key_not_found}
    end
  end

  @impl true
  def rotate_key(key_id, _opts) do
    case get_key(key_id) do
      %Key{status: :active, version: version} ->
        key = build_key(key_id, version + 1, :active, KeyManager.random_key_material(), :rotated)
        put_key(key)
        {:ok, key}

      %Key{status: :retired} ->
        {:error, :key_retired}

      nil ->
        {:error, :key_not_found}
    end
  end

  @impl true
  def retire_key(key_id, _opts) do
    case get_key(key_id) do
      %Key{} = key ->
        retired = %{key | status: :retired, retired_at: utc_now()}
        put_key(retired)
        {:ok, retired}

      nil ->
        {:error, :key_not_found}
    end
  end

  defp build_key(key_id, version, status, bytes, lifecycle) do
    {:ok, material} = KeyMaterial.new(bytes)
    now = utc_now()

    %Key{
      id: key_id,
      backend: :test,
      status: status,
      version: version,
      material: material,
      created_at: now,
      rotated_at: if(lifecycle == :rotated, do: now),
      metadata: %{"purpose" => "test"}
    }
  end

  defp put_key(%Key{} = key) do
    Process.put(@store_key, Map.put(all_keys(), key.id, key))
  end

  defp get_key(key_id), do: Map.get(all_keys(), key_id)

  defp all_keys do
    case Process.get(@store_key) do
      %{} = keys -> keys
      _missing -> %{}
    end
  end

  defp utc_now, do: DateTime.truncate(Twelvgaige.Clock.utc_now(), :second)
end
