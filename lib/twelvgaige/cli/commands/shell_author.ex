defmodule Twelvgaige.CLI.Commands.ShellAuthor do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.Authoring.ShellAuthorReview
  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  @spec review(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def review(path, args) do
    with {:ok, opts} <- parse_review_opts(args),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, report} <- ShellAuthorReview.review(path, review_opts(opts)) do
      {:ok, format_review(report, opts[:format]), report.exit_code}
    else
      {:error, error} ->
        format = args |> parse_review_error_format()
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp parse_review_opts(args) do
    parse_review_opts(args,
      provider: "mock",
      model: "mock-model",
      allow_remote?: false,
      max_input_bytes: 64 * 1024,
      format: :human,
      root: nil
    )
  end

  defp parse_review_opts([], opts), do: {:ok, opts}

  defp parse_review_opts(["--provider", provider | rest], opts) do
    parse_review_opts(rest, Keyword.put(opts, :provider, provider))
  end

  defp parse_review_opts(["--model", model | rest], opts) do
    parse_review_opts(rest, Keyword.put(opts, :model, model))
  end

  defp parse_review_opts(["--allow-remote" | rest], opts) do
    parse_review_opts(rest, Keyword.put(opts, :allow_remote?, true))
  end

  defp parse_review_opts(["--max-input-bytes", value | rest], opts) do
    case parse_positive_integer(value, "--max-input-bytes") do
      {:ok, max_input_bytes} ->
        parse_review_opts(rest, Keyword.put(opts, :max_input_bytes, max_input_bytes))

      {:error, _reason} = error ->
        error
    end
  end

  defp parse_review_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_review_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_review_opts(["--root", root | rest], opts) do
    parse_review_opts(rest, Keyword.put(opts, :root, root))
  end

  defp parse_review_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_review_error_format(args) do
    args
    |> parse_review_opts()
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp parse_positive_integer(value, label) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 ->
        {:ok, integer}

      _other ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "#{label} must be a positive integer")}
    end
  end

  defp review_opts(opts) do
    [
      provider: opts[:provider],
      model: opts[:model],
      allow_remote?: opts[:allow_remote?],
      max_input_bytes: opts[:max_input_bytes]
    ]
  end

  defp format_review(report, :json) do
    report
    |> Map.delete(:exit_code)
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_review(report, :human) do
    disclosure = report.disclosure
    plan = report.patch_plan

    changes =
      plan["changes"]
      |> Enum.map(fn change ->
        target = Map.get(change, "target", "collection")
        "  - #{change["action"]} #{target}: #{change["description"]}"
      end)
      |> Enum.join("\n")

    paths =
      disclosure["source_paths"]
      |> Enum.map(&"  - #{&1}")
      |> Enum.join("\n")

    tools = Enum.join(disclosure["tools_exposed"], ", ")

    """
    Shell author review: #{plan["path"]}
    Status: OK
    Provider: #{report.provider}
    Model: #{report.model}
    Remote: #{disclosure["remote"]}
    Writes files: false
    Source bytes: #{disclosure["source_bytes"]}
    Redacted bytes: #{disclosure["redacted_bytes"]}
    Tools exposed: #{tools}
    Plan digest: #{plan["plan_digest"]}
    Base digest: #{plan["base_digest"]}
    Source paths:
    #{paths}
    Changes:
    #{changes}
    """
  end
end
