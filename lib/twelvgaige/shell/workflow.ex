defmodule Twelvgaige.Shell.Workflow.Policy do
  @moduledoc false

  alias Twelvgaige.Shell.Validation, as: V

  @keys ~w(on_shot_failure on_condition_error on_store_error on_safety_reject on_cancel safety_scope resource_profile queue_timeout)

  @type t :: %__MODULE__{
          on_shot_failure: :fail_round | :halt_round,
          on_condition_error: :fail_round | :halt_round,
          on_store_error: :block_round | :fail_round,
          on_safety_reject: :halt_round | :fail_round,
          on_cancel: :cancel_round,
          safety_scope: :dependency | :round,
          resource_profile: :laptop | :minimal | :workstation | :server,
          queue_timeout_ms: non_neg_integer() | nil
        }

  defstruct on_shot_failure: :fail_round,
            on_condition_error: :fail_round,
            on_store_error: :block_round,
            on_safety_reject: :halt_round,
            on_cancel: :cancel_round,
            safety_scope: :dependency,
            resource_profile: :laptop,
            queue_timeout_ms: nil

  @spec from_map(term(), [term()]) :: {:ok, t()} | {:error, Twelvgaige.Error.t()}
  def from_map(nil, _path), do: {:ok, %__MODULE__{}}

  def from_map(map, path) do
    with {:ok, map} <- V.map(map, path),
         :ok <- V.known_keys(map, @keys, path),
         {:ok, on_shot_failure} <-
           V.optional_enum(map, :on_shot_failure, [:fail_round, :halt_round], :fail_round, path),
         {:ok, on_condition_error} <-
           V.optional_enum(
             map,
             :on_condition_error,
             [:fail_round, :halt_round],
             :fail_round,
             path
           ),
         {:ok, on_store_error} <-
           V.optional_enum(map, :on_store_error, [:block_round, :fail_round], :block_round, path),
         {:ok, on_safety_reject} <-
           V.optional_enum(map, :on_safety_reject, [:halt_round, :fail_round], :halt_round, path),
         {:ok, on_cancel} <-
           V.optional_enum(map, :on_cancel, [:cancel_round], :cancel_round, path),
         {:ok, safety_scope} <-
           V.optional_enum(map, :safety_scope, [:dependency, :round], :dependency, path),
         {:ok, resource_profile} <-
           V.optional_enum(
             map,
             :resource_profile,
             [:laptop, :minimal, :workstation, :server],
             :laptop,
             path
           ),
         {:ok, queue_timeout_ms} <- V.optional_duration_ms(map, :queue_timeout, nil, path) do
      {:ok,
       %__MODULE__{
         on_shot_failure: on_shot_failure,
         on_condition_error: on_condition_error,
         on_store_error: on_store_error,
         on_safety_reject: on_safety_reject,
         on_cancel: on_cancel,
         safety_scope: safety_scope,
         resource_profile: resource_profile,
         queue_timeout_ms: queue_timeout_ms
       }}
    end
  end
end

defmodule Twelvgaige.Shell.Workflow.Retry do
  @moduledoc false

  alias Twelvgaige.Shell.Validation, as: V

  @keys ~w(max_attempts backoff base_delay max_delay retryable_errors)
  @retryable_errors [
    :llm_timeout,
    :llm_rate_limited,
    :output_parse_error,
    :output_schema_violation,
    :tool_retryable,
    :tool_timeout,
    :shot_timeout,
    :resource_queue_timeout,
    :shot_crash
  ]

  @type t :: %__MODULE__{
          max_attempts: pos_integer(),
          backoff: :fixed | :linear | :exponential,
          base_delay_ms: non_neg_integer(),
          max_delay_ms: non_neg_integer(),
          retryable_errors: [atom()]
        }

  defstruct max_attempts: 1,
            backoff: :fixed,
            base_delay_ms: 0,
            max_delay_ms: 0,
            retryable_errors: []

  @spec from_map(term(), [term()]) :: {:ok, t()} | {:error, Twelvgaige.Error.t()}
  def from_map(nil, _path), do: {:ok, %__MODULE__{}}

  def from_map(map, path) do
    with {:ok, map} <- V.map(map, path),
         :ok <- V.known_keys(map, @keys, path),
         {:ok, max_attempts} <- V.optional_positive_integer(map, :max_attempts, 1, path),
         {:ok, backoff} <-
           V.optional_enum(map, :backoff, [:fixed, :linear, :exponential], :fixed, path),
         {:ok, base_delay_ms} <-
           V.optional_duration_ms(map, :base_delay, 0, path, allow_zero: true),
         {:ok, max_delay_ms} <- max_delay_ms(map, base_delay_ms, path),
         {:ok, retryable_errors} <- retryable_errors(map, path) do
      {:ok,
       %__MODULE__{
         max_attempts: max_attempts,
         backoff: backoff,
         base_delay_ms: base_delay_ms,
         max_delay_ms: max_delay_ms,
         retryable_errors: retryable_errors
       }}
    end
  end

  defp max_delay_ms(map, base_delay_ms, path) do
    case V.optional_duration_ms(map, :max_delay, base_delay_ms, path, allow_zero: true) do
      {:ok, max_delay_ms} when max_delay_ms >= base_delay_ms ->
        {:ok, max_delay_ms}

      {:ok, _max_delay_ms} ->
        V.error(
          :invalid_shell,
          "max_delay must be greater than or equal to base_delay",
          path ++ ["max_delay"]
        )

      {:error, _error} = error ->
        error
    end
  end

  defp retryable_errors(map, path) do
    case V.optional(map, :retryable_errors, []) do
      nil -> {:ok, []}
      value -> V.enum_list(value, @retryable_errors, path ++ ["retryable_errors"])
    end
  end
