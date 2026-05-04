defmodule Twelvgaige.Authoring.ShellAuthorReview do
  @moduledoc """
  Read-only provider-assisted shell authoring review.

  This is AC5's controlled hosted-authoring surface. It sends bounded, redacted
  shell source to a configured provider and returns a structured patch plan. It
  does not write files or apply patches.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.LLM
  alias Twelvgaige.Redactor
  alias Twelvgaige.Shell.Loader

  @hosted_providers MapSet.new(~w(anthropic openai gemini))
  @local_providers MapSet.new(~w(mock ollama))
  @default_max_input_bytes 64 * 1024
  @default_provider "mock"
  @default_model "mock-model"
  @tools ~w(shell_validate shell_graph shell_lint shell_inventory shell_impact shell_diff shell_normalize tool_catalog_read patch_plan)

  @type report :: %{
          kind: String.t(),
          status: :ok,
          provider: String.t(),
          model: String.t(),
          disclosure: map(),
          patch_plan: map(),
          exit_code: 0
        }

  @spec review(String.t(), keyword()) :: {:ok, report()} | {:error, Error.t()}
  def review(path, opts \\ [])

  def review(path, opts) when is_binary(path) do
    provider = opts |> Keyword.get(:provider, @default_provider) |> stringify()
    model = opts |> Keyword.get(:model, @default_model) |> stringify()
    max_input_bytes = Keyword.get(opts, :max_input_bytes, @default_max_input_bytes)

    with :ok <- validate_provider(provider, opts),
         {:ok, sources} <- source_documents(path),
         :ok <- validate_sources_size(sources, max_input_bytes),
         redacted_sources <- redact_sources(sources),
         {:ok, response} <-
           LLM.complete(provider, model, messages(redacted_sources), llm_opts(opts)),
         {:ok, changes} <- extract_changes(response.content),
         patch_plan <- patch_plan(path, sources, changes),
         disclosure <- disclosure(provider, model, sources, redacted_sources) do
      {:ok,
       %{
         kind: "twelvgaige.author_review",
         status: :ok,
         provider: provider,
         model: model,
         disclosure: disclosure,
         patch_plan: patch_plan,
         exit_code: 0
       }}
    end
  end

  def review(_path, _opts) do
    {:error, Error.new(:input_error, :invalid_shell, "author review path must be a string")}
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
           "hosted authoring review requires --allow-remote",
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

  defp source_documents(path) do
    expanded = Path.expand(path)

    cond do
      File.dir?(expanded) ->
        expanded
        |> shell_paths()
        |> read_sources()

      File.regular?(expanded) ->
        read_sources([expanded])

      true ->
        {:error,
         Error.new(:input_error, :invalid_shell, "author review path does not exist",
           details: %{path: expanded}
         )}
    end
  end

  defp shell_paths(dir) do
    Loader.supported_extensions()
    |> Enum.map(&Path.join(dir, "**/*#{&1}"))
    |> Enum.flat_map(&Path.wildcard/1)
    |> Enum.sort()
    |> Enum.uniq()
  end

  defp read_sources([]) do
    {:error, Error.new(:input_error, :invalid_shell, "author review found no shell files")}
  end

  defp read_sources(paths) do
    Enum.reduce_while(paths, {:ok, []}, fn path, {:ok, acc} ->
      case File.read(path) do
        {:ok, contents} ->
          {:cont, {:ok, [%{path: path, contents: contents, bytes: byte_size(contents)} | acc]}}

        {:error, reason} ->
          {:halt,
           {:error,
            Error.new(:input_error, :invalid_shell, "unable to read author review source",
              details: %{path: path, reason: inspect(reason)}
            )}}
      end
    end)
    |> case do
      {:ok, sources} -> {:ok, Enum.reverse(sources)}
      {:error, _error} = error -> error
    end
  end

  defp validate_sources_size(sources, max_input_bytes)
       when is_integer(max_input_bytes) and max_input_bytes > 0 do
    bytes = Enum.reduce(sources, 0, &(&1.bytes + &2))

    if bytes <= max_input_bytes do
      :ok
    else
      {:error,
       Error.new(:llm_error, :llm_context_too_large, "author review input exceeds maximum size",
         details: %{bytes: bytes, max_input_bytes: max_input_bytes}
       )}
    end
  end

  defp validate_sources_size(_sources, _max_input_bytes) do
    {:error,
     Error.new(:input_error, :invalid_shell, "max input bytes must be a positive integer")}
  end

  defp redact_sources(sources) do
    Enum.map(sources, fn source ->
      redacted = Redactor.redact_text(source.contents)
      Map.merge(source, %{redacted: redacted, redacted_bytes: byte_size(redacted)})
    end)
  end

  defp messages(redacted_sources) do
    [
      %{
        role: "system",
        content: """
        You review Twelvgaige workflow shells for maintainability.
        Return JSON only. Do not include prose outside JSON.
        Do not claim that files were edited. Do not generate executable patches.
        Return an object with a non-empty changes array.
        Each change must have action, description, and optional target.
        """
      },
      %{
        role: "user",
        content: """
        Review these Twelvgaige shell files and propose a read-only patch plan.

        #{source_block(redacted_sources)}
        """
      }
    ]
  end

  defp source_block(sources) do
    sources
    |> Enum.map_join("\n\n", fn source ->
      """
      <shell_source path="#{source.path}">
      #{source.redacted}
      </shell_source>
      """
    end)
  end

  defp llm_opts(opts) do
    opts
    |> Keyword.drop([:allow_remote?, :max_input_bytes, :model, :provider])
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
    Jason.encode!(%{
      "changes" => [
        %{
          "action" => "review",
          "target" => "collection",
          "description" => "Review graph, lint, ownership, and safety-gate posture."
        }
      ]
    })
  end

  defp extract_changes(content) when is_binary(content) do
    content
    |> candidate_json_documents()
    |> Enum.reduce_while(
      {:error, Error.new(:compile_error, :invalid_shell, "author review did not return JSON")},
      fn candidate, _last_error ->
        case Jason.decode(candidate) do
          {:ok, %{"changes" => changes}} -> {:halt, validate_changes(changes)}
          {:ok, changes} when is_list(changes) -> {:halt, validate_changes(changes)}
          {:ok, _other} -> {:cont, {:error, invalid_changes_error()}}
          {:error, _reason} -> {:cont, {:error, invalid_changes_error()}}
        end
      end
    )
  end

  defp candidate_json_documents(content) do
    fenced =
      ~r/```(?:json)?\s*\n(?<body>.*?)\n```/s
      |> Regex.scan(content, capture: ["body"])
      |> List.flatten()

    (fenced ++ [content])
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp validate_changes(changes) when is_list(changes) and changes != [] do
    changes
    |> Enum.reduce_while({:ok, []}, fn change, {:ok, acc} ->
      case normalize_change(change) do
        {:ok, change} -> {:cont, {:ok, [change | acc]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, changes} -> {:ok, Enum.reverse(changes)}
      {:error, _error} = error -> error
    end
  end

  defp validate_changes(_changes), do: {:error, invalid_changes_error()}

  defp normalize_change(%{"action" => action, "description" => description} = change)
       when is_binary(action) and action != "" and is_binary(description) and description != "" do
    {:ok,
     %{
       "action" => action,
       "description" => description,
       "target" => Map.get(change, "target")
     }
     |> compact()}
  end

  defp normalize_change(_change), do: {:error, invalid_changes_error()}

  defp invalid_changes_error do
    Error.new(:compile_error, :invalid_shell, "author review response must include changes")
  end

  defp patch_plan(path, sources, changes) do
    plan =
      %{
        "kind" => "twelvgaige.patch_plan",
        "path" => Path.expand(path),
        "base_digest" => digest(Enum.map_join(sources, "", & &1.contents)),
        "changes" => changes
      }

    Map.put(plan, "plan_digest", digest(:erlang.term_to_binary(plan)))
  end

  defp disclosure(provider, model, sources, redacted_sources) do
    %{
      "provider" => provider,
      "model" => model,
      "remote" => hosted_provider?(provider),
      "source_paths" => Enum.map(sources, & &1.path),
      "source_bytes" => Enum.reduce(sources, 0, &(&1.bytes + &2)),
      "redacted_bytes" => Enum.reduce(redacted_sources, 0, &(&1.redacted_bytes + &2)),
      "tools_exposed" => @tools,
      "writes_files" => false
    }
  end

  defp digest(contents) do
    "sha256:" <> (:crypto.hash(:sha256, contents) |> Base.encode16(case: :lower))
  end

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)

  defp compact(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) or value == [] or value == %{} end)
    |> Map.new()
  end
end
