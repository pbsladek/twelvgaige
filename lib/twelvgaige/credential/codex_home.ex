defmodule Twelvgaige.Credential.CodexHome do
  @moduledoc "Materializes a private, bounded Codex login home without exposing secrets in argv or env."

  alias Twelvgaige.Security.FileMode

  @default_destination "/run/codex-home"
  @default_max_entries 128
  @default_max_bytes 4 * 1_048_576
  @default_timeout_ms 30_000
  @safe_environment ~w(PATH SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE)

  @doc "Creates an isolated Codex home and logs in with the supplied API key over stdin."
  def materialize(api_key, destination, opts \\ []) do
    root = opts |> Keyword.fetch!(:allowed_root) |> Path.expand()
    destination = Path.expand(destination)

    with :ok <- validate_secret(api_key),
         :ok <- validate_destination(root, destination, :create),
         :ok <- FileMode.ensure_private_dir(root),
         :ok <- File.mkdir(destination),
         :ok <- File.chmod(destination, 0o700),
         :ok <- run_login(api_key, destination, opts),
         :ok <- validate_and_harden_tree(destination, opts) do
      {:ok,
       %{
         source: destination,
         destination: @default_destination,
         mode: :read_write
       }}
    else
      {:error, reason} ->
        _ = cleanup_created_destination(root, destination)
        {:error, reason}
    end
  rescue
    _error ->
      _ = cleanup_after_crash(destination, opts)
      {:error, :codex_home_materialization_crashed}
  end

  @doc "Removes one validated per-session Codex home."
  def cleanup(destination, opts \\ []) do
    root = opts |> Keyword.fetch!(:allowed_root) |> Path.expand()
    destination = Path.expand(destination)

    with :ok <- validate_destination(root, destination, :cleanup) do
      case File.lstat(destination) do
        {:error, :enoent} ->
          :already_removed

        {:ok, %{type: :directory}} ->
          case File.rm_rf(destination) do
            {:ok, _removed} -> :ok
            {:error, reason, _path} -> {:error, {:codex_home_cleanup_failed, reason}}
          end

        {:ok, _other} ->
          {:error, :codex_home_cleanup_target_invalid}

        {:error, reason} ->
          {:error, {:codex_home_cleanup_stat_failed, reason}}
      end
    end
  end

  defp validate_secret(secret) when is_binary(secret) do
    if String.trim(secret) == "", do: {:error, :codex_api_key_missing}, else: :ok
  end

  defp validate_secret(_secret), do: {:error, :codex_api_key_invalid}

  defp validate_destination(root, destination, operation) do
    cond do
      Path.type(root) != :absolute or Path.type(destination) != :absolute ->
        {:error, :codex_home_path_not_absolute}

      Path.dirname(destination) != root ->
        {:error, :codex_home_outside_allowed_root}

      Path.basename(destination) in ["", ".", ".."] ->
        {:error, :codex_home_destination_invalid}

      operation == :create and File.exists?(destination) ->
        {:error, :codex_home_destination_exists}

      true ->
        validate_root(root)
    end
  end

  defp validate_root(root) do
    case File.lstat(root) do
      {:ok, %{type: :directory}} -> :ok
      {:ok, _other} -> {:error, :codex_home_root_invalid}
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:codex_home_root_stat_failed, reason}}
    end
  end

  defp run_login(api_key, destination, opts) do
    binary = Keyword.get(opts, :codex_binary, System.find_executable("codex"))
    runner = Keyword.get(opts, :login_runner, &default_login_runner/4)

    cond do
      not is_binary(binary) or Path.type(binary) != :absolute ->
        {:error, :codex_binary_not_found}

      true ->
        runner_opts =
          opts
          |> Keyword.put(:environment, login_environment(destination, opts))
          |> Keyword.put_new(:timeout_ms, @default_timeout_ms)

        case runner.(binary, ["login", "--with-api-key"], api_key <> "\n", runner_opts) do
          :ok -> :ok
          {:ok, _output} -> :ok
          {_, 0} -> :ok
          {:error, reason} -> {:error, {:codex_login_failed, sanitize_reason(reason)}}
          {_output, status} when is_integer(status) -> {:error, {:codex_login_failed, status}}
          _other -> {:error, :codex_login_result_invalid}
        end
    end
  end

  defp login_environment(destination, opts) do
    inherited =
      @safe_environment
      |> Enum.reduce(%{}, fn name, acc ->
        case System.get_env(name) do
          value when is_binary(value) and value != "" -> Map.put(acc, name, value)
          _missing -> acc
        end
      end)

    inherited
    |> Map.merge(Keyword.get(opts, :safe_environment, %{}))
    |> Map.put("HOME", destination)
    |> Map.put("CODEX_HOME", destination)
  end

  defp default_login_runner(binary, args, stdin, opts) do
    env_binary = Keyword.get(opts, :env_binary, "/usr/bin/env")
    environment = Keyword.fetch!(opts, :environment)

    env_args =
      ["-i"] ++
        (environment
         |> Enum.sort()
         |> Enum.map(fn {key, value} -> key <> "=" <> value end)) ++ [binary | args]

    port =
      Port.open(
        {:spawn_executable, env_binary},
        [:binary, :exit_status, :stderr_to_stdout, {:args, env_args}]
      )

    true = Port.command(port, stdin)

    collect_port(
      port,
      0,
      Keyword.fetch!(opts, :timeout_ms),
      Keyword.get(opts, :max_output_bytes, 8_192)
    )
  rescue
    _error -> {:error, :codex_login_start_failed}
  end

  defp collect_port(port, bytes, timeout_ms, max_output_bytes) do
    receive do
      {^port, {:data, data}} ->
        next = bytes + byte_size(data)

        if next > max_output_bytes do
          Port.close(port)
          {:error, :codex_login_output_limit_exceeded}
        else
          collect_port(port, next, timeout_ms, max_output_bytes)
        end

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        {:error, {:codex_login_exit_status, status}}
    after
      timeout_ms ->
        Port.close(port)
        {:error, :codex_login_timeout}
    end
  end

  defp validate_and_harden_tree(root, opts) do
    limits = %{
      entries: Keyword.get(opts, :max_entries, @default_max_entries),
      bytes: Keyword.get(opts, :max_bytes, @default_max_bytes)
    }

    with {:ok, _usage} <- walk(root, %{entries: 0, bytes: 0}, limits),
         :ok <- File.chmod(root, 0o700) do
      :ok
    end
  end

  defp walk(path, usage, limits) do
    with {:ok, entries} <- File.ls(path) do
      Enum.reduce_while(entries, {:ok, usage}, fn entry, {:ok, current} ->
        child = Path.join(path, entry)

        case File.lstat(child) do
          {:ok, %{type: :directory}} ->
            next = %{current | entries: current.entries + 1}

            with :ok <- within_limits(next, limits),
                 :ok <- File.chmod(child, 0o700),
                 {:ok, nested} <- walk(child, next, limits) do
              {:cont, {:ok, nested}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:ok, %{type: :regular, size: size}} ->
            next = %{entries: current.entries + 1, bytes: current.bytes + size}

            with :ok <- within_limits(next, limits), :ok <- File.chmod(child, 0o600) do
              {:cont, {:ok, next}}
            else
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:ok, _unsupported} ->
            {:halt, {:error, :codex_home_unsupported_entry}}

          {:error, reason} ->
            {:halt, {:error, {:codex_home_entry_stat_failed, reason}}}
        end
      end)
    end
  end

  defp within_limits(usage, limits) do
    cond do
      usage.entries > limits.entries -> {:error, :codex_home_entry_limit_exceeded}
      usage.bytes > limits.bytes -> {:error, :codex_home_byte_limit_exceeded}
      true -> :ok
    end
  end

  defp sanitize_reason(reason) when is_atom(reason) or is_integer(reason), do: reason
  defp sanitize_reason({name, value}) when is_atom(name) and is_integer(value), do: {name, value}
  defp sanitize_reason(_reason), do: :redacted

  defp cleanup_created_destination(root, destination) do
    if Path.dirname(destination) == root do
      case File.lstat(destination) do
        {:ok, %{type: :directory}} ->
          case File.rm_rf(destination) do
            {:ok, _removed} -> :ok
            {:error, reason, _path} -> {:error, {:codex_home_cleanup_failed, reason}}
          end

        {:error, :enoent} ->
          :already_removed

        _other ->
          {:error, :codex_home_cleanup_target_invalid}
      end
    else
      {:error, :codex_home_outside_allowed_root}
    end
  end

  defp cleanup_after_crash(destination, opts) do
    root = opts |> Keyword.fetch!(:allowed_root) |> Path.expand()
    cleanup_created_destination(root, Path.expand(destination))
  rescue
    _error -> {:error, :codex_home_cleanup_failed}
  end
end
