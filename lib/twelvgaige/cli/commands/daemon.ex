defmodule Twelvgaige.CLI.Commands.Daemon do
  @moduledoc false

  alias Twelvgaige.Breech.Daemon
  alias Twelvgaige.Breech.IPC.Endpoint
  alias Twelvgaige.Breech.IPC.Server
  alias Twelvgaige.CLI.ExitCode
  alias Twelvgaige.CLI.ResultEnvelope

  import Twelvgaige.CLI.CommandHelpers,
    only: [encode_line: 1, format_command_error: 2, parse_format: 1]

  @spec serve([String.t()]) :: :ok | no_return()
  def serve(args) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, pid} <- Daemon.start_link(start_opts(opts)) do
      output =
        pid
        |> Server.address()
        |> format_started(opts[:format])

      IO.write(wrap_serve_output(output, opts[:format]))
      ref = Process.monitor(pid)

      receive do
        {:DOWN, ^ref, :process, _pid, _reason} -> :ok
      end
    else
      {:error, error} ->
        emit_serve_error(error, args)
    end
  end

  @spec paths([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def paths(args) do
    with {:ok, opts} <- parse_opts(args) do
      {:ok, format_paths(Twelvgaige.daemon_paths(start_opts(opts)), opts[:format]), 0}
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  @spec stop([String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def stop(args) do
    with {:ok, opts} <- parse_opts(args) do
      case Twelvgaige.stop_daemon(stop_opts(opts)) do
        :ok ->
          {:ok, format_stop(opts[:format]), 0}

        {:error, error} ->
          {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp start_opts(opts), do: Keyword.take(opts, [:runtime_dir, :transport, :endpoint_path])

  defp stop_opts(opts) do
    cond do
      endpoint_path = opts[:endpoint_path] ->
        [endpoint_path: endpoint_path]

      runtime_dir = opts[:runtime_dir] ->
        [endpoint_path: Endpoint.default_path(runtime_dir: runtime_dir)]

      true ->
        []
    end
  end

  defp parse_opts(args),
    do:
      parse_opts(args,
        format: :human,
        transport: nil,
        runtime_dir: nil,
        endpoint_path: nil
      )

  defp parse_opts([], opts) do
    opts =
      opts
      |> compact_nil(:transport)
      |> compact_nil(:runtime_dir)
      |> compact_nil(:endpoint_path)

    {:ok, opts}
  end

  defp parse_opts(["--format", format | rest], opts) do
    parse_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_opts(["--transport", transport | rest], opts)
       when transport in ["unix", "tcp"] do
    parse_opts(rest, Keyword.put(opts, :transport, parse_transport(transport)))
  end

  defp parse_opts(["--transport", _transport | _rest], _opts) do
    {:error,
     Twelvgaige.Error.new(:input_error, :invalid_shell, "--transport must be unix or tcp")}
  end

  defp parse_opts(["--runtime-dir", runtime_dir | rest], opts) do
    parse_opts(rest, Keyword.put(opts, :runtime_dir, runtime_dir))
  end

  defp parse_opts(["--endpoint", endpoint_path | rest], opts) do
    parse_opts(rest, Keyword.put(opts, :endpoint_path, endpoint_path))
  end

  defp parse_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp format_started(address, :json) do
    %{status: "running", address: Endpoint.address_to_string(address)}
    |> encode_line()
  end

  defp format_started(address, :human) do
    "Breech daemon listening on #{Endpoint.address_to_string(address)}\n"
  end

  defp format_paths(paths, :json), do: encode_line(paths)

  defp format_paths(paths, :human) do
    """
    Runtime dir: #{paths.runtime_dir}
    Endpoint: #{paths.endpoint_path}
    Lock: #{paths.lock_path}
    Transport: #{paths.transport}
    Socket: #{paths.socket_path}
    """
  end

  defp format_stop(:json), do: encode_line(%{status: "stopping"})
  defp format_stop(:human), do: "Breech daemon stopping\n"

  defp wrap_serve_output(output, :json) do
    {:ok, wrapped, 0} =
      ResultEnvelope.wrap({:ok, output, 0}, ["daemon", "serve", "--format", "json"])

    wrapped
  end

  defp wrap_serve_output(output, :human), do: output

  @spec emit_serve_error(term(), [String.t()]) :: no_return()
  defp emit_serve_error(error, args) do
    code = ExitCode.for_error(error)

    if ResultEnvelope.requested_format(args) == :json do
      {:ok, output, ^code} =
        error
        |> format_command_error(:json)
        |> then(&ResultEnvelope.wrap({:ok, &1, code}, ["daemon", "serve", "--format", "json"]))

      IO.write(output)
    else
      IO.write(:stderr, format_command_error(error, :human))
    end

    System.halt(code)
  end

  defp parse_transport("unix"), do: :unix
  defp parse_transport("tcp"), do: :tcp

  defp compact_nil(opts, key) do
    if is_nil(opts[key]), do: Keyword.delete(opts, key), else: opts
  end
end
