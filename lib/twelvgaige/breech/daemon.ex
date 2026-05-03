defmodule Twelvgaige.Breech.Daemon do
  @moduledoc """
  Foreground Breech daemon launcher.

  Detached process management is left to the OS/service wrapper. This module
  owns the cross-platform defaults for the local IPC listener, endpoint file,
  and singleton lock.
  """

  alias Twelvgaige.Breech.IPC.Endpoint
  alias Twelvgaige.Breech.IPC.Server
  alias Twelvgaige.Breech.Lock

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts
    |> server_opts()
    |> Server.start_link()
  end

  @spec server_opts(keyword()) :: keyword()
  def server_opts(opts \\ []) do
    runtime_dir = Endpoint.default_runtime_dir(opts)
    transport = Keyword.get(opts, :transport, default_transport(opts))

    base_opts = [
      transport: transport,
      endpoint_path:
        Keyword.get(opts, :endpoint_path, Endpoint.default_path(runtime_dir: runtime_dir)),
      lock_path: Keyword.get(opts, :lock_path, Lock.default_path(runtime_dir: runtime_dir))
    ]

    transport_opts(transport, runtime_dir, opts) ++ base_opts
  end

  @spec paths(keyword()) :: map()
  def paths(opts \\ []) do
    runtime_dir = Endpoint.default_runtime_dir(opts)
    transport = Keyword.get(opts, :transport, default_transport(opts))

    %{
      runtime_dir: runtime_dir,
      endpoint_path:
        Keyword.get(opts, :endpoint_path, Endpoint.default_path(runtime_dir: runtime_dir)),
      lock_path: Keyword.get(opts, :lock_path, Lock.default_path(runtime_dir: runtime_dir)),
      transport: Atom.to_string(transport),
      socket_path: socket_path_for_paths(transport, runtime_dir, opts),
      pipe_path: pipe_path(opts),
      windows_named_pipe: pipe_path(opts)
    }
  end

  defp transport_opts(:unix, runtime_dir, opts) do
    [socket_path: socket_path(runtime_dir, opts)]
  end

  defp transport_opts(:tcp, _runtime_dir, opts) do
    [port: Keyword.get(opts, :port, 0)]
  end

  defp transport_opts(:npipe, _runtime_dir, opts) do
    [pipe_path: pipe_path(opts)]
  end

  defp transport_opts(_transport, _runtime_dir, _opts), do: []

  defp socket_path(runtime_dir, opts) do
    Keyword.get(opts, :socket_path, Path.join(runtime_dir, "breech.sock"))
  end

  defp socket_path_for_paths(:unix, runtime_dir, opts), do: socket_path(runtime_dir, opts)
  defp socket_path_for_paths(_transport, _runtime_dir, _opts), do: nil

  defp pipe_path(opts) do
    Keyword.get(opts, :pipe_path, windows_named_pipe_name(opts))
  end

  defp default_transport(opts) do
    if windows?(opts), do: :tcp, else: :unix
  end

  defp windows_named_pipe_name(opts) do
    user =
      Keyword.get(opts, :user_identity, System.user_home!())
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 12)

    "\\\\.\\pipe\\twelvgaige-#{user}-breech"
  end

  defp windows?(opts) do
    match?({:win32, _name}, Keyword.get(opts, :os_type, :os.type()))
  end
end
