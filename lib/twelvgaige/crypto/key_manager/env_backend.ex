defmodule Twelvgaige.Crypto.KeyManager.EnvBackend do
  @moduledoc """
  Explicit environment-variable key backend for CI/headless development.

  This backend is intentionally marked insecure. It only resolves active keys
  and cannot create, rotate, or retire environment variables.
  """

  @behaviour Twelvgaige.Crypto.KeyManager

  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyManager
  alias Twelvgaige.Crypto.KeyMaterial

  @impl true
  def create_key(_opts), do: {:error, :unsupported_key_operation}

  @impl true
  def fetch_key(key_ref, opts) do
    with :ok <- KeyManager.require_insecure_acceptance(opts),
         env when is_binary(env) and env != "" <- env_name(key_ref, opts),
         value when is_binary(value) and value != "" <- System.get_env(env),
         {:ok, bytes} <- decode_key_value(value),
         {:ok, material} <- KeyMaterial.new(bytes) do
      {:ok,
       %Key{
         id: key_ref,
         backend: :env,
         status: :active,
         version: 1,
         material: material,
         created_at: nil,
         metadata: %{"env" => env}
       }}
    else
      {:error, _reason} = error -> error
      nil -> {:error, :key_not_found}
      "" -> {:error, :key_not_found}
    end
  end

  @impl true
  def rotate_key(_key_ref, _opts), do: {:error, :unsupported_key_operation}

  @impl true
  def retire_key(_key_ref, _opts), do: {:error, :unsupported_key_operation}

  defp env_name(key_ref, opts) do
    case Keyword.get(opts, :env) || Keyword.get(opts, :env_name) do
      env when is_binary(env) and env != "" -> env
      _missing -> key_ref
    end
  end

  defp decode_key_value("base64:" <> encoded), do: Base.decode64(encoded)
  defp decode_key_value(value), do: {:ok, value}
end
