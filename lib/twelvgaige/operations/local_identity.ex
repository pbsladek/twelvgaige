defmodule Twelvgaige.Operations.LocalIdentity do
  @moduledoc "Local OS-user and loopback transport policy for supported unattended operation."

  @spec current(keyword()) :: {:ok, map()} | {:error, term()}
  def current(opts \\ []) do
    with {:ok, uid} <- resolve_uid(opts),
         {:ok, username} <- resolve_username(opts) do
      {:ok, %{uid: uid, username: username, home: System.user_home!(), os: :os.type()}}
    end
  end

  @spec authorize_uid(non_neg_integer(), keyword()) :: :ok | {:error, :local_user_mismatch}
  def authorize_uid(expected_uid, opts \\ []) when is_integer(expected_uid) do
    case current(opts) do
      {:ok, %{uid: ^expected_uid}} -> :ok
      {:ok, _identity} -> {:error, :local_user_mismatch}
      {:error, _reason} -> {:error, :local_user_mismatch}
    end
  end

  @spec loopback?(:inet.ip_address()) :: boolean()
  def loopback?({127, _b, _c, _d}), do: true
  def loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  def loopback?(_ip), do: false

  @spec private_path(Path.t(), non_neg_integer()) :: :ok | {:error, term()}
  def private_path(path, expected_uid) do
    case File.stat(path) do
      {:ok, %{uid: ^expected_uid, mode: mode}} when Bitwise.band(mode, 0o077) == 0 -> :ok
      {:ok, %{uid: uid}} when uid != expected_uid -> {:error, :path_owner_mismatch}
      {:ok, _stat} -> {:error, :path_permissions_too_broad}
      {:error, reason} -> {:error, reason}
    end
  end

  defp resolve_uid(opts) do
    case Keyword.get(opts, :uid) do
      uid when is_integer(uid) and uid >= 0 -> {:ok, uid}
      nil -> command_uid(Keyword.get(opts, :id_command, "/usr/bin/id"))
      _other -> {:error, :invalid_local_uid}
    end
  end

  defp command_uid(command) do
    case System.cmd(command, ["-u"], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {uid, ""} when uid >= 0 -> {:ok, uid}
          _other -> {:error, :invalid_local_uid}
        end

      {_output, status} ->
        {:error, {:local_uid_unavailable, status}}
    end
  rescue
    error -> {:error, {:local_uid_unavailable, Exception.message(error)}}
  end

  defp resolve_username(opts) do
    case Keyword.get(opts, :username) || System.get_env("USER") || System.get_env("USERNAME") do
      value when is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      _other -> {:error, :local_username_unavailable}
    end
  end
end
