defmodule Twelvgaige.Authoring.ShellDraft do
  @moduledoc """
  Agent-assisted workflow draft generation.

  Drafting is intentionally non-executing. It accepts bounded source text,
  redacts it before provider transport, asks a configured LLM provider for a
  candidate workflow shell, then validates and strict-lints the candidate.
  """

  alias Twelvgaige.Authoring.Scaffold
  alias Twelvgaige.Error
  alias Twelvgaige.LLM
  alias Twelvgaige.Redactor
  alias Twelvgaige.Shell.Document
  alias Twelvgaige.Shell.Format.JSON
  alias Twelvgaige.Shell.Format.TOML
  alias Twelvgaige.Shell.Format.YAML
  alias Twelvgaige.Shell.Lint
  alias Twelvgaige.Shell.Workflow

  @hosted_providers MapSet.new(~w(anthropic openai gemini))
  @local_providers MapSet.new(~w(mock ollama))
  @default_max_input_bytes 64 * 1024
  @default_provider "mock"
  @default_model "mock-model"
  @draft_workflow_id "drafted_workflow"

  @type report :: %{
          provider: String.t(),
          model: String.t(),
          source_bytes: non_neg_integer(),
          redacted_bytes: non_neg_integer(),
          candidate: String.t(),
          workflow: Workflow.t(),
          lint: Lint.report(),
          status: :ok | :failed,
          exit_code: 0 | 1
        }

  @spec draft(term(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def draft(source, opts \\ [])

  def draft(source, opts) when is_binary(source) do
    provider = opts |> Keyword.get(:provider, @default_provider) |> stringify()
    model = opts |> Keyword.get(:model, @default_model) |> stringify()
    max_input_bytes = Keyword.get(opts, :max_input_bytes, @default_max_input_bytes)

    with :ok <- validate_provider(provider, opts),
         :ok <- validate_input_size(source, max_input_bytes),
         redacted_source <- Redactor.redact_text(source),
         {:ok, response} <-
           LLM.complete(provider, model, messages(redacted_source), llm_opts(opts)),
         {:ok, workflow} <- extract_workflow(response.content),
         lint <- Lint.run(workflow, strict?: true, path: "<draft>"),
         :ok <- require_lint_success(lint),
         {:ok, candidate} <- Document.encode(workflow, Keyword.get(opts, :format, :yaml)) do
      {:ok,
       %{
         provider: provider,
         model: model,
         source_bytes: byte_size(source),
         redacted_bytes: byte_size(redacted_source),
         candidate: candidate,
         workflow: workflow,
         lint: lint,
         status: lint.status,
         exit_code: lint.exit_code
       }}
    end
  end

  def draft(_source, _opts) do
    {:error,
     Error.new(:input_error, :invalid_shell, "draft source must be text",
       details: %{expected: "binary"}
     )}
  end

  @spec hosted_provider?(String.t() | atom()) :: boolean()
  def hosted_provider?(provider), do: MapSet.member?(@hosted_providers, stringify(provider))

  defp validate_provider(provider, opts) do
    cond do
      MapSet.member?(@local_providers, provider) ->
        :ok

      MapSet.member?(@hosted_providers, provider) and Keyword.get(opts, :allow_remote?, false) ->
        :ok

      MapSet.member?(@hosted_providers, provider) ->
        {:error,
         Error.new(
           :policy_error,
           :policy_denied,
           "hosted provider drafting requires --allow-remote",
           details: %{provider: provider}
         )}

      LLM.known_provider?(provider) ->
        :ok

      true ->
        {:error,
         Error.new(:llm_error, :llm_bad_request, "unknown LLM provider #{inspect(provider)}",
           details: %{provider: provider}
         )}
    end
  end

  defp validate_input_size(source, max_input_bytes)
       when is_integer(max_input_bytes) and max_input_bytes > 0 do
    if byte_size(source) <= max_input_bytes do
      :ok
    else
      {:error,
       Error.new(:llm_error, :llm_context_too_large, "draft input exceeds maximum size",
         details: %{bytes: byte_size(source), max_input_bytes: max_input_bytes}
       )}
    end
  end

  defp validate_input_size(_source, _max_input_bytes) do
    {:error,
     Error.new(:input_error, :invalid_shell, "max input bytes must be a positive integer")}
  end

  defp messages(redacted_source) do
    [
      %{
        role: "system",
        content: """
        You generate Twelvgaige workflow shells only.
        Return exactly one complete workflow shell as YAML, JSON, or TOML.
        Do not include prose outside the shell document.
        Do not execute tools or claim execution.
        Write-capable tools require a direct safety shot dependency.
        Every slug shot must have an explicit timeout and output_schema.
        """
      },
      %{
        role: "user",
        content: """
        Draft a Twelvgaige workflow shell from this request:

        #{redacted_source}
        """
      }
    ]
  end

  defp llm_opts(opts) do
    opts
    |> Keyword.drop([
      :allow_remote?,
      :format,
      :max_input_bytes,
      :model,
      :provider
    ])
    |> maybe_put_default_mock_response(opts)
  end

  defp maybe_put_default_mock_response(llm_opts, opts) do
    provider = opts |> Keyword.get(:provider, @default_provider) |> stringify()

    if provider == "mock" and not Keyword.has_key?(llm_opts, :response) and
         not Keyword.has_key?(llm_opts, :mock_handler) do
      Keyword.put(llm_opts, :response, default_mock_response())
    else
      llm_opts
    end
  end

  defp default_mock_response do
    with {:ok, expansion} <- Scaffold.expand("single-shot", @draft_workflow_id),
         {:ok, contents} <- Document.encode(expansion.workflow, :yaml) do
      contents
    else
      {:error, error} -> "draft generation failed: #{error.message}"
    end
  end

  defp extract_workflow(content) when is_binary(content) do
    content
    |> candidate_documents()
    |> Enum.reduce_while(
      {:error,
       Error.new(
         :compile_error,
         :invalid_shell,
         "draft response did not contain a workflow shell"
       )},
      fn candidate, _last_error ->
        case parse_workflow(candidate) do
          {:ok, workflow} -> {:halt, {:ok, workflow}}
          {:error, error} -> {:cont, {:error, error}}
        end
      end
    )
  end

  defp candidate_documents(content) do
    fenced =
      ~r/```(?:yaml|yml|json|toml)?\s*\n(?<body>.*?)\n```/s
      |> Regex.scan(content, capture: ["body"])
      |> List.flatten()

    (fenced ++ [content])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp parse_workflow(candidate) do
    [
      {YAML, "draft.yaml"},
      {JSON, "draft.json"},
      {TOML, "draft.toml"}
    ]
    |> Enum.reduce_while(nil, fn {parser, path}, _last_error ->
      case parser.parse(candidate, path) do
        {:ok, map} ->
          case Workflow.from_map(map) do
            {:ok, workflow} -> {:halt, {:ok, workflow}}
            {:error, error} -> {:cont, {:error, error}}
          end

        {:error, error} ->
          {:cont, {:error, error}}
      end
    end)
    |> case do
      {:ok, workflow} ->
        {:ok, workflow}

      {:error, %Error{} = error} ->
        {:error,
         Error.new(:compile_error, :invalid_shell, "draft candidate failed shell validation",
           details: Error.to_map(error)
         )}

      nil ->
        {:error,
         Error.new(:compile_error, :invalid_shell, "draft candidate failed shell validation")}
    end
  end

  defp require_lint_success(%{status: :ok}), do: :ok

  defp require_lint_success(report) do
    {:error,
     Error.new(:compile_error, :invalid_shell, "draft candidate failed strict lint",
       details: %{lint: Lint.to_map(report)}
     )}
  end

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)
end