end

defmodule Twelvgaige.Shell.Workflow.Choke do
  @moduledoc false

  alias Twelvgaige.Shell.Validation, as: V

  @keys ~w(token_budget max_iterations tool_safety audit)

  @type t :: %__MODULE__{
          token_budget: pos_integer() | nil,
          max_iterations: pos_integer(),
          tool_safety: :read_only | :idempotent_write | :destructive | :irreversible,
          audit: :summary | :all
        }

  defstruct token_budget: nil,
            max_iterations: 6,
            tool_safety: :read_only,
            audit: :summary

  @spec from_map(term(), [term()]) :: {:ok, t()} | {:error, Twelvgaige.Error.t()}
  def from_map(nil, _path), do: {:ok, %__MODULE__{}}

  def from_map(map, path) do
    with {:ok, map} <- V.map(map, path),
         :ok <- V.known_keys(map, @keys, path),
         {:ok, token_budget} <- V.optional_positive_integer(map, :token_budget, nil, path),
         {:ok, max_iterations} <- V.optional_positive_integer(map, :max_iterations, 6, path),
         {:ok, tool_safety} <-
           V.optional_enum(
             map,
             :tool_safety,
             [:read_only, :idempotent_write, :destructive, :irreversible],
             :read_only,
             path
           ),
         {:ok, audit} <- V.optional_enum(map, :audit, [:summary, :all], :summary, path) do
      {:ok,
       %__MODULE__{
         token_budget: token_budget,
         max_iterations: max_iterations,
         tool_safety: tool_safety,
         audit: audit
       }}
    end
  end
end

defmodule Twelvgaige.Shell.Workflow.Shot do
  @moduledoc false

  alias Twelvgaige.Shell.Metadata
  alias Twelvgaige.Shell.Schema
  alias Twelvgaige.Shell.Validation, as: V
  alias Twelvgaige.Shell.Workflow.Choke
  alias Twelvgaige.Shell.Workflow.Retry

  @keys ~w(id kind agent description depends_on condition timeout tools retry choke output_schema prompt metadata)

  @type t :: %__MODULE__{
          id: String.t(),
          kind: :slug | :safety,
          agent: String.t() | nil,
          description: String.t() | nil,
          depends_on: [String.t()],
          condition: boolean() | String.t(),
          timeout_ms: pos_integer() | nil,
          tools: [String.t()],
          retry: Retry.t(),
          choke: Choke.t(),
          output_schema: Schema.t() | nil,
          prompt: String.t() | nil,
          metadata: Metadata.t()
        }

  defstruct [
    :id,
    :kind,
    :agent,
    :description,
    :timeout_ms,
    :output_schema,
    :prompt,
    depends_on: [],
    condition: true,
    tools: [],
    retry: %Retry{},
    choke: %Choke{},
    metadata: %Metadata{}
  ]

  @spec from_map(term(), [term()]) :: {:ok, t()} | {:error, Twelvgaige.Error.t()}
  def from_map(map, path) do
    with {:ok, map} <- V.map(map, path),
         :ok <- V.known_keys(map, @keys, path),
         {:ok, id} <- V.required_slug(map, :id, path),
         {:ok, kind} <- V.required_enum(map, :kind, [:slug, :safety], path),
         {:ok, agent} <- agent(map, kind, path),
         {:ok, description} <- V.optional_non_empty_string(map, :description, path),
         {:ok, depends_on} <- V.optional_slug_list(map, :depends_on, [], path),
         {:ok, condition} <- V.optional_condition(map, :condition, true, path),
         {:ok, timeout_ms} <- V.optional_duration_ms(map, :timeout, nil, path),
         {:ok, tools} <- V.optional_slug_list(map, :tools, [], path),
         :ok <- safety_tools(kind, tools, path),
         {:ok, retry} <- Retry.from_map(V.optional(map, :retry, nil), path ++ ["retry"]),
         {:ok, choke} <- Choke.from_map(V.optional(map, :choke, nil), path ++ ["choke"]),
         {:ok, output_schema} <- optional_schema(map, :output_schema, path),
         {:ok, prompt} <- V.optional_non_empty_string(map, :prompt, path),
         {:ok, metadata} <-
           Metadata.from_map(V.optional(map, :metadata, nil), path ++ ["metadata"], :shot) do
      {:ok,
       %__MODULE__{
         id: id,
         kind: kind,
         agent: agent,
         description: description,
         depends_on: depends_on,
         condition: condition,
         timeout_ms: timeout_ms,
         tools: tools,
         retry: retry,
         choke: choke,
         output_schema: output_schema,
         prompt: prompt,
         metadata: metadata
       }}
    end
  end

  defp agent(map, :safety, path) do
    case V.optional(map, :agent, nil) do
      nil -> {:ok, nil}
      value -> V.slug(value, path ++ ["agent"])
    end
  end

  defp agent(map, :slug, path) do
    V.required_slug(map, :agent, path)
  end

  defp safety_tools(:safety, [], _path), do: :ok
  defp safety_tools(:slug, _tools, _path), do: :ok

  defp safety_tools(:safety, _tools, path) do
    V.error(:invalid_shell, "safety shots must not declare tools", path ++ ["tools"])
  end

  defp optional_schema(map, field, path) do
    case V.optional(map, field, nil) do
      nil -> {:ok, nil}
      schema -> Schema.from_map(schema, path ++ [Atom.to_string(field)])
    end
  end
