defmodule Twelvgaige.DelegatedSession.Store do
  @moduledoc "Persistence contract for delegated-session records and normalized events."

  alias Twelvgaige.DelegatedSession
  alias Twelvgaige.DelegatedSession.Event

  @callback create(DelegatedSession.t()) :: :ok | {:error, term()}
  @callback put(DelegatedSession.t()) :: :ok | {:error, term()}
  @callback get(String.t()) :: {:ok, DelegatedSession.t()} | {:error, :not_found}
  @callback append_event(Event.t()) :: :ok | :duplicate | {:error, term()}
  @callback list_events(String.t(), keyword()) :: {:ok, [Event.t()]} | {:error, term()}
end
