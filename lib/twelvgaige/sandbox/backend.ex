defmodule Twelvgaige.Sandbox.Backend do
  @moduledoc "Backend-neutral outer sandbox lifecycle."

  @callback probe(keyword()) :: {:ok, map()} | {:error, term()}
  @callback prepare(map(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback create(map(), keyword()) :: {:ok, String.t(), map()} | {:error, term()}
  @callback start(String.t(), keyword()) :: {:ok, term()} | {:error, term()}
  @callback inspect(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  @callback stop(String.t(), keyword()) :: :ok | {:error, term()}
  @callback destroy(String.t(), keyword()) :: :ok | {:error, term()}
  @callback export(String.t(), Path.t(), [Path.t()], keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback reconcile(map(), keyword()) :: {:ok, atom(), map()} | {:error, term()}

  @optional_callbacks export: 4
end
