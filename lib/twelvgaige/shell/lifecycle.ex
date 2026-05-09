defmodule Twelvgaige.Shell.Lifecycle do
  @moduledoc """
  Digest-bound workflow lifecycle metadata updates.

  Lifecycle commands are authoring operations. They rewrite workflow metadata in
  canonical shell form and never affect runtime DAG execution by themselves.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Digest
  alias Twelvgaige.Shell.Document
  alias Twelvgaige.Shell.Workflow

  @type action :: :review | :approve | :deprecate | :retire

  @type result :: %{
          path: Path.t(),
          action: action(),
          lifecycle: :reviewed | :approved | :deprecated | :retired,
          actor: String.t(),
          scope: String.t() | nil,
          reason: String.t() | nil,
          digest: String.t(),
          format: Document.format(),
          original: String.t(),
          candidate: String.t(),
          diff: String.t(),
          workflow: Workflow.t()
        }

  @spec review(Path.t(), keyword()) :: {:ok, result()} | {:error, Error.t()}
  def review(path, opts \\ [])

  def review(path, opts) when is_binary(path) do
    with {:ok, actor} <- required_string(opts, :by, "--by is required"),
         {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         {:ok, result} <- update_lifecycle(path, workflow, format, :review, actor, opts) do
      {:ok, result}
    else
      {:ok, _other_shell} -> invalid("shell review requires a workflow shell", %{path: path})
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def review(_path, _opts), do: invalid("shell review requires a path")

  @spec approve(Path.t(), keyword()) :: {:ok, result()} | {:error, Error.t()}
  def approve(path, opts \\ [])

  def approve(path, opts) when is_binary(path) do
    with {:ok, actor} <- required_string(opts, :by, "--by is required"),
         {:ok, scope} <- required_string(opts, :scope, "--scope is required"),
         {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         :ok <- require_owner(workflow),
         {:ok, result} <-
           update_lifecycle(
             path,
             workflow,
             format,
             :approve,
             actor,
             Keyword.put(opts, :scope, scope)
           ) do
      {:ok, result}
    else
      {:ok, _other_shell} -> invalid("shell approve requires a workflow shell", %{path: path})
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def approve(_path, _opts), do: invalid("shell approve requires a path")

  @spec deprecate(Path.t(), keyword()) :: {:ok, result()} | {:error, Error.t()}
  def deprecate(path, opts \\ [])

  def deprecate(path, opts) when is_binary(path) do
    with {:ok, actor} <- required_string(opts, :by, "--by is required"),
         {:ok, reason} <- required_string(opts, :reason, "--reason is required"),
         {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         {:ok, result} <-
           update_terminal_lifecycle(path, workflow, format, :deprecate, actor, reason, opts) do
      {:ok, result}
    else
      {:ok, _other_shell} -> invalid("shell deprecate requires a workflow shell", %{path: path})
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def deprecate(_path, _opts), do: invalid("shell deprecate requires a path")

  @spec retire(Path.t(), keyword()) :: {:ok, result()} | {:error, Error.t()}
  def retire(path, opts \\ [])

  def retire(path, opts) when is_binary(path) do
    with {:ok, actor} <- required_string(opts, :by, "--by is required"),
         {:ok, reason} <- required_string(opts, :reason, "--reason is required"),
         {:ok, format} <- format_for_path(path),
         {:ok, %Workflow{} = workflow} <- Twelvgaige.validate_shell(path),
         {:ok, result} <-
           update_terminal_lifecycle(path, workflow, format, :retire, actor, reason, opts) do
      {:ok, result}
    else
      {:ok, _other_shell} -> invalid("shell retire requires a workflow shell", %{path: path})
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  def retire(_path, _opts), do: invalid("shell retire requires a path")

  defp update_lifecycle(path, %Workflow{} = workflow, format, action, actor, opts) do
    timestamp = Keyword.get_lazy(opts, timestamp_key(action), &timestamp/0)
    document = Document.to_map(workflow)
    metadata = Map.get(document, "metadata", %{})

    {lifecycle, binding_key} =
      case action do
        :review -> {"reviewed", "review"}
        :approve -> {"approved", "approval"}
      end

    base_document =
      document
      |> Map.put(
        "metadata",
        metadata |> Map.put("lifecycle", lifecycle) |> Map.delete(binding_key)
      )
      |> compact()

    with {:ok, %Workflow{} = base_workflow} <- Workflow.from_map(base_document),
         digest = Digest.workflow_subject_digest(base_workflow),
         binding <- binding(action, digest, actor, timestamp, opts),
         candidate_document <-
           put_in(base_document, ["metadata", binding_key], binding) |> compact(),
         {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         {:ok, original} <- Document.encode(workflow, format),
         {:ok, candidate} <- Document.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         action: action,
         lifecycle: lifecycle_atom(action),
         actor: actor,
         scope: Keyword.get(opts, :scope),
         reason: nil,
         digest: digest,
         format: format,
         original: original,
         candidate: candidate,
         diff: unified_diff(path, original, candidate),
         workflow: candidate_workflow
       }}
    end
  end

  defp lifecycle_atom(:review), do: :reviewed
  defp lifecycle_atom(:approve), do: :approved

  defp update_terminal_lifecycle(
         path,
         %Workflow{} = workflow,
         format,
         action,
         actor,
         reason,
         opts
       ) do
    lifecycle = terminal_lifecycle(action)

    candidate_document =
      workflow
      |> Document.to_map()
      |> Map.update("metadata", %{}, fn metadata ->
        metadata
        |> Map.put("lifecycle", Atom.to_string(lifecycle))
        |> Map.put("lifecycle_reason", reason)
        |> Map.put("generated_by", %{
          "tool" => "twelvgaige",
          "command" => "shell #{action}",
          "version" => Twelvgaige.version(),
          "source" => %{"kind" => "lifecycle", "id" => Atom.to_string(action)}
        })
        |> Map.delete("review")
        |> Map.delete("approval")
      end)
      |> compact()

    with {:ok, %Workflow{} = candidate_workflow} <- Workflow.from_map(candidate_document),
         digest = Digest.workflow_subject_digest(candidate_workflow),
         {:ok, original} <- Document.encode(workflow, format),
         {:ok, candidate} <- Document.encode(candidate_workflow, format) do
      {:ok,
       %{
         path: path,
         action: action,
         lifecycle: lifecycle,
         actor: actor,
         scope: Keyword.get(opts, :scope),
         reason: reason,
         digest: digest,
         format: format,
         original: original,
         candidate: candidate,
         diff: unified_diff(path, original, candidate),
         workflow: candidate_workflow
       }}
    end
  end

  defp terminal_lifecycle(:deprecate), do: :deprecated
  defp terminal_lifecycle(:retire), do: :retired

  defp binding(:review, digest, actor, timestamp, opts) do
    %{
      "workflow_digest" => digest,
      "reviewer" => actor,
      "reviewed_at" => timestamp,
      "scope" => Keyword.get(opts, :scope),
      "evidence_hash" => Keyword.get(opts, :evidence_hash)
    }
    |> compact()
  end

  defp binding(:approve, digest, actor, timestamp, opts) do
    %{
      "workflow_digest" => digest,
      "approver" => actor,
      "approved_at" => timestamp,
      "scope" => Keyword.fetch!(opts, :scope),
      "expires_at" => Keyword.get(opts, :expires_at),
      "evidence_hash" => Keyword.get(opts, :evidence_hash)
    }
    |> compact()
  end

  defp require_owner(%Workflow{metadata: %{owner: owner}}) when is_binary(owner), do: :ok

  defp require_owner(_workflow) do
    invalid("shell approve requires metadata.owner before approval")
  end

  defp required_string(opts, key, message) do
    case Keyword.get(opts, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> invalid(message)
    end
  end

  defp timestamp_key(:review), do: :reviewed_at
  defp timestamp_key(:approve), do: :approved_at

  defp timestamp do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp format_for_path(path) do
    case path |> Path.extname() |> String.downcase() do
      ".json" ->
        {:ok, :json}

      ".toml" ->
        {:ok, :toml}

      ".yaml" ->
        {:ok, :yaml}

      ".yml" ->
        {:ok, :yaml}

      extension ->
        invalid("unsupported shell file extension for lifecycle update", %{extension: extension})
    end
  end

  defp compact(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      value = compact(value)

      if value in [nil, %{}, []] do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp compact(list) when is_list(list), do: Enum.map(list, &compact/1)
  defp compact(value), do: value

  defp unified_diff(path, original, candidate) do
    original_lines = String.split(original, "\n", trim: false)
    candidate_lines = String.split(candidate, "\n", trim: false)
    max = max(length(original_lines), length(candidate_lines))

    body =
      0..(max - 1)
      |> Enum.flat_map(fn index ->
        old = Enum.at(original_lines, index)
        new = Enum.at(candidate_lines, index)

        cond do
          old == new and not is_nil(old) -> [" #{old}"]
          is_nil(old) -> ["+#{new}"]
          is_nil(new) -> ["-#{old}"]
          true -> ["-#{old}", "+#{new}"]
        end
      end)
      |> Enum.reject(&(&1 in [" ", "+", "-"]))
      |> Enum.join("\n")

    """
    --- #{path}
    +++ #{path}
    @@
    #{body}
    """
  end

  defp invalid(message, details \\ %{}) do
    {:error, Error.new(:input_error, :invalid_shell, message, details: details)}
  end
end
