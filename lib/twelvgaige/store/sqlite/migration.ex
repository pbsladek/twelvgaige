defmodule Twelvgaige.Store.SQLite.Migration do
  @moduledoc """
  Offline SQLite store migration helpers.

  The plaintext-to-SQLCipher path is intentionally explicit and offline. It
  never reads the active store configuration, never overwrites by default, and
  fails before creating the destination when the loaded SQLite driver is not
  SQLCipher-backed.
  """

  alias Ecto.Adapters.SQL
  alias Twelvgaige.Security.FileMode

  @default_key_env "TWELVGAIGE_STORE_SQLCIPHER_KEY"
  @default_sqlcipher_kdf_iter 256_000
  @driver "ecto_sqlite3/exqlite"

  defmodule Repo do
    @moduledoc false

    use Ecto.Repo,
      otp_app: :twelvgaige,
      adapter: Ecto.Adapters.SQLite3
  end

  @spec plaintext_to_encrypted(Path.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def plaintext_to_encrypted(source, destination, opts \\ [])
      when is_binary(source) and is_binary(destination) do
    source = Path.expand(source)
    destination = Path.expand(destination)
    temp = temp_destination(destination)

    result =
      with {:ok, key} <- sqlcipher_key(opts),
           :ok <- validate_source(source),
           :ok <- validate_destination(source, destination, opts),
           {:ok, cipher_version} <- detect_sqlcipher(),
           {:ok, source_versions} <- migration_versions(source, nil),
           :ok <- FileMode.ensure_private_parent_dir(destination),
           :ok <- remove_sqlite_files(temp),
           :ok <- export_sqlcipher(source, temp, key, opts),
           {:ok, destination_versions} <- migration_versions(temp, key),
           {:ok, true} <- open_without_key_rejected?(temp),
           :ok <- install_temp_destination(temp, destination, opts),
           :ok <- FileMode.ensure_private_existing_files(sqlite_files(destination)),
           {:ok, bytes} <- file_size(destination) do
        {:ok,
         %{
           "status" => "ok",
           "source" => source,
           "destination" => destination,
           "driver" => @driver,
           "cipher_version" => cipher_version,
           "migration_versions" => destination_versions,
           "source_migration_versions" => source_versions,
           "encrypted" => true,
           "open_without_key_rejected" => true,
           "bytes" => bytes,
           "replaced" => Keyword.get(opts, :replace?, false) == true,
           "warnings" => []
         }}
      else
        {:ok, false} -> {:error, :sqlcipher_open_without_key_succeeded}
        {:error, _reason} = error -> error
      end

    cleanup_temp(result, temp)
  end

  defp sqlcipher_key(opts) do
    key = Keyword.get(opts, :key) || key_from_env(Keyword.get(opts, :key_env, @default_key_env))

    case key do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :sqlcipher_key_required}
    end
  end

  defp key_from_env(nil), do: nil
  defp key_from_env(""), do: nil

  defp key_from_env(env) when is_binary(env) do
    case System.get_env(env) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end

  defp validate_source(source) do
    if File.regular?(source) do
      :ok
    else
      {:error, :migration_source_not_found}
    end
  end

  defp validate_destination(source, destination, opts) do
    cond do
      source == destination ->
        {:error, :migration_same_path}

      File.exists?(destination) and Keyword.get(opts, :replace?, false) != true ->
        {:error, :migration_destination_exists}

      true ->
        :ok
    end
  end

  defp detect_sqlcipher do
    with {:ok, repo_pid} <- start_repo(":memory:", nil) do
      try do
        case SQL.query(Repo, "PRAGMA cipher_version", []) do
          {:ok, %{rows: [[version] | _]}} when is_binary(version) and version != "" ->
            {:ok, version}

          {:ok, _result} ->
            {:error, :sqlcipher_unavailable}

          {:error, reason} ->
            {:error, reason}
        end
      after
        stop_repo(repo_pid)
      end
    end
  end

  defp export_sqlcipher(source, destination, key, opts) do
    with {:ok, repo_pid} <- start_repo(source, nil) do
      try do
        with :ok <- configure_plain_connection(),
             :ok <- attach_encrypted_destination(destination, key, opts),
             :ok <- query_ok("SELECT sqlcipher_export('encrypted')", []),
             :ok <- query_ok("DETACH DATABASE encrypted", []) do
          :ok
        end
      after
        stop_repo(repo_pid)
      end
    end
  end

  defp attach_encrypted_destination(destination, key, opts) do
    sql =
      [
        "ATTACH DATABASE ",
        sql_string_literal(destination),
        " AS encrypted KEY ",
        sql_string_literal(key)
      ]
      |> IO.iodata_to_binary()

    with :ok <- query_ok(sql, []),
         :ok <- query_ok("PRAGMA encrypted.kdf_iter = #{cipher_kdf_iter(opts)}", []),
         :ok <- query_ok("PRAGMA encrypted.cipher_memory_security = ON", []) do
      :ok
    end
  end

  defp migration_versions(path, key) do
    with {:ok, repo_pid} <- start_repo(path, key) do
      try do
        with :ok <- configure_plain_connection(),
             {:ok, %{rows: rows}} <-
               SQL.query(Repo, "SELECT version FROM schema_migrations ORDER BY version", []) do
          {:ok, Enum.map(rows, fn [version] -> version end)}
        else
          {:error, _reason} -> {:error, :migration_source_invalid}
        end
      after
        stop_repo(repo_pid)
      end
    end
  end

  defp open_without_key_rejected?(path) do
    with {:ok, repo_pid} <- start_repo(path, nil) do
      try do
        case SQL.query(Repo, "SELECT count(*) FROM schema_migrations", []) do
          {:ok, _result} -> {:ok, false}
          {:error, _reason} -> {:ok, true}
        end
      after
        stop_repo(repo_pid)
      end
    else
      {:error, _reason} -> {:ok, true}
    end
  end

  defp configure_plain_connection do
    with :ok <- query_ok("PRAGMA foreign_keys = ON", []),
         :ok <- query_ok("PRAGMA busy_timeout = 5000", []) do
      :ok
    end
  end

  defp query_ok(sql, params) do
    case SQL.query(Repo, sql, params) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp start_repo(path, key) do
    opts =
      [
        database: path,
        pool_size: 1,
        busy_timeout: 5_000,
        journal_mode: :delete,
        log: false
      ]
      |> maybe_put_key(key)

    Repo.start_link(opts)
  end

  defp stop_repo(pid) when is_pid(pid), do: Supervisor.stop(pid)

  defp maybe_put_key(opts, key) when is_binary(key) and key != "" do
    Keyword.put(opts, :key, sql_string_literal(key))
  end

  defp maybe_put_key(opts, _key), do: opts

  defp cipher_kdf_iter(opts) do
    opts
    |> Keyword.get(:cipher_kdf_iter, @default_sqlcipher_kdf_iter)
    |> max(1)
  end

  defp install_temp_destination(temp, destination, opts) do
    with :ok <- maybe_remove_destination(destination, opts),
         :ok <- rename_file(temp, destination) do
      remove_sqlite_sidecars(temp)
    end
  end

  defp maybe_remove_destination(destination, opts) do
    if Keyword.get(opts, :replace?, false) == true do
      remove_sqlite_files(destination)
    else
      :ok
    end
  end

  defp remove_sqlite_files(path) do
    path
    |> sqlite_files()
    |> Enum.reduce_while(:ok, fn file, :ok ->
      case File.rm(file) do
        :ok -> {:cont, :ok}
        {:error, :enoent} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp remove_sqlite_sidecars(path) do
    [path <> "-wal", path <> "-shm"]
    |> Enum.each(&File.rm/1)

    :ok
  end

  defp rename_file(source, destination) do
    case File.rename(source, destination) do
      :ok -> FileMode.chmod_if_supported(destination, 0o600)
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_temp({:ok, _report} = ok, temp) do
    _ignored = remove_sqlite_files(temp)
    ok
  end

  defp cleanup_temp({:error, _reason} = error, temp) do
    _ignored = remove_sqlite_files(temp)
    error
  end

  defp sqlite_files(path), do: [path, path <> "-wal", path <> "-shm"]

  defp temp_destination(destination) do
    "#{destination}.migrating-#{System.unique_integer([:positive])}"
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat.size}
      {:error, reason} -> {:error, reason}
    end
  end

  defp sql_string_literal(value) do
    escaped = String.replace(value, "'", "''")
    "'#{escaped}'"
  end
end
