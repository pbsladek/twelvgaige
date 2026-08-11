defmodule Twelvgaige.Operations.Paths do
  @moduledoc "Supported per-user operational data paths."

  def data_root(opts \\ []) do
    cond do
      path = Keyword.get(opts, :data_root) ->
        Path.expand(path)

      path = System.get_env("TWELVGAIGE_DATA_ROOT") ->
        Path.expand(path)

      match?({:unix, :darwin}, :os.type()) ->
        Path.join([System.user_home!(), "Library", "Application Support", "Twelvgaige"])

      match?({:unix, :linux}, :os.type()) ->
        Path.join(
          System.get_env("XDG_DATA_HOME") || Path.join(System.user_home!(), ".local/share"),
          "twelvgaige"
        )

      true ->
        raise "unsupported Twelvgaige platform"
    end
  end

  def operations_database(opts \\ []),
    do: Path.join([data_root(opts), "databases", "operations.sqlite3"])

  def workspaces(opts \\ []), do: Path.join(data_root(opts), "workspaces")
  def artifacts(opts \\ []), do: Path.join(data_root(opts), "artifacts")
  def credentials(opts \\ []), do: Path.join(data_root(opts), "credentials")
  def audit_exports(opts \\ []), do: Path.join(data_root(opts), "audit-exports")

  def audit_checkpoints(opts \\ []),
    do: Path.join(audit_exports(opts), "operations-checkpoints.ndjson")

  def prepare(opts \\ []) do
    root = data_root(opts)
    owner_uid = Keyword.fetch!(opts, :owner_uid)

    directories = [
      root,
      workspaces(opts),
      artifacts(opts),
      credentials(opts),
      Path.dirname(operations_database(opts)),
      audit_exports(opts)
    ]

    with :ok <- create_private_directories(directories),
         :ok <- verify_owner(root, owner_uid) do
      {:ok, %{data_root: root, owner_uid: owner_uid}}
    end
  end

  defp create_private_directories(directories) do
    Enum.reduce_while(directories, :ok, fn path, :ok ->
      with :ok <- File.mkdir_p(path), :ok <- File.chmod(path, 0o700) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp verify_owner(path, expected_uid) do
    case File.stat(path) do
      {:ok, %{uid: ^expected_uid}} -> :ok
      {:ok, %{uid: uid}} -> {:error, {:operations_data_owner_mismatch, expected_uid, uid}}
      {:error, reason} -> {:error, reason}
    end
  end
end
