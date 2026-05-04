defmodule Twelvgaige.Store.Config do
  @moduledoc """
  Store backend configuration shared by the application supervisor and Breech.

  The default remains the in-memory store. Setting `:store` application config
  or `TWELVGAIGE_STORE_FILE` switches the runtime to a durable backend before
  the supervision tree starts.
  """

  alias Twelvgaige.Store.File, as: FileStore
  alias Twelvgaige.Store.Memory
  alias Twelvgaige.Store.SQLite
  alias Twelvgaige.Store.SQLiteEncrypted

  @env_store_file "TWELVGAIGE_STORE_FILE"
  @env_store_sqlite "TWELVGAIGE_STORE_SQLITE"
  @env_store_sqlcipher "TWELVGAIGE_STORE_SQLCIPHER"
  @env_store_sqlcipher_key "TWELVGAIGE_STORE_SQLCIPHER_KEY"

  @type config :: module() | {module(), keyword()}

  @spec resolve(keyword()) :: config()
  def resolve(opts \\ []) do
    opts[:store]
    |> fallback(Application.get_env(:twelvgaige, :store))
    |> fallback(env_store())
    |> fallback(Memory)
    |> normalize!()
  end

  @spec child_spec(config()) :: module() | {module(), keyword()}
  def child_spec(config), do: normalize!(config)

  @spec module(config()) :: module()
  def module(module) when is_atom(module), do: module
  def module({module, opts}) when is_atom(module) and is_list(opts), do: module

  defp fallback(nil, fallback), do: fallback
  defp fallback(value, _fallback), do: value

  defp env_store do
    env_sqlcipher_store() || env_sqlite_store() || env_file_store()
  end

  defp env_sqlcipher_store do
    case System.get_env(@env_store_sqlcipher) do
      nil -> nil
      "" -> nil
      path -> {SQLiteEncrypted, path: path, key_env: @env_store_sqlcipher_key}
    end
  end

  defp env_sqlite_store do
    case System.get_env(@env_store_sqlite) do
      nil -> nil
      "" -> nil
      path -> {SQLite, path: path}
    end
  end

  defp env_file_store do
    case System.get_env(@env_store_file) do
      nil -> nil
      "" -> nil
      path -> {FileStore, path: path}
    end
  end

  defp normalize!(module) when is_atom(module), do: module
  defp normalize!({module, opts}) when is_atom(module) and is_list(opts), do: {module, opts}
end
