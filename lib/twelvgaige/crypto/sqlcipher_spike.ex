defmodule Twelvgaige.Crypto.SQLCipherSpike do
  @moduledoc """
  Feasibility probe for SQLCipher-backed SQLite storage.

  This module deliberately does not implement an encrypted production store. It
  only proves whether the currently loaded `ecto_sqlite3`/`exqlite` stack was
  built against SQLCipher and, when it was, whether Twelvgaige migrations can be
  applied and reopened with a key.
  """

  alias Ecto.Adapters.SQL
  alias Twelvgaige.Security.FileMode
  alias Twelvgaige.Store.SQLite.Migrations.Initial
  alias Twelvgaige.Store.SQLite.Migrations.RoundQueryColumns
  alias Twelvgaige.Store.SQLite.Migrations.ShotRuns

  @migrations [Initial, ShotRuns, RoundQueryColumns]
  @driver "ecto_sqlite3/exqlite"
  @default_key_env "TWELVGAIGE_SQLCIPHER_SPIKE_KEY"

  defmodule Repo do
    @moduledoc false

    use Ecto.Repo,
      otp_app: :twelvgaige,
      adapter: Ecto.Adapters.SQLite3
  end

  @type result :: map()

  @spec run(keyword()) :: {:ok, result()} | {:error, term()}
  def run(opts \\ []) do
    path = opts |> Keyword.get(:path) |> normalize_path()
    key = Keyword.get(opts, :key) || key_from_env(Keyword.get(opts, :key_env, @default_key_env))

    case detect_sqlcipher(key) do
      {:ok, cipher_version} when is_binary(cipher_version) ->
        prove_sqlcipher_store(path, key, cipher_version)

      {:error, :sqlcipher_unavailable} ->
        {:ok, unavailable_report(path)}

      {:error, _reason} = error ->
        error
    end
  end

  defp detect_sqlcipher(key) do
    with {:ok, repo_pid} <- start_repo(":memory:", key) do
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

  defp prove_sqlcipher_store(_path, nil, _cipher_version), do: {:error, :sqlcipher_key_required}
  defp prove_sqlcipher_store(_path, "", _cipher_version), do: {:error, :sqlcipher_key_required}

  defp prove_sqlcipher_store(path, key, cipher_version) do
    with :ok <- FileMode.ensure_private_parent_dir(path),
         {:ok, _created} <- create_migrated_store(path, key),
         {:ok, reopened_versions} <- reopen_with_key(path, key),
         {:ok, rejected?} <- open_without_key_rejected?(path),
         :ok <- FileMode.ensure_private_existing_files([path, path <> "-wal", path <> "-shm"]) do
      {:ok,
       %{
         "status" => "ok",
         "available" => true,
         "driver" => @driver,
         "path" => path,
         "cipher_version" => cipher_version,
         "migrations" => "ok",
         "migration_versions" => reopened_versions,
         "reopen_with_key" => true,
         "open_without_key_rejected" => rejected?,
         "warnings" => []
       }}
    end
  end

  defp create_migrated_store(path, key) do
    with {:ok, repo_pid} <- start_repo(path, key) do
      try do
        with :ok <- configure_connection(),
             :ok <- migrate_all() do
          {:ok, :created}
        end
      after
        stop_repo(repo_pid)
      end
    end
  end

  defp reopen_with_key(path, key) do
    with {:ok, repo_pid} <- start_repo(path, key) do
      try do
        with :ok <- configure_connection(),
             {:ok, versions} <- migration_versions() do
          {:ok, versions}
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

  defp configure_connection do
    with {:ok, _} <- SQL.query(Repo, "PRAGMA foreign_keys = ON", []),
         {:ok, _} <- SQL.query(Repo, "PRAGMA busy_timeout = 5000", []) do
      :ok
    end
  end

  defp migrate_all do
    Enum.reduce_while(@migrations, :ok, fn migration, :ok ->
      case Ecto.Migrator.up(Repo, migration.version(), migration,
             log: false,
             log_migrations_sql: false,
             log_migrator_sql: false
           ) do
        status when status in [:ok, :already_up] -> {:cont, :ok}
      end
    end)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, reason}
  end

  defp migration_versions do
    case SQL.query(Repo, "SELECT version FROM schema_migrations ORDER BY version", []) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, fn [version] -> version end)}

      {:error, reason} ->
        {:error, reason}
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

  defp sql_string_literal(value) do
    escaped = String.replace(value, "'", "''")
    "'#{escaped}'"
  end

  defp unavailable_report(path) do
    %{
      "status" => "unavailable",
      "available" => false,
      "driver" => @driver,
      "path" => path,
      "cipher_version" => nil,
      "migrations" => "skipped",
      "migration_versions" => [],
      "reopen_with_key" => false,
      "open_without_key_rejected" => false,
      "warnings" => [
        "PRAGMA cipher_version returned no version; exqlite is not built against SQLCipher",
        "no encrypted store was created"
      ]
    }
  end

  defp normalize_path(nil) do
    Path.join(
      System.tmp_dir!(),
      "twelvgaige-sqlcipher-spike-#{System.unique_integer([:positive])}.db"
    )
  end

  defp normalize_path(path) when is_binary(path), do: Path.expand(path)

  defp key_from_env(nil), do: nil
  defp key_from_env(""), do: nil

  defp key_from_env(env) when is_binary(env) do
    case System.get_env(env) do
      value when is_binary(value) and value != "" -> value
      _missing -> nil
    end
  end
end
