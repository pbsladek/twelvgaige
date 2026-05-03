defmodule Twelvgaige.Store do
  @moduledoc """
  Store behaviour for round snapshots, manifests, events, and audit records.
  """

  @type round_id :: String.t()
  @type transition_id :: String.t()
  @type version :: non_neg_integer()

  @callback create_round(snapshot :: map(), manifest :: map(), audit_events :: [map()]) ::
              :ok | {:error, term()}

  @callback record_attempt_started(attempt :: map(), audit_events :: [map()]) ::
              :ok | :already_recorded | {:error, term()}

  @callback record_attempt_finished(attempt :: map(), audit_events :: [map()]) ::
              :ok | :already_recorded | {:error, term()}

  @callback record_tool_intent(intent :: map(), audit_events :: [map()]) ::
              :ok | :already_recorded | {:error, term()}

  @callback record_tool_result(result :: map(), audit_events :: [map()]) ::
              :ok | :already_recorded | {:error, term()}

  @callback list_attempt_journals(round_id()) :: {:ok, [map()]} | {:error, term()}
  @callback list_tool_journals(round_id()) :: {:ok, [map()]} | {:error, term()}
  @callback list_audit_events(round_id(), keyword()) :: {:ok, [map()]} | {:error, term()}

  @callback commit_transition(
              round_id(),
              expected_version :: version(),
              transition_id(),
              next_snapshot :: map(),
              events :: [map()],
              audit_events :: [map()]
            ) ::
              :ok | :already_committed | {:error, :version_conflict} | {:error, term()}

  @callback get_round(round_id()) :: {:ok, map()} | {:error, :not_found}
  @callback get_manifest(round_id()) :: {:ok, map()} | {:error, :not_found}
  @callback list_rounds(keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback list_shot_runs(round_id()) :: {:ok, [map()]} | {:error, term()}
  @callback list_round_events(round_id(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback await_round_events(round_id(), keyword()) :: {:ok, [map()]} | {:error, term()}
  @callback list_incomplete_rounds() :: {:ok, [map()]} | {:error, term()}
  @callback stats() :: {:ok, map()} | {:error, term()}
end
