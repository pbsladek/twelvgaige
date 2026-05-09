defmodule Twelvgaige.CLI.Commands.RoundControl do
  @moduledoc false

  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers,
    only: [encode_line: 1, format_command_error: 2, parse_format: 1]

  @spec safety_decision(:approve | :reject, String.t(), [String.t()]) ::
          {:ok, String.t(), non_neg_integer()}
  def safety_decision(decision, round_id, args) do
    with {:ok, opts} <- parse_safety_opts(args),
         {:ok, shot_id} <- required_safety_shot(opts) do
      result =
        case decision do
          :approve ->
            Twelvgaige.approve_safety(round_id, shot_id,
              reason: opts[:reason],
              actor: "human:cli"
            )

          :reject ->
            Twelvgaige.reject_safety(round_id, shot_id,
              reason: opts[:reason],
              actor: "human:cli"
            )
        end

      case result do
        :ok ->
          {:ok, format_safety_decision(decision, round_id, shot_id, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  @spec cancel(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def cancel(round_id, args) do
    with {:ok, opts} <- parse_cancel_opts(args) do
      case Twelvgaige.cancel_round(round_id, reason: opts[:reason], actor: "human:cli") do
        :ok ->
          {:ok, format_cancel(round_id, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_safety_opts(args), do: parse_safety_opts(args, format: :human)

  defp parse_safety_opts([], opts), do: {:ok, opts}

  defp parse_safety_opts(["--shot", shot_id | rest], opts) do
    parse_safety_opts(rest, Keyword.put(opts, :shot_id, shot_id))
  end

  defp parse_safety_opts(["--reason", reason | rest], opts) do
    parse_safety_opts(rest, Keyword.put(opts, :reason, reason))
  end

  defp parse_safety_opts(["--format", format | rest], opts) do
    parse_safety_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_safety_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp required_safety_shot(opts) do
    case Keyword.get(opts, :shot_id) do
      shot_id when is_binary(shot_id) and shot_id != "" ->
        {:ok, shot_id}

      _missing ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--shot is required")}
    end
  end

  defp parse_cancel_opts(args), do: parse_cancel_opts(args, format: :human)

  defp parse_cancel_opts([], opts), do: {:ok, opts}

  defp parse_cancel_opts(["--reason", reason | rest], opts) do
    parse_cancel_opts(rest, Keyword.put(opts, :reason, reason))
  end

  defp parse_cancel_opts(["--format", format | rest], opts) do
    parse_cancel_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_cancel_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp format_safety_decision(decision, round_id, shot_id, :json) do
    %{
      status: "accepted",
      decision: Atom.to_string(decision),
      round_id: round_id,
      shot_id: shot_id
    }
    |> encode_line()
  end

  defp format_safety_decision(decision, round_id, shot_id, :human) do
    "Safety #{decision} accepted for #{round_id} #{shot_id}\n"
  end

  defp format_cancel(round_id, :json) do
    encode_line(%{status: "accepted", decision: "cancel", round_id: round_id})
  end

  defp format_cancel(round_id, :human), do: "Cancel accepted for #{round_id}\n"
end
