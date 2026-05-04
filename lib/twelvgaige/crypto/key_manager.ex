defmodule Twelvgaige.Crypto.KeyManager do
  @moduledoc """
  Behaviour and dispatcher for key-management backends.

  This phase defines the contract only. It is not wired into an encrypted store
  yet, and env/file backends require explicit insecure-backend acceptance.
  """

  alias Twelvgaige.Crypto.Key

  @type key_ref :: String.t()
  @type backend :: module()
  @type backend_opts :: keyword()

  @callback create_key(keyword()) :: {:ok, Key.t()} | {:error, term()}
  @callback fetch_key(key_ref(), keyword()) :: {:ok, Key.t()} | {:error, term()}
  @callback rotate_key(key_ref(), keyword()) :: {:ok, Key.t()} | {:error, term()}
  @callback retire_key(key_ref(), keyword()) :: {:ok, Key.t()} | {:error, term()}

  @spec create_key(backend(), backend_opts()) :: {:ok, Key.t()} | {:error, term()}
  def create_key(backend, opts \\ []) when is_atom(backend) do
    backend.create_key(opts)
  end

  @spec fetch_key(backend(), key_ref(), backend_opts()) :: {:ok, Key.t()} | {:error, term()}
  def fetch_key(backend, key_ref, opts \\ []) when is_atom(backend) and is_binary(key_ref) do
    backend.fetch_key(key_ref, opts)
  end

  @spec rotate_key(backend(), key_ref(), backend_opts()) :: {:ok, Key.t()} | {:error, term()}
  def rotate_key(backend, key_ref, opts \\ []) when is_atom(backend) and is_binary(key_ref) do
    backend.rotate_key(key_ref, opts)
  end

  @spec retire_key(backend(), key_ref(), backend_opts()) :: {:ok, Key.t()} | {:error, term()}
  def retire_key(backend, key_ref, opts \\ []) when is_atom(backend) and is_binary(key_ref) do
    backend.retire_key(key_ref, opts)
  end

  @spec require_insecure_acceptance(keyword()) :: :ok | {:error, term()}
  def require_insecure_acceptance(opts) do
    if Keyword.get(opts, :allow_insecure_key_backend?, false) == true do
      :ok
    else
      {:error, :insecure_key_backend_not_allowed}
    end
  end

  @spec random_key_material() :: binary()
  def random_key_material, do: :crypto.strong_rand_bytes(32)
end
