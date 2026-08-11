defmodule Twelvgaige.Breech.Lock do
  @moduledoc """
  Filesystem singleton lock for one Breech daemon per runtime directory.

  The lock is a directory created atomically. This keeps the implementation
  simple and portable while still giving startup code a clear ownership proof
  before it cleans stale endpoint files.
  """

  @filename "breech.lock"
  @owner_file "owner.json"

  @type t :: %__MODULE__{
          path: Path.t(),
          token: String.t(),
          acquired_at: DateTime.t()
        }

  @enforce_keys [:path, :token, :acquired_at]
  defstruct [:path, :token, :acquired_at]

  @spec default_path(keyword()) :: Path.t()
  def default_path(opts \\ []) do
    opts
    |> Twelvgaige.Breech.IPC.Endpoint.default_runtime_dir()
    |> Path.join(@filename)
  end

  @spec acquire(keyword()) :: {:ok, t()} | {:error, term()}
  def acquire(opts \\ []) do
    path = Keyword.get(opts, :path, default_path(opts))
    token = Keyword.get_lazy(opts, :token, &token/0)
    acquired_at = Keyword.get(opts, :acquired_at, Twelvgaige.Clock.utc_now())

    with :ok <- ensure_private_parent(path),
         :ok <- mkdir_lock(path),
         lock <- %__MODULE__{path: path, token: token, acquired_at: acquired_at},
         :ok <- write_owner(lock) do
      {:ok, lock}
    end
  end

  @spec release(t()) :: :ok | {:error, term()}
  def release(%__MODULE__{} = lock) do
    if verified?(lock) do
      case File.rm_rf(lock.path) do
        {:ok, _removed} -> :ok
        {:error, _path, reason} -> {:error, reason}
      end
    else
      {:error, :lock_not_owned}
    end
  end

  @spec verified?(t() | nil) :: boolean()
  def verified?(%__MODULE__{} = lock) do
    case read_owner(lock.path) do
      {:ok, %{"token" => token}} -> token == lock.token
      _other -> false
    end
  end

  def verified?(_lock), do: false

  @spec read_owner(Path.t()) :: {:ok, map()} | {:error, term()}
  def read_owner(path) when is_binary(path) do
    path
    |> owner_path()
    |> File.read()
    |> case do
      {:ok, body} -> Jason.decode(body)
      {:error, _reason} = error -> error
    end
  end

  @spec token() :: String.t()
  def token do
    24
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp ensure_private_parent(path) do
    parent = Path.dirname(path)

    with :ok <- File.mkdir_p(parent) do
      chmod_if_supported(parent, 0o700)
    end
  end

  defp mkdir_lock(path) do
    case File.mkdir(path) do
      :ok ->
        chmod_if_supported(path, 0o700)

      {:error, :eexist} ->
        {:error, {:already_locked, read_owner_or_unknown(path)}}

      {:error, _reason} = error ->
        error
    end
  end

  defp write_owner(%__MODULE__{} = lock) do
    owner = %{
      "kind" => "twelvgaige.breech.lock",
      "version" => Twelvgaige.version(),
      "pid" => System.pid(),
      "token" => lock.token,
      "acquired_at" => DateTime.to_iso8601(lock.acquired_at)
    }

    path = owner_path(lock.path)

    with :ok <- File.write(path, Jason.encode!(owner)) do
      chmod_if_supported(path, 0o600)
    end
  end

  defp owner_path(path), do: Path.join(path, @owner_file)

  defp read_owner_or_unknown(path) do
    case read_owner(path) do
      {:ok, owner} -> owner
      {:error, reason} -> %{"error" => inspect(reason)}
    end
  end

  defp chmod_if_supported(path, mode) do
    case File.chmod(path, mode) do
      :ok -> :ok
      {:error, :enotsup} -> :ok
      {:error, :eperm} -> {:error, :eperm}
      {:error, _reason} = error -> error
    end
  end
end
