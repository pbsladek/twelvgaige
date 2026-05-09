defmodule Twelvgaige.CLI.Commands.ShellLifecycleActions do
  @moduledoc false

  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.CLI.AuthoringIO
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Shell
  alias Twelvgaige.Shell.Lifecycle

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_human_json_format: 1, root_opts: 1]

  @spec lifecycle(:review | :approve | :deprecate | :retire, String.t(), [String.t()]) ::
          {:ok, String.t(), non_neg_integer()}
  def lifecycle(action, path, args) do
    with {:ok, opts} <- parse_lifecycle_args(args, action),
         {:ok, root} <- AuthoringRoot.resolve(root_opts(opts)),
         :ok <- AuthoringRoot.ensure_within_root(path, root),
         {:ok, result} <- run_lifecycle_action(action, path, opts) do
      if opts[:write?] do
        write_lifecycle(result, opts)
      else
        {:ok, format_lifecycle(result, opts[:format], false), 0}
      end
    else
      {:error, error} ->
        format = args |> parse_lifecycle_error_format(action)
        {:ok, format_command_error(error, format), ExitCode.for_error(error)}
    end
  end

  defp write_lifecycle(result, opts) do
    with :ok <- AuthoringIO.write_file(result.path, result.candidate),
         {:ok, %Shell.Workflow{} = workflow} <- Twelvgaige.validate_shell(result.path),
         true <- lifecycle_binding_current?(workflow, result.action) do
      {:ok, format_lifecycle(result, opts[:format], true), 0}
    else
      {:ok, _other_shell} ->
        error =
          Twelvgaige.Error.new(
            :input_error,
            :invalid_shell,
            "lifecycle shell did not validate as a workflow",
            details: %{path: result.path}
          )

        AuthoringIO.format_write_error(error)

      false ->
        error =
          Twelvgaige.Error.new(
            :compile_error,
            :invalid_shell,
            "lifecycle binding digest was not current after write",
            details: %{path: result.path, action: Atom.to_string(result.action)}
          )

        AuthoringIO.format_write_error(error)

      {:error, error} ->
        AuthoringIO.format_write_error(error)
    end
  end

  defp lifecycle_binding_current?(workflow, :review),
    do: Twelvgaige.Shell.Digest.current_binding?(workflow, :review)

  defp lifecycle_binding_current?(workflow, :approve),
    do: Twelvgaige.Shell.Digest.current_binding?(workflow, :approval)

  defp lifecycle_binding_current?(_workflow, action) when action in [:deprecate, :retire],
    do: true

  defp run_lifecycle_action(:review, path, opts) do
    Lifecycle.review(path,
      by: opts[:by],
      scope: opts[:scope],
      evidence_hash: opts[:evidence_hash]
    )
  end

  defp run_lifecycle_action(:approve, path, opts) do
    Lifecycle.approve(path,
      by: opts[:by],
      scope: opts[:scope],
      expires_at: opts[:expires_at],
      evidence_hash: opts[:evidence_hash]
    )
  end

  defp run_lifecycle_action(:deprecate, path, opts) do
    Lifecycle.deprecate(path,
      by: opts[:by],
      reason: opts[:reason],
      scope: opts[:scope]
    )
  end

  defp run_lifecycle_action(:retire, path, opts) do
    Lifecycle.retire(path,
      by: opts[:by],
      reason: opts[:reason],
      scope: opts[:scope]
    )
  end

  defp parse_lifecycle_args(args, action) do
    parse_lifecycle_opts(args,
      action: action,
      by: nil,
      scope: nil,
      reason: nil,
      evidence_hash: nil,
      expires_at: nil,
      write?: false,
      format: :human,
      root: nil
    )
  end

  defp parse_lifecycle_opts([], opts) do
    cond do
      is_nil(opts[:by]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--by is required")}

      opts[:action] == :approve and is_nil(opts[:scope]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--scope is required")}

      opts[:action] in [:deprecate, :retire] and is_nil(opts[:reason]) ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--reason is required")}

      true ->
        {:ok, opts}
    end
  end

  defp parse_lifecycle_opts(["--by", by | rest], opts),
    do: parse_lifecycle_opts(rest, Keyword.put(opts, :by, by))

  defp parse_lifecycle_opts(["--scope", scope | rest], opts),
    do: parse_lifecycle_opts(rest, Keyword.put(opts, :scope, scope))

  defp parse_lifecycle_opts(["--reason", reason | rest], opts),
    do: parse_lifecycle_opts(rest, Keyword.put(opts, :reason, reason))

  defp parse_lifecycle_opts(["--evidence-hash", evidence_hash | rest], opts),
    do: parse_lifecycle_opts(rest, Keyword.put(opts, :evidence_hash, evidence_hash))

  defp parse_lifecycle_opts(["--expires-at", expires_at | rest], opts),
    do: parse_lifecycle_opts(rest, Keyword.put(opts, :expires_at, expires_at))

  defp parse_lifecycle_opts(["--write" | rest], opts),
    do: parse_lifecycle_opts(rest, Keyword.put(opts, :write?, true))

  defp parse_lifecycle_opts(["--dry-run" | rest], opts),
    do: parse_lifecycle_opts(rest, Keyword.put(opts, :write?, false))

  defp parse_lifecycle_opts(["--format", format | rest], opts) do
    case parse_human_json_format(format) do
      {:ok, format} -> parse_lifecycle_opts(rest, Keyword.put(opts, :format, format))
      {:error, _reason} = error -> error
    end
  end

  defp parse_lifecycle_opts(["--root", root | rest], opts),
    do: parse_lifecycle_opts(rest, Keyword.put(opts, :root, root))

  defp parse_lifecycle_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_lifecycle_error_format(args, action) do
    args
    |> parse_lifecycle_args(action)
    |> case do
      {:ok, opts} -> opts[:format]
      {:error, _error} -> :human
    end
  end

  defp format_lifecycle(result, :json, wrote?) do
    %{
      path: result.path,
      action: Atom.to_string(result.action),
      lifecycle: Atom.to_string(result.lifecycle),
      actor: result.actor,
      scope: result.scope,
      reason: result.reason,
      digest: result.digest,
      format: Atom.to_string(result.format),
      wrote: wrote?,
      diff: result.diff
    }
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp format_lifecycle(result, :human, true) do
    """
    marked workflow #{result.action}: #{result.path}
    lifecycle: #{result.lifecycle}
    actor: #{result.actor}
    scope: #{result.scope || "none"}
    reason: #{result.reason || "none"}
    digest: #{result.digest}
    wrote: true
    """
  end

  defp format_lifecycle(result, :human, false) do
    """
    dry run: shell #{result.action} #{result.path}
    lifecycle: #{result.lifecycle}
    actor: #{result.actor}
    scope: #{result.scope || "none"}
    reason: #{result.reason || "none"}
    digest: #{result.digest}
    wrote: false

    #{result.diff}
    """
  end
end
