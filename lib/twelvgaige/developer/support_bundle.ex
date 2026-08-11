defmodule Twelvgaige.Developer.SupportBundle do
  @moduledoc "Allowlist-based, redacted diagnostic export for developer review."

  alias Twelvgaige.Breech.IPC.{Endpoint, Protocol}
  alias Twelvgaige.Developer.Config
  alias Twelvgaige.Workspace.Canonical

  @schema_version 1
  @allowed_files ["configuration.json", "daemon.json", "environment.json"]
  @excluded [
    "absolute paths",
    "audit event payloads",
    "credential material and endpoint tokens",
    "operations databases",
    "provider transcripts and task text",
    "result artifacts and patches",
    "source repositories and managed workspaces"
  ]

  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts) do
    with {:ok, destination} <- destination(opts),
         {:ok, request_id} <- request_id(opts),
         :ok <- write_authority(opts),
         {:ok, files} <- build_files(opts),
         report <- report(destination, request_id, files, opts) do
      if Keyword.get(opts, :write?, false) do
        write(destination, request_id, files, report)
      else
        {:ok, report}
      end
    end
  end

  defp build_files(opts) do
    environment = %{
      schema_version: 1,
      cli_version: Twelvgaige.version(),
      daemon_protocol_version: Protocol.api_version(),
      elixir_version: System.version(),
      otp_version: :erlang.system_info(:otp_release) |> to_string(),
      operating_system: operating_system(),
      architecture: :erlang.system_info(:system_architecture) |> to_string()
    }

    files = %{
      "configuration.json" => %{schema_version: 1, profiles: profile_names(opts)},
      "daemon.json" => daemon_summary(opts),
      "environment.json" => environment
    }

    {:ok, Map.new(files, fn {name, value} -> {name, encode(value)} end)}
  rescue
    _error -> {:error, :support_bundle_build_failed}
  end

  defp profile_names(opts) do
    case Keyword.get(opts, :profile_names_fun, &Config.profile_names/1).(opts) do
      {:ok, names} when is_list(names) ->
        %{status: "available", names: Enum.filter(names, &is_binary/1) |> Enum.sort()}

      {:error, reason} ->
        %{status: "unavailable", failure: failure_code(reason)}

      _invalid ->
        %{status: "unavailable", failure: "profile_summary_invalid"}
    end
  end

  defp daemon_summary(opts) do
    discover = Keyword.get(opts, :endpoint_discover_fun, &default_endpoint_discover/1)

    case discover.(opts) do
      {:ok, endpoint} ->
        %{schema_version: 1, status: "available", transport: endpoint_transport(endpoint)}

      :none ->
        %{schema_version: 1, status: "unavailable", transport: "unreported"}

      {:error, reason} ->
        %{
          schema_version: 1,
          status: "unavailable",
          transport: "unreported",
          failure: failure_code(reason)
        }

      _invalid ->
        %{
          schema_version: 1,
          status: "unavailable",
          transport: "unreported",
          failure: "endpoint_summary_invalid"
        }
    end
  end

  defp default_endpoint_discover(opts) do
    path =
      Keyword.get(opts, :endpoint_path) ||
        Endpoint.default_path(runtime_dir: Keyword.get(opts, :runtime_dir))

    Endpoint.discover(path: path)
  end

  defp endpoint_transport(%{address: {:unix, _path}}), do: "unix"
  defp endpoint_transport(%{address: {:tcp, _address, _port}}), do: "tcp"
  defp endpoint_transport(_endpoint), do: "unreported"

  defp report(destination, request_id, files, opts) do
    file_reports =
      Map.new(files, fn {name, contents} ->
        {:ok, digest} = Canonical.digest_bytes("support-bundle-file", 1, contents)
        {name, %{bytes: byte_size(contents), digest: digest}}
      end)

    %{
      schema_version: @schema_version,
      destination: destination,
      request_id: request_id,
      dry_run: not Keyword.get(opts, :write?, false),
      replayed: false,
      files: file_reports,
      excluded: @excluded,
      redaction: "allowlist-only"
    }
  end

  defp write(destination, request_id, files, report) do
    case File.lstat(destination) do
      {:ok, %{type: :directory}} -> replay(destination, request_id, report)
      {:ok, _stat} -> {:error, :support_bundle_destination_exists}
      {:error, :enoent} -> write_new(destination, files, report)
      {:error, reason} -> {:error, {:support_bundle_destination_unavailable, reason}}
    end
  end

  defp write_new(destination, files, report) do
    parent = Path.dirname(destination)
    staging = destination <> ".staging-#{System.unique_integer([:positive])}"

    result =
      with :ok <- File.mkdir_p(parent),
           :ok <- File.mkdir(staging),
           :ok <- File.chmod(staging, 0o700),
           :ok <- write_files(staging, files),
           completed <-
             report
             |> Map.put(:generated_at, DateTime.utc_now() |> DateTime.truncate(:second))
             |> Map.put(:dry_run, false),
           manifest <- Map.delete(completed, :destination),
           :ok <- write_private(Path.join(staging, "manifest.json"), encode(manifest)),
           :ok <- File.rename(staging, destination) do
        {:ok, completed}
      end

    case result do
      {:ok, manifest} ->
        {:ok, manifest}

      {:error, reason} ->
        _ = File.rm_rf(staging)
        {:error, {:support_bundle_write_failed, reason}}
    end
  end

  defp write_files(destination, files) do
    Enum.reduce_while(files, :ok, fn {name, contents}, :ok ->
      case write_private(Path.join(destination, name), contents) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp write_private(path, contents) do
    with :ok <- File.write(path, contents, [:binary, :exclusive]),
         :ok <- File.chmod(path, 0o600) do
      :ok
    end
  end

  defp replay(destination, request_id, expected) do
    with :ok <- private_directory(destination),
         :ok <- private_regular_file(Path.join(destination, "manifest.json")),
         {:ok, contents} <- File.read(Path.join(destination, "manifest.json")),
         {:ok, manifest} <- Jason.decode(contents),
         ^request_id <- value(manifest, :request_id),
         :ok <- verify_existing_files(destination, value(manifest, :files, %{})),
         {:ok, names} <- File.ls(destination),
         true <- MapSet.new(names) == MapSet.new(["manifest.json" | @allowed_files]) do
      {:ok,
       expected
       |> Map.put(:files, value(manifest, :files))
       |> Map.put(:excluded, value(manifest, :excluded))
       |> Map.put(:redaction, value(manifest, :redaction))
       |> Map.put(:dry_run, false)
       |> Map.put(:replayed, true)
       |> Map.put(:generated_at, value(manifest, :generated_at))}
    else
      _mismatch -> {:error, :support_bundle_destination_conflict}
    end
  end

  defp verify_existing_files(destination, files) when is_map(files) do
    if MapSet.new(Map.keys(files)) == MapSet.new(@allowed_files) do
      Enum.reduce_while(files, :ok, fn {name, metadata}, :ok ->
        path = Path.join(destination, name)

        with :ok <- private_regular_file(path),
             {:ok, contents} <- File.read(path),
             {:ok, digest} <- Canonical.digest_bytes("support-bundle-file", 1, contents),
             ^digest <- value(metadata, :digest),
             bytes when bytes == byte_size(contents) <- value(metadata, :bytes) do
          {:cont, :ok}
        else
          _mismatch -> {:halt, {:error, :support_bundle_file_verification_failed}}
        end
      end)
    else
      {:error, :support_bundle_manifest_invalid}
    end
  end

  defp verify_existing_files(_destination, _files),
    do: {:error, :support_bundle_manifest_invalid}

  defp private_directory(path) do
    case File.lstat(path) do
      {:ok, %{type: :directory, mode: mode}} ->
        if Bitwise.band(mode, 0o077) == 0,
          do: :ok,
          else: {:error, :support_bundle_permissions_invalid}

      _invalid ->
        {:error, :support_bundle_destination_invalid}
    end
  end

  defp private_regular_file(path) do
    case File.lstat(path) do
      {:ok, %{type: :regular, mode: mode}} ->
        if Bitwise.band(mode, 0o077) == 0,
          do: :ok,
          else: {:error, :support_bundle_permissions_invalid}

      _invalid ->
        {:error, :support_bundle_file_invalid}
    end
  end

  defp destination(opts) do
    case Keyword.get(opts, :destination) do
      value when is_binary(value) and value != "" -> {:ok, Path.expand(value)}
      _missing -> {:error, :support_bundle_destination_required}
    end
  end

  defp request_id(opts) do
    case Keyword.get(opts, :request_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _missing -> {:error, :support_bundle_request_id_required}
    end
  end

  defp write_authority(opts) do
    if Keyword.get(opts, :write?, false) and not Keyword.get(opts, :yes?, false),
      do: {:error, :support_bundle_confirmation_required},
      else: :ok
  end

  defp operating_system do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {:unix, name} -> to_string(name)
      {family, name} -> "#{family}-#{name}"
    end
  end

  defp encode(value), do: Jason.encode!(value, pretty: true) <> "\n"

  defp failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code(_reason), do: "unavailable"

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