end

defmodule Twelvgaige.Shell.Workflow do
  @moduledoc """
  Declarative workflow shell loaded from a validated map.
  """

  alias Twelvgaige.Shell.Metadata
  alias Twelvgaige.Shell.Schema
  alias Twelvgaige.Shell.Validation, as: V
  alias Twelvgaige.Shell.Workflow.Policy
  alias Twelvgaige.Shell.Workflow.Shot

  @keys ~w(kind id name version timeout policy input_schema metadata shots)

  @type t :: %__MODULE__{
          kind: :workflow,
          id: String.t(),
          name: String.t() | nil,
          version: String.t(),
          timeout_ms: pos_integer() | nil,
          policy: Policy.t(),
          input_schema: Schema.t() | nil,
          metadata: Metadata.t(),
          shots: [Shot.t()]
        }

  defstruct [
    :id,
    :name,
    :version,
    :timeout_ms,
    :input_schema,
    kind: :workflow,
    policy: %Policy{},
    metadata: %Metadata{},
    shots: []
  ]

  @spec from_map(term()) :: {:ok, t()} | {:error, Twelvgaige.Error.t()}
  def from_map(map) do
    with {:ok, map} <- V.map(map, []),
         :ok <- V.known_keys(map, @keys, []),
         {:ok, :workflow} <- V.required_enum(map, :kind, [:workflow], []),
         {:ok, id} <- V.required_slug(map, :id, []),
         {:ok, name} <- V.optional_non_empty_string(map, :name, []),
         {:ok, version} <- V.required_semver(map, :version, []),
         {:ok, timeout_ms} <- V.optional_duration_ms(map, :timeout, nil, []),
         {:ok, policy} <- Policy.from_map(V.optional(map, :policy, nil), ["policy"]),
         {:ok, input_schema} <- optional_schema(map, :input_schema),
         {:ok, metadata} <-
           Metadata.from_map(V.optional(map, :metadata, nil), ["metadata"], :workflow),
         {:ok, shots} <- shots(map) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         version: version,
         timeout_ms: timeout_ms,
         policy: policy,
         input_schema: input_schema,
         metadata: metadata,
         shots: shots
       }}
    end
  end

  defp optional_schema(map, field) do
    case V.optional(map, field, nil) do
      nil -> {:ok, nil}
      schema -> Schema.from_map(schema, [Atom.to_string(field)])
    end
  end

  defp shots(map) do
    with {:ok, shots} <- V.required(map, :shots, []),
         {:ok, shots} <- non_empty_list(shots, ["shots"]),
         {:ok, shots} <- V.indexed_map(shots, ["shots"], &Shot.from_map/2),
         :ok <- unique_shot_ids(shots) do
      {:ok, shots}
    end
  end

  defp non_empty_list([], path), do: V.error(:invalid_shell, "shots must not be empty", path)
  defp non_empty_list(value, _path) when is_list(value), do: {:ok, value}

  defp non_empty_list(_value, path),
    do: V.error(:invalid_shell, "expected a non-empty shot list", path)

  defp unique_shot_ids(shots) do
    shots
    |> Enum.map(& &1.id)
    |> V.unique(["shots"])
  end
end
