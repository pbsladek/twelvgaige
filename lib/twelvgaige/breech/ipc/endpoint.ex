defmodule Twelvgaige.Breech.IPC.Endpoint do
  @moduledoc """
  Discovery file for the local Breech IPC listener.

  The endpoint file is intentionally small JSON so shell wrappers and future
  platform-specific launchers can inspect it without booting the full app.
  """

  alias Twelvgaige.Breech.IPC.Client
  alias Twelvgaige.Breech.IPC.Protocol
  alias Twelvgaige.Breech.Lock
  alias Twelvgaige.Error

  @filename "breech.endpoint.json"
  @windows_pipe_prefix "\\\\.\\pipe\\"

  @type t :: %{
          address: Client.address(),
          address_text: String.t(),
          api_version: pos_integer(),
          token: String.t() | nil,
          path: Path.t() | nil,
          pid: String.t() | nil,
          version: String.t() | nil,
          created_at: String.t() | nil
        }

  @spec default_runtime_dir(keyword()) :: Path.t()
  def default_runtime_dir(opts \\ []) do
    cond do
      dir = Keyword.get(opts, :runtime_dir) ->
        Path.expand(dir)

      dir = env(opts, "TWELVGAIGE_RUNTIME_DIR") ->
        Path.expand(dir)

      windows?(opts) ->
        opts
        |> windows_data_dir()
        |> Path.join("run")

      dir = xdg_runtime_dir(opts) ->
        Path.join(dir, "twelvgaige")

      true ->
        Path.join([System.user_home!(), ".twelvgaige", "run"])
    end
  end

  @spec default_path(keyword()) :: Path.t()
  def default_path(opts \\ []) do
    opts
    |> default_runtime_dir()
    |> Path.join(@filename)
  end

  @spec write(map(), keyword()) :: :ok | {:error, term()}
  def write(endpoint, opts \\ []) when is_map(endpoint) do
    path = Keyword.get(opts, :path, default_path(opts))
    dir = Path.dirname(path)

    with :ok <- ensure_private_dir(dir),
         {:ok, body} <- encode(endpoint),
         :ok <- File.write(path, body),
         :ok <- chmod_if_supported(path, 0o600) do
      :ok
    end
  end

  @spec read(keyword()) :: {:ok, t()} | {:error, term()}
  def read(opts \\ []) do
    path = Keyword.get(opts, :path, default_path(opts))

    with {:ok, body} <- File.read(path),
         {:ok, decoded} <- Jason.decode(body),
         {:ok, endpoint} <- decode(decoded) do
      {:ok, %{endpoint | path: path}}
    end
  end

  @spec discover(keyword()) :: {:ok, t()} | :none | {:error, term()}
  def discover(opts \\ []) do
    case read(opts) do
      {:ok, endpoint} -> {:ok, endpoint}
      {:error, :enoent} -> :none
      {:error, _reason} = error -> error
    end
  end

  @spec remove(keyword()) :: :ok | {:error, term()}
  def remove(opts \\ []) do
    path = Keyword.get(opts, :path, default_path(opts))

    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, _reason} = error -> error
    end
  end

  @spec cleanup_stale(keyword()) ::
          :ok | {:error, :lock_required | :daemon_running | term()}
  def cleanup_stale(opts \\ []) do
    if lock_verified?(opts) do
      do_cleanup_stale(opts)
    else
      {:error, :lock_required}
    end
  end

  @spec address_to_string(Client.address() | String.t()) :: String.t()
  def address_to_string({:tcp, ip, port}) do
    host =
      ip
      |> :inet.ntoa()
      |> to_string()
      |> bracket_ipv6_host(ip)

    "tcp://#{host}:#{port}"
  end

  def address_to_string({:unix, path}) when is_binary(path) do
    "unix://#{path}"
  end

  def address_to_string({:npipe, path}) when is_binary(path) do
    pipe_name =
      path
      |> pipe_name()
      |> String.split("\\", trim: true)
      |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)

    "npipe:////./pipe/#{pipe_name}"
  end

  def address_to_string(address) when is_binary(address), do: address

  @spec token() :: String.t()
  def token do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp do_cleanup_stale(opts) do
    case read(opts) do
      {:ok, endpoint} ->
        case probe(endpoint, opts) do
          {:error, _reason} -> remove(opts)
          {:ok, _status} -> {:error, :daemon_running}
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        if corrupt_endpoint?(reason), do: remove(opts), else: {:error, reason}
    end
  end

  defp probe(endpoint, opts) do
    case Keyword.get(opts, :probe) do
      probe when is_function(probe, 1) ->
        probe.(endpoint)

      _other ->
        Client.status(endpoint.address,
          token: endpoint.token,
          timeout_ms: Keyword.get(opts, :timeout_ms, 250)
        )
    end
  end

  defp lock_verified?(opts) do
    Keyword.get(opts, :lock_verified?, false) or Lock.verified?(Keyword.get(opts, :lock))
  end

  defp encode(endpoint) do
    address_text = endpoint |> Map.fetch!(:address) |> address_to_string()

    body = %{
      "kind" => "twelvgaige.breech.endpoint",
      "api_version" => Protocol.api_version(),
      "version" => Twelvgaige.version(),
      "address" => address_text,
      "token" => Map.get(endpoint, :token),
      "pid" => System.pid(),
      "created_at" => DateTime.to_iso8601(Twelvgaige.Clock.utc_now())
    }

    {:ok, Jason.encode!(body)}
  rescue
    error -> {:error, error}
  end

  defp decode(%{"address" => address_text} = decoded) do
    with :ok <- validate_api_version(Map.get(decoded, "api_version")),
         {:ok, address} <- Client.parse_address(address_text) do
      {:ok,
       %{
         address: address,
         address_text: address_text,
         api_version: Map.fetch!(decoded, "api_version"),
         token: Map.get(decoded, "token"),
         path: nil,
         pid: Map.get(decoded, "pid"),
         version: Map.get(decoded, "version"),
         created_at: Map.get(decoded, "created_at")
       }}
    end
  end

  defp decode(_decoded), do: {:error, :invalid_endpoint}

  defp validate_api_version(version) do
    expected = Protocol.api_version()

    if version == expected do
      :ok
    else
      {:error,
       Error.new(:policy_error, :daemon_version_mismatch, "daemon endpoint API version mismatch",
         details: %{
           expected_api_version: expected,
           endpoint_api_version: version
         }
       )}
    end
  end

  defp ensure_private_dir(dir) do
    with :ok <- File.mkdir_p(dir) do
      chmod_if_supported(dir, 0o700)
    end
  end

  defp chmod_if_supported(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, :enotsup} -> :ok
      {:error, :eperm} -> if(windows?(), do: :ok, else: {:error, :eperm})
      {:error, _reason} = error -> error
    end
  end

  defp bracket_ipv6_host(host, {_a, _b, _c, _d}), do: host
  defp bracket_ipv6_host(host, {_a, _b, _c, _d, _e, _f, _g, _h}), do: "[#{host}]"

  defp corrupt_endpoint?(:invalid_endpoint), do: true
  defp corrupt_endpoint?(:invalid_ipc_address), do: true
  defp corrupt_endpoint?(%Jason.DecodeError{}), do: true
  defp corrupt_endpoint?(_reason), do: false

  defp pipe_name(@windows_pipe_prefix <> name), do: name
  defp pipe_name(path), do: path

  defp windows_data_dir(opts) do
    case env(opts, "LOCALAPPDATA") do
      nil -> Path.join([System.user_home!(), "AppData", "Local", "Twelvgaige"])
      local_appdata -> Path.join(local_appdata, "Twelvgaige")
    end
  end

  defp xdg_runtime_dir(opts) do
    if windows?(opts), do: nil, else: env(opts, "XDG_RUNTIME_DIR")
  end

  defp env(opts, name) do
    case Keyword.get(opts, :env) do
      nil -> System.get_env(name)
      env when is_map(env) -> Map.get(env, name)
      _env -> nil
    end
  end

  defp windows?(opts \\ []) do
    match?({:win32, _name}, Keyword.get(opts, :os_type, :os.type()))
  end
end
