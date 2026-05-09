defmodule Twelvgaige.CLI.Commands.RoundRun do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.RoundFormat
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Shell.Admission, as: ShellAdmission

  import Twelvgaige.CLI.CommandHelpers,
    only: [format_command_error: 2, parse_format: 1]

  @spec run(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def run(path, args) do
    with {:ok, opts} <- parse_round_opts(args),
         {:ok, input} <- read_input(opts.input) do
      format = opts.format

      case run_round_mode(path, input, opts) do
        {:ok, %Snapshot{} = snapshot} ->
          {:ok, RoundFormat.snapshot(snapshot, format), ExitCode.for_snapshot(snapshot)}

        {:ok, round_id} when is_binary(round_id) ->
          {:ok, RoundFormat.detached_round(round_id, format), 0}

        {:error, error} ->
          {:ok, format_command_error(error, format), ExitCode.for_error(error)}
      end
    else
      {:error, error} ->
        {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_round_opts(args),
    do:
      parse_round_opts(args, %{
        input: nil,
        format: :human,
        profile: nil,
        admission_policy: nil,
        approve_safety?: false,
        detach?: false,
        agent_shells: [],
        discover_agents?: true,
        trusted_root?: true
      })

  defp parse_round_opts([], %{input: nil} = opts), do: {:ok, %{opts | input: "{}"}}
  defp parse_round_opts([], opts), do: {:ok, opts}

  defp parse_round_opts(["--input", input | rest], opts) do
    parse_round_opts(rest, %{opts | input: input})
  end

  defp parse_round_opts(["--format", format | rest], opts) do
    parse_round_opts(rest, %{opts | format: parse_format(format)})
  end

  defp parse_round_opts(["--profile", profile | rest], opts) do
    case Twelvgaige.RuntimeProfile.normalize(profile) do
      {:ok, profile} -> parse_round_opts(rest, %{opts | profile: profile})
      {:error, _reason} = error -> error
    end
  end

  defp parse_round_opts(["--admission", policy | rest], opts) do
    case ShellAdmission.normalize_policy(policy) do
      {:ok, :manual} -> parse_round_opts(rest, %{opts | admission_policy: nil})
      {:ok, policy} -> parse_round_opts(rest, %{opts | admission_policy: policy})
      {:error, _reason} = error -> error
    end
  end

  defp parse_round_opts(["--agent-shell", path | rest], opts) do
    parse_round_opts(rest, %{opts | agent_shells: opts.agent_shells ++ [path]})
  end

  defp parse_round_opts(["--no-agent-discovery" | rest], opts) do
    parse_round_opts(rest, %{opts | discover_agents?: false})
  end

  defp parse_round_opts(["--untrusted-root" | rest], opts) do
    parse_round_opts(rest, %{opts | trusted_root?: false})
  end

  defp parse_round_opts(["--approve-safety" | rest], opts) do
    parse_round_opts(rest, %{opts | approve_safety?: true})
  end

  defp parse_round_opts(["--detach" | rest], opts) do
    parse_round_opts(rest, %{opts | detach?: true})
  end

  defp parse_round_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp round_run_opts(opts) do
    []
    |> maybe_put_profile(opts)
    |> maybe_put_admission_policy(opts)
    |> maybe_put_approve_all_safety(opts)
    |> maybe_put_agent_shells(opts)
    |> maybe_put_agent_discovery(opts)
  end

  defp maybe_put_profile(run_opts, %{profile: nil}), do: run_opts

  defp maybe_put_profile(run_opts, %{profile: profile}),
    do: Keyword.put(run_opts, :profile, profile)

  defp maybe_put_admission_policy(run_opts, %{admission_policy: nil}), do: run_opts

  defp maybe_put_admission_policy(run_opts, %{admission_policy: policy}) do
    Keyword.put(run_opts, :admission_policy, policy)
  end

  defp maybe_put_approve_all_safety(run_opts, %{approve_safety?: true}) do
    Keyword.put(run_opts, :approve_all_safety?, true)
  end

  defp maybe_put_approve_all_safety(run_opts, _opts), do: run_opts
  defp maybe_put_agent_shells(run_opts, %{agent_shells: []}), do: run_opts

  defp maybe_put_agent_shells(run_opts, %{agent_shells: agent_shells}) do
    Keyword.put(run_opts, :agent_shells, agent_shells)
  end

  defp maybe_put_agent_discovery(run_opts, opts) do
    run_opts
    |> Keyword.put(:discover_agents?, opts.discover_agents?)
    |> Keyword.put(:trusted_root?, opts.trusted_root?)
  end

  defp run_round_mode(path, input, %{detach?: true} = opts) do
    Twelvgaige.run_round(path, input, round_run_opts(opts))
  end

  defp run_round_mode(path, input, opts) do
    Twelvgaige.run_round_sync(path, input, round_run_opts(opts))
  end

  defp read_input("-") do
    :stdio
    |> IO.read(:eof)
    |> decode_json("stdin")
  end

  defp read_input(input) when is_binary(input) do
    trimmed = String.trim_leading(input)

    if String.starts_with?(trimmed, ["{", "["]) do
      decode_json(input, "inline JSON")
    else
      case File.read(input) do
        {:ok, contents} ->
          decode_json(contents, input)

        {:error, reason} ->
          {:error,
           Twelvgaige.Error.new(:input_error, :invalid_shell, "unable to read input file",
             details: %{path: input, reason: inspect(reason)}
           )}
      end
    end
  end

  defp decode_json(contents, source) do
    case Jason.decode(contents) do
      {:ok, map} when is_map(map) ->
        {:ok, map}

      {:ok, _other} ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "round input must be a JSON object",
           details: %{source: source}
         )}

      {:error, error} ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "invalid JSON input",
           details: %{source: source, reason: Exception.message(error)}
         )}
    end
  end
end
