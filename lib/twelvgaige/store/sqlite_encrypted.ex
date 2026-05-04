defmodule Twelvgaige.Store.SQLiteEncrypted do
  @moduledoc """
  SQLCipher-backed SQLite store.

  This is intentionally separate from `Twelvgaige.Store.SQLite`. It fails closed
  unless the linked `ecto_sqlite3`/`exqlite` driver exposes SQLCipher and a key is
  supplied directly or through `:key_env`.
  """

  @behaviour Twelvgaige.Store

  alias Twelvgaige.Store.SQLite

  @impl Twelvgaige.Store
  def create_round(snapshot, manifest, audit_events) do
    GenServer.call(__MODULE__, {:create_round, snapshot, manifest, audit_events})
  end

  @impl Twelvgaige.Store
  def record_attempt_started(attempt, audit_events) do
    GenServer.call(__MODULE__, {:record_attempt_started, attempt, audit_events})
  end

  @impl Twelvgaige.Store
  def record_attempt_finished(attempt, audit_events) do
    GenServer.call(__MODULE__, {:record_attempt_finished, attempt, audit_events})
  end

  @impl Twelvgaige.Store
  def record_tool_intent(intent, audit_events) do
    GenServer.call(__MODULE__, {:record_tool_intent, intent, audit_events})
  end

  @impl Twelvgaige.Store
  def record_tool_result(result, audit_events) do
    GenServer.call(__MODULE__, {:record_tool_result, result, audit_events})
  end

  @impl Twelvgaige.Store
  def list_attempt_journals(round_id),
    do: GenServer.call(__MODULE__, {:list_attempt_journals, round_id})

  @impl Twelvgaige.Store
  def list_tool_journals(round_id),
    do: GenServer.call(__MODULE__, {:list_tool_journals, round_id})

  @impl Twelvgaige.Store
  def list_audit_events(round_id, opts),
    do: GenServer.call(__MODULE__, {:list_audit_events, round_id, opts})

  @impl Twelvgaige.Store
  def commit_transition(
        round_id,
        expected_version,
        transition_id,
        next_snapshot,
        events,
        audit_events
      ) do
    GenServer.call(
      __MODULE__,
      {:commit_transition, round_id, expected_version, transition_id, next_snapshot, events,
       audit_events}
    )
  end

  @impl Twelvgaige.Store
  def get_round(round_id), do: GenServer.call(__MODULE__, {:get_round, round_id})

  @impl Twelvgaige.Store
  def get_manifest(round_id), do: GenServer.call(__MODULE__, {:get_manifest, round_id})

  @impl Twelvgaige.Store
  def list_rounds(opts), do: GenServer.call(__MODULE__, {:list_rounds, opts})

  @impl Twelvgaige.Store
  def list_shot_runs(round_id), do: GenServer.call(__MODULE__, {:list_shot_runs, round_id})

  @impl Twelvgaige.Store
  def list_round_events(round_id, opts),
    do: GenServer.call(__MODULE__, {:list_round_events, round_id, opts})

  @impl Twelvgaige.Store
  def await_round_events(round_id, opts),
    do: GenServer.call(__MODULE__, {:await_round_events, round_id, opts}, :infinity)

  @impl Twelvgaige.Store
  def list_incomplete_rounds, do: GenServer.call(__MODULE__, :list_incomplete_rounds)

  @impl Twelvgaige.Store
  def stats, do: GenServer.call(__MODULE__, :stats)

  @spec backup(Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def backup(destination, opts \\ []) when is_binary(destination) do
    opts = Keyword.put_new(opts, :server, __MODULE__)
    SQLite.backup(destination, opts)
  end

  @spec restore_backup(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def restore_backup(source, destination, opts \\ [])
      when is_binary(source) and is_binary(destination) do
    SQLite.restore_backup(source, destination, opts)
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    opts =
      opts
      |> Keyword.put(:encrypted?, true)
      |> Keyword.put_new(:name, __MODULE__)

    SQLite.start_link(opts)
  end

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end
end
