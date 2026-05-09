defmodule Twelvgaige.CLI.Commands.RoundQuery do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.RoundFormat
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.Round.Watch

  import Twelvgaige.CLI.CommandHelpers,
    only: [
      format_command_error: 2,
      parse_format: 1,
      parse_non_negative_integer: 1,
      parse_positive_integer: 1
    ]

  @spec list([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def list(args) do
    with {:ok, opts} <- parse_list_opts(args) do
      case Twelvgaige.list_rounds(Keyword.take(opts, [:status])) do
        {:ok, rounds} ->
          {:ok, RoundFormat.round_list(rounds, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  @spec show(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def show(round_id, args) do
    with {:ok, opts} <- parse_show_opts(args) do
      case Twelvgaige.get_round(round_id) do
        {:ok, snapshot} ->
          {:ok, RoundFormat.snapshot(snapshot, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  @spec watch(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def watch(round_id, args) do
    with {:ok, opts} <- parse_watch_opts(args) do
      case Watch.collect(round_id, opts) do
        {:ok, events} ->
          {:ok, RoundFormat.events(events, opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  @spec stream_watch(String.t(), [String.t()], (String.t() -> term())) :: :ok | no_return()
  def stream_watch(round_id, args, write) do
    with {:ok, opts} <- parse_watch_opts(args) do
      result =
        Watch.stream(
          round_id,
          fn events ->
            write.(RoundFormat.events(events, opts[:format]))
            :ok
          end,
          opts
        )

      case result do
        {:ok, %{delivered: 0}} ->
          write.(RoundFormat.events([], opts[:format]))
          :ok

        {:ok, _summary} ->
          :ok

        {:error, error} ->
          output = format_command_error(error, :human)
          IO.write(:stderr, output)
          System.halt(ExitCode.for_error(error))

        {:halt, reason} ->
          output = format_command_error(reason, :human)
          IO.write(:stderr, output)
          System.halt(ExitCode.for_error(reason))
      end
    else
      {:error, error} ->
        output = format_command_error(error, :human)
        IO.write(:stderr, output)
        System.halt(ExitCode.for_error(error))
    end
  end

  defp parse_list_opts(args), do: parse_list_opts(args, format: :human)
  defp parse_list_opts([], opts), do: {:ok, opts}

  defp parse_list_opts(["--format", format | rest], opts) do
    parse_list_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_list_opts(["--status", status | rest], opts) do
    parse_list_opts(rest, Keyword.put(opts, :status, status))
  end

  defp parse_list_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_show_opts(args), do: parse_show_opts(args, format: :human)
  defp parse_show_opts([], opts), do: {:ok, opts}

  defp parse_show_opts(["--format", format | rest], opts) do
    parse_show_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_show_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_watch_opts(args),
    do:
      parse_watch_opts(args,
        format: :human,
        after_seq: 0,
        limit: 100,
        follow?: false,
        until_terminal?: false,
        timeout_ms: 30_000
      )

  defp parse_watch_opts([], opts), do: {:ok, opts}

  defp parse_watch_opts(["--format", format | rest], opts) do
    parse_watch_opts(rest, Keyword.put(opts, :format, parse_watch_format(format)))
  end

  defp parse_watch_opts(["--after-seq", seq | rest], opts) do
    case parse_non_negative_integer(seq) do
      {:ok, seq} ->
        parse_watch_opts(rest, Keyword.put(opts, :after_seq, seq))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--after-seq must be >= 0")}
    end
  end

  defp parse_watch_opts(["--limit", limit | rest], opts) do
    case parse_positive_integer(limit) do
      {:ok, limit} ->
        parse_watch_opts(rest, Keyword.put(opts, :limit, limit))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--limit must be > 0")}
    end
  end

  defp parse_watch_opts(["--follow" | rest], opts) do
    parse_watch_opts(rest, Keyword.put(opts, :follow?, true))
  end

  defp parse_watch_opts(["--until-terminal" | rest], opts) do
    opts =
      opts
      |> Keyword.put(:follow?, true)
      |> Keyword.put(:until_terminal?, true)

    parse_watch_opts(rest, opts)
  end

  defp parse_watch_opts(["--timeout-ms", timeout_ms | rest], opts) do
    case parse_non_negative_integer(timeout_ms) do
      {:ok, timeout_ms} ->
        parse_watch_opts(rest, Keyword.put(opts, :timeout_ms, timeout_ms))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--timeout-ms must be >= 0")}
    end
  end

  defp parse_watch_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_watch_format("ndjson"), do: :ndjson
  defp parse_watch_format("human"), do: :human
  defp parse_watch_format(_other), do: :human
end
