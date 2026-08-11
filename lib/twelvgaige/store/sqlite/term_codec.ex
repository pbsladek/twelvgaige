defmodule Twelvgaige.Store.SQLite.TermCodec do
  @moduledoc false

  @external_term_modules [
    Calendar.ISO,
    DateTime,
    MapSet,
    Twelvgaige.Audit.Event,
    Twelvgaige.Error,
    Twelvgaige.LLM.Response,
    Twelvgaige.Loadout,
    Twelvgaige.Pattern.Compiled,
    Twelvgaige.Round.Event,
    Twelvgaige.Round.Manifest,
    Twelvgaige.Round.ShotRun,
    Twelvgaige.Round.Snapshot,
    Twelvgaige.Shell.Agent,
    Twelvgaige.Shell.Agent.Choke,
    Twelvgaige.Shell.Agent.Memory,
    Twelvgaige.Shell.Agent.Tools,
    Twelvgaige.Shell.Workflow,
    Twelvgaige.Shell.Workflow.Choke,
    Twelvgaige.Shell.Workflow.Policy,
    Twelvgaige.Shell.Workflow.Retry,
    Twelvgaige.Shell.Workflow.Shot,
    Twelvgaige.Shot.Attempt,
    Twelvgaige.Shot.AttemptJournal,
    Twelvgaige.Shot.State,
    Twelvgaige.Tool.Call,
    Twelvgaige.Tool.IntentJournal
  ]

  @external_term_atoms [
    :actor,
    :agent,
    :attempt,
    :audit,
    :awaiting_reconciliation,
    :awaiting_safety,
    :backoff,
    :base_delay_ms,
    :block_round,
    :calendar,
    :cancelled,
    :cancel_round,
    :choke,
    :complete,
    :completed,
    :completed_at,
    :condition,
    :created_at,
    :day,
    :dependency,
    :depends_on,
    :description,
    :effective_resource_profile,
    :error,
    :estimated,
    :event_type,
    :fail_round,
    false,
    :fixed,
    :halt_round,
    :history,
    :hour,
    :id,
    :idempotency_metadata,
    :input,
    :input_schema,
    :input_tokens,
    :kind,
    :failed,
    :halted,
    :laptop,
    :max_attempts,
    :max_delay_ms,
    :max_iterations,
    :microsecond,
    :minute,
    :month,
    :name,
    :next_retry_at,
    :occurred_at,
    :ok,
    :on_cancel,
    :on_condition_error,
    :on_safety_reject,
    :on_shot_failure,
    :on_store_error,
    :output,
    :output_schema,
    :output_tokens,
    :path,
    :payload,
    :pending,
    :policy,
    :prompt,
    :queue_timeout_ms,
    :queued,
    :read_only,
    :requires_tool_intents,
    :resource_profile,
    :result,
    :retry,
    :retryable_errors,
    :round_completed,
    :round_created,
    :round_id,
    :round_state_transition,
    :round_version,
    :retrying,
    :running,
    :safety_level,
    :safety_scope,
    :schema_version,
    :second,
    :seq,
    :shell_id,
    :shell_version,
    :shot_attempt_finished,
    :shot_attempt_started,
    :shot_id,
    :shots,
    :skipped,
    :slug,
    :source,
    :started,
    :started_at,
    :status,
    :std_offset,
    :store_status,
    :summary,
    :time_zone,
    :timeout_ms,
    :tool_call_count,
    :token_budget,
    :tool_safety,
    :tools,
    :total_tokens,
    :transition_id,
    true,
    :type,
    :usage,
    :utc_offset,
    :version,
    :intent_recorded,
    :write,
    :workflow,
    :workflow_hash,
    :year,
    :zone_abbr
  ]

  @spec preload() :: :ok
  def preload do
    Enum.each(@external_term_modules, &Code.ensure_loaded/1)
    Enum.each(@external_term_atoms, &Atom.to_string/1)
    :ok
  end

  @spec encode(term()) :: binary()
  def encode(term), do: :erlang.term_to_binary(term)

  @spec decode(binary()) :: term()
  # The `:safe` option forbids creation of new atoms, references, funs, and
  # other unsafe external terms. This is the reviewed exception to Sobelow's
  # syntax-only BinToTerm finding.
  # sobelow_skip ["Misc.BinToTerm"]
  def decode(binary), do: :erlang.binary_to_term(binary, [:safe])

  @spec encode_nullable(term() | nil) :: binary() | nil
  def encode_nullable(nil), do: nil
  def encode_nullable(term), do: encode(term)

  @spec decode_nullable(binary() | nil) :: term() | nil
  def decode_nullable(nil), do: nil
  def decode_nullable(binary), do: decode(binary)
end
