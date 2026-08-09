defmodule Twelvgaige.DelegatedSession.Adapter do
  @moduledoc "Behaviour implemented by structured delegated-agent runtime drivers."

  @callback capabilities(map()) :: {:ok, map()} | {:error, term()}
  @callback prepare(map()) :: {:ok, term()} | {:error, term()}
  @callback authenticate(term(), term()) :: {:ok, term()} | {:error, term()}
  @callback start(term(), map()) :: {:ok, term(), map()} | {:error, term()}
  @callback resume(String.t(), term(), map()) :: {:ok, term(), map()} | {:error, term()}
  @callback send_input(term(), term()) :: :ok | {:error, term()}
  @callback decide(term(), String.t(), map()) :: :ok | {:error, term()}
  @callback cancel(term(), term()) :: :ok | {:error, term()}
  @callback snapshot(term()) :: {:ok, map()} | {:error, term()}
  @callback reconcile(map(), map()) :: {:ok, atom(), map()} | {:error, term()}
  @callback finalize(term()) :: {:ok, map()} | {:error, term()}
end
