defmodule Twelvgaige.CLI.InterruptSource do
  @moduledoc """
  Reads interrupt bytes from the private FIFO created by the packaged CLI
  launcher.

  The launcher owns terminal signal handling because Erlang/OTP does not expose
  `SIGINT` through `os:set_signal/2`. It keeps the BEAM in a separate process
  that ignores `SIGINT` and writes one byte to this FIFO for each Ctrl-C.
  """

  @environment "TWELVGAIGE_INTERRUPT_FIFO"
  @ready_environment "TWELVGAIGE_INTERRUPT_READY"

  @type t :: %{reader: pid(), path: Path.t(), ready_path: Path.t()}

  @spec start((-> term())) :: {:ok, t() | nil} | {:error, term()}
  def start(callback) when is_function(callback, 0) do
    case System.get_env(@environment) do
      path when is_binary(path) and path != "" ->
        start_fifo(Path.expand(path), System.get_env(@ready_environment), callback)

      _missing ->
        {:ok, nil}
    end
  end

  @spec stop(t() | nil) :: :ok
  def stop(nil), do: :ok

  def stop(handle) do
    if Process.alive?(handle.reader), do: Process.exit(handle.reader, :kill)
    _ = File.rm(handle.ready_path)
    :ok
  end

  defp start_fifo(path, ready_path, callback) when is_binary(ready_path) and ready_path != "" do
    ready_path = Path.expand(ready_path)

    with {:ok, stat} <- File.lstat(path, time: :posix),
         :ok <- validate_fifo(path, stat),
         :ok <- validate_ready_path(path, ready_path),
         {:ok, reader} <- start_reader(path, ready_path, callback) do
      {:ok, %{reader: reader, path: path, ready_path: ready_path}}
    else
      {:error, reason} -> {:error, {:interrupt_fifo_unavailable, reason}}
    end
  end

  defp start_fifo(_path, _ready_path, _callback),
    do: {:error, {:interrupt_fifo_unavailable, :interrupt_ready_path_missing}}

  defp validate_fifo(path, %{type: :other, mode: mode}) do
    cond do
      Bitwise.band(mode, 0o077) != 0 -> {:error, :interrupt_fifo_permissions_invalid}
      not under_private_temp?(path) -> {:error, :interrupt_fifo_path_untrusted}
      true -> :ok
    end
  end

  defp validate_fifo(_path, _stat), do: {:error, :interrupt_fifo_type_invalid}

  defp validate_ready_path(fifo_path, ready_path) do
    if Path.dirname(fifo_path) == Path.dirname(ready_path) and under_private_temp?(ready_path),
      do: :ok,
      else: {:error, :interrupt_ready_path_untrusted}
  end

  defp under_private_temp?(path) do
    temp = System.tmp_dir!() |> Path.expand()
    path == temp or String.starts_with?(path, temp <> "/")
  end

  defp start_reader(path, ready_path, callback) do
    parent = self()
    reference = make_ref()

    with {:ok, reader} <-
           Task.start(fn -> reader_process(path, ready_path, callback, parent, reference) end) do
      receive do
        {^reference, :ready} -> {:ok, reader}
        {^reference, {:error, reason}} -> {:error, reason}
      after
        5_000 ->
          Process.exit(reader, :kill)
          {:error, :interrupt_fifo_open_timeout}
      end
    end
  end

  defp reader_process(path, ready_path, callback, parent, reference) do
    case File.open(path, [:read, :binary, :raw]) do
      {:ok, device} ->
        try do
          with :ok <- File.write(ready_path, "ready\n", [:exclusive]),
               :ok <- File.chmod(ready_path, 0o600) do
            send(parent, {reference, :ready})
            read_loop(device, callback)
          else
            {:error, reason} -> send(parent, {reference, {:error, reason}})
          end
        after
          _ = File.close(device)
          _ = File.rm(ready_path)
        end

      {:error, reason} ->
        send(parent, {reference, {:error, reason}})
    end
  end

  defp read_loop(device, callback) do
    result = IO.binread(device, 1)

    if System.get_env("TWELVGAIGE_INTERRUPT_DEBUG") == "1" do
      IO.puts(:stderr, "[interrupt-source] read=#{inspect(result)}")
    end

    case result do
      byte when is_binary(byte) ->
        _ = callback.()
        read_loop(device, callback)

      _closed ->
        :ok
    end
  end
end
