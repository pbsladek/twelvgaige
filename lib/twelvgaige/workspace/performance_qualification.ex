defmodule Twelvgaige.Workspace.PerformanceQualification do
  @moduledoc """
  Builds and qualifies a disposable, representative Git workspace.

  The generated evidence contains host and aggregate measurement data only. It
  deliberately excludes source paths, file contents, patches, and task data.
  """

  alias Twelvgaige.Breech.IPC.Protocol
  alias Twelvgaige.Workspace.Git.ManagedWorkspace

  alias Twelvgaige.Workspace.{
    Canonical,
    RepositoryInspection,
    ResultManifest,
    SourceCapture
  }

  @regular_files 2_000
  @binary_bytes 8 * 1_024 * 1_024
  @schema_version 1
  @default_limits %{
    repository_inspection_ms: 10_000,
    source_capture_ms: 60_000,
    result_capture_ms: 30_000,
    manifest_verification_ms: 30_000,
    memory_growth_bytes: 512 * 1_024 * 1_024,
    disk_amplification_milli: 4_000
  }

  @duration_metrics [
    :repository_inspection_ms,
    :source_capture_ms,
    :result_capture_ms,
    :manifest_verification_ms
  ]

  @spec default_limits() :: map()
  def default_limits, do: @default_limits

  @doc "Evaluates complete measurements against explicit release ceilings."
  @spec evaluate(map(), map()) :: map()
  def evaluate(measurements, limits \\ @default_limits)
      when is_map(measurements) and is_map(limits) do
    limit_checks =
      Enum.map(@duration_metrics ++ [:memory_growth_bytes], fn metric ->
        upper_bound_check(metric, value(measurements, metric), value(limits, metric))
      end)

    disk_check =
      ratio_check(
        value(measurements, :managed_disk_bytes),
        value(measurements, :source_disk_bytes),
        value(limits, :disk_amplification_milli)
      )

    checks = limit_checks ++ [disk_check]

    %{
      status: if(Enum.all?(checks, &(&1.status == "pass")), do: "pass", else: "fail"),
      checks: checks
    }
  end

  @doc "Runs the real Git qualification and atomically writes redacted JSON evidence."
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(opts \\ []) do
    evidence_path =
      Keyword.get(
        opts,
        :evidence_path,
        Path.expand("qualification/evidence/workspace/performance.json")
      )

    limits = Map.merge(@default_limits, Map.new(Keyword.get(opts, :limits, %{})))
    temporary_root = temporary_root(opts)
    File.mkdir!(temporary_root)
    File.chmod!(temporary_root, 0o700)

    started_at = DateTime.utc_now() |> DateTime.truncate(:second)

    qualification =
      try do
        qualify(temporary_root, limits)
      rescue
        error -> {:error, {:qualification_crashed, error.__struct__}}
      catch
        kind, _reason -> {:error, {:qualification_stopped, kind}}
      end

    evidence = evidence(qualification, started_at, limits)

    try do
      with :ok <- write_evidence(evidence_path, evidence) do
        case qualification do
          {:ok, _details} when evidence.status == "pass" -> {:ok, evidence}
          {:ok, _details} -> {:error, {:workspace_performance_limits_exceeded, evidence_path}}
          {:error, reason} -> {:error, {:workspace_performance_qualification_failed, reason}}
        end
      end
    after
      File.rm_rf!(temporary_root)
    end
  end

  defp qualify(root, limits) do
    repository = Path.join(root, "source")
    workspace = Path.join(root, "workspace")

    with {:ok, fixture} <- create_fixture(repository, root),
         baseline_memory <- memory_bytes(),
         {:ok, inspection, inspection_measurement} <-
           measure(fn -> RepositoryInspection.inspect(repository) end),
         :ok <- required_git_version(inspection.git_version),
         {:ok, capture, source_capture_measurement} <-
           measure(fn ->
             SourceCapture.capture(repository, workspace,
               source_mode: :committed,
               workspace_id: "ws_performance_qualification",
               creation_operation_id: "op_performance_qualification",
               git_audit_fun: fn _event -> :ok end
             )
           end),
         {:ok, after_capture} <- RepositoryInspection.inspect(repository),
         :ok <- source_unchanged(inspection, after_capture),
         :ok <- mutate_workspace(workspace),
         {:ok, authority} <-
           ManagedWorkspace.authorize(
             %{id: "ws_performance_qualification", path: workspace, control_epoch: 0},
             expected_epoch: 0,
             lease: "op_performance_qualification",
             operation_id: "op_performance_qualification",
             audit_fun: fn _event -> :ok end,
             scope: :execution
           ),
         {:ok, result, result_measurement} <-
           measure(fn ->
             ManagedWorkspace.capture_result(authority, capture.workspace_baseline_commit,
               artifact_base: inspection.base_commit,
               max_result_files: @regular_files + 100,
               max_result_file_bytes: @binary_bytes + 1_024,
               max_result_bytes: @binary_bytes * 2
             )
           end),
         :ok <- verify_expected_result(result),
         {:ok, manifest, manifest_measurement} <-
           measure(fn -> build_and_verify_manifest(inspection, capture, result) end),
         {:ok, source_disk_bytes} <- disk_usage(repository),
         {:ok, managed_disk_bytes} <- disk_usage(workspace) do
      measurements = %{
        repository_inspection_ms: inspection_measurement.elapsed_ms,
        source_capture_ms: source_capture_measurement.elapsed_ms,
        result_capture_ms: result_measurement.elapsed_ms,
        manifest_verification_ms: manifest_measurement.elapsed_ms,
        memory_growth_bytes:
          [
            inspection_measurement.memory_bytes,
            source_capture_measurement.memory_bytes,
            result_measurement.memory_bytes,
            manifest_measurement.memory_bytes,
            memory_bytes()
          ]
          |> Enum.max()
          |> Kernel.-(baseline_memory)
          |> max(0),
        source_disk_bytes: source_disk_bytes,
        managed_disk_bytes: managed_disk_bytes
      }

      {:ok,
       %{
         fixture: fixture,
         measurements: measurements,
         evaluation: evaluate(measurements, limits),
         result: %{
           changed_paths: length(result.changed_paths),
           patch_bytes: byte_size(result.patch),
           integrity: result.integrity,
           manifest_digest: manifest.manifest_digest
         },
         git_version: inspection.git_version
       }}
    end
  end

  defp create_fixture(repository, home) do
    with :ok <- File.mkdir_p(Path.join(repository, "src")),
         :ok <- File.mkdir_p(Path.join(repository, "docs")),
         :ok <- create_text_files(repository),
         :ok <- create_special_files(repository),
         :ok <- create_binary(Path.join(repository, "assets/payload.bin")),
         {:ok, symlink?} <- create_symlink(repository),
         :ok <- git(repository, ["init", "--quiet"], home),
         :ok <- git(repository, ["config", "user.name", "Qualification"], home),
         :ok <- git(repository, ["config", "user.email", "qualification@localhost"], home),
         :ok <- git(repository, ["add", "--all"], home),
         :ok <- git(repository, ["commit", "--quiet", "-m", "qualification fixture"], home) do
      {:ok,
       %{
         regular_files: @regular_files,
         symlinks: if(symlink?, do: 1, else: 0),
         binary_bytes: @binary_bytes,
         unusual_paths: 4,
         executable_files: 1
       }}
    end
  end

  defp create_text_files(repository) do
    Enum.reduce_while(1..1_994, :ok, fn index, :ok ->
      group = index |> rem(32) |> Integer.to_string() |> String.pad_leading(2, "0")
      directory = Path.join([repository, "src", "group-#{group}"])

      path =
        Path.join(directory, "file-#{String.pad_leading(Integer.to_string(index), 4, "0")}.txt")

      with :ok <- File.mkdir_p(directory),
           :ok <- File.write(path, "qualification file #{index}\n", [:binary]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:fixture_write_failed, reason}}}
      end
    end)
  end

  defp create_special_files(repository) do
    unusual = [
      {"docs/space name.txt", "space\n"},
      {"docs/unicode-ß.txt", "unicode\n"},
      {"docs/-leading-dash.txt", "dash\n"},
      {"docs/comma,name[1].txt", "comma and brackets\n"}
    ]

    with :ok <- write_files(repository, unusual),
         executable = Path.join(repository, "scripts/qualified"),
         :ok <- File.mkdir_p(Path.dirname(executable)),
         :ok <- File.write(executable, "#!/bin/sh\nexit 0\n", [:binary]),
         :ok <- File.chmod(executable, 0o755) do
      :ok
    end
  end

  defp write_files(root, files) do
    Enum.reduce_while(files, :ok, fn {relative, contents}, :ok ->
      case File.write(Path.join(root, relative), contents, [:binary]) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:fixture_write_failed, reason}}}
      end
    end)
  end

  defp create_binary(path) do
    with :ok <- File.mkdir_p(Path.dirname(path)),
         {:ok, device} <- File.open(path, [:write, :binary, :exclusive]) do
      result =
        Enum.reduce_while(0..127, :ok, fn chunk, :ok ->
          bytes =
            0..2_047
            |> Enum.map(fn block -> :crypto.hash(:sha256, <<chunk::32, block::32>>) end)

          case :file.write(device, bytes) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:fixture_binary_write_failed, reason}}}
          end
        end)

      case File.close(device) do
        :ok -> result
        {:error, reason} -> {:error, {:fixture_binary_close_failed, reason}}
      end
    end
  end

  defp create_symlink(repository) do
    case File.ln_s("space name.txt", Path.join(repository, "docs/space-link")) do
      :ok -> {:ok, true}
      {:error, reason} when reason in [:eperm, :enotsup] -> {:ok, false}
      {:error, reason} -> {:error, {:fixture_symlink_failed, reason}}
    end
  end

  defp mutate_workspace(workspace) do
    renamed_from = Path.join(workspace, "src/group-01/file-0001.txt")
    renamed_to = Path.join(workspace, "src/group-01/renamed file.txt")
    binary = Path.join(workspace, "assets/payload.bin")

    with :ok <- File.write(Path.join(workspace, "src/group-02/file-0002.txt"), "edited\n"),
         :ok <- File.rename(renamed_from, renamed_to),
         :ok <- File.rm(Path.join(workspace, "src/group-03/file-0003.txt")),
         {:ok, device} <- File.open(binary, [:read, :write, :binary]),
         :ok <- :file.pwrite(device, 4_096, "TWELVGAIGE-QUALIFIED"),
         :ok <- File.close(device),
         :ok <- File.write(Path.join(workspace, "docs/new result.txt"), "new\n") do
      :ok
    end
  end

  defp verify_expected_result(%{integrity: :verified, no_change: false} = result) do
    paths =
      result.changed_paths
      |> Enum.flat_map(fn change ->
        [:path, :old_path, :new_path]
        |> Enum.flat_map(fn key ->
          case Map.get(change, Atom.to_string(key)) do
            nil -> []
            encoded -> [Canonical.decode_path(encoded)]
          end
        end)
      end)
      |> Enum.flat_map(fn
        {:ok, path} -> [path]
        {:error, _reason} -> []
      end)
      |> MapSet.new()

    expected = [
      "assets/payload.bin",
      "docs/new result.txt",
      "src/group-01/file-0001.txt",
      "src/group-01/renamed file.txt",
      "src/group-02/file-0002.txt",
      "src/group-03/file-0003.txt"
    ]

    if Enum.all?(expected, &MapSet.member?(paths, &1)),
      do: :ok,
      else: {:error, :qualification_result_incomplete}
  end

  defp verify_expected_result(_result), do: {:error, :qualification_result_unverified}

  defp build_and_verify_manifest(inspection, capture, result) do
    with {:ok, manifest} <-
           ResultManifest.new(%{
             workspace_id: "workspace_qualification",
             source_base_commit: inspection.base_commit,
             workspace_baseline_commit: capture.workspace_baseline_commit,
             result_tree: result.result_tree,
             changed_paths: result.changed_paths,
             patch: result.patch,
             no_change: result.no_change,
             outcomes: %{
               agent_execution: :completed,
               result_capture: :complete,
               artifact_integrity: :verified,
               test_verification: :not_run,
               policy_compliance: :compliant,
               workspace_disposition: :reviewable
             },
             created_at: DateTime.utc_now()
           }),
         {:ok, digest} <-
           Canonical.digest(
             "result-manifest",
             manifest.encoding_version,
             ResultManifest.payload(manifest)
           ),
         true <- digest == manifest.manifest_digest do
      {:ok, manifest}
    else
      false -> {:error, :qualification_manifest_digest_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp source_unchanged(before, after_capture) do
    if before.source_state_token == after_capture.source_state_token and
         before.base_commit == after_capture.base_commit and after_capture.dirtiness.clean,
       do: :ok,
       else: {:error, :qualification_source_changed}
  end

  defp required_git_version(actual) do
    case System.get_env("TWELVGAIGE_REQUIRE_GIT_VERSION") do
      nil -> :ok
      "" -> :ok
      ^actual -> :ok
      _mismatch -> {:error, :qualification_git_version_mismatch}
    end
  end

  defp measure(fun) do
    started = System.monotonic_time(:microsecond)
    result = fun.()
    elapsed = System.monotonic_time(:microsecond) - started
    measurement = %{elapsed_ms: max(div(elapsed + 999, 1_000), 1), memory_bytes: memory_bytes()}

    case result do
      {:ok, value} -> {:ok, value, measurement}
      {:error, _reason} = error -> error
    end
  end

  defp evidence({:ok, details}, generated_at, limits) do
    %{
      schema_version: @schema_version,
      generated_at: generated_at,
      status: details.evaluation.status,
      scope: "single-user local Git workspace qualification",
      host: host(details.git_version),
      fixture: details.fixture,
      measurements: details.measurements,
      limits: limits,
      evaluation: details.evaluation,
      result: details.result
    }
  end

  defp evidence({:error, reason}, generated_at, limits) do
    %{
      schema_version: @schema_version,
      generated_at: generated_at,
      status: "fail",
      scope: "single-user local Git workspace qualification",
      host: host("unreported"),
      limits: limits,
      failure: %{code: failure_code(reason)}
    }
  end

  defp host(git_version) do
    %{
      operating_system: operating_system(),
      architecture: :erlang.system_info(:system_architecture) |> to_string(),
      git_version: git_version,
      cli_version: Application.spec(:twelvgaige, :vsn) |> to_string(),
      daemon_protocol_version: Protocol.api_version(),
      otp_version: :erlang.system_info(:otp_release) |> to_string(),
      elixir_version: System.version()
    }
  end

  defp operating_system do
    case :os.type() do
      {:unix, :darwin} -> "macos"
      {:unix, name} -> to_string(name)
      {family, name} -> "#{family}-#{name}"
    end
  end

  defp disk_usage(path) do
    case System.cmd("du", ["-sk", path], stderr_to_stdout: true) do
      {output, 0} ->
        case output |> String.split() |> List.first() |> Integer.parse() do
          {kilobytes, ""} when kilobytes >= 0 -> {:ok, kilobytes * 1_024}
          _invalid -> {:error, :qualification_disk_measurement_invalid}
        end

      {_output, _status} ->
        {:error, :qualification_disk_measurement_failed}
    end
  rescue
    _error -> {:error, :qualification_disk_measurement_failed}
  end

  defp write_evidence(destination, evidence) do
    destination = Path.expand(destination)
    parent = Path.dirname(destination)
    staging = destination <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(parent),
         :ok <-
           File.write(staging, [Jason.encode_to_iodata!(evidence, pretty: true), "\n"], [
             :exclusive
           ]),
         :ok <- File.chmod(staging, 0o600),
         :ok <- File.rename(staging, destination) do
      :ok
    else
      {:error, reason} ->
        _ = File.rm(staging)
        {:error, {:qualification_evidence_write_failed, reason}}
    end
  end

  defp git(repository, args, home) do
    command = [
      "-c",
      "core.hooksPath=/dev/null",
      "-c",
      "credential.helper=",
      "-C",
      repository
      | args
    ]

    env = [
      {"GIT_CONFIG_GLOBAL", "/dev/null"},
      {"GIT_CONFIG_NOSYSTEM", "1"},
      {"GIT_TERMINAL_PROMPT", "0"},
      {"HOME", home}
    ]

    case System.cmd("git", command, env: env, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, :qualification_git_command_failed}
    end
  rescue
    _error -> {:error, :qualification_git_unavailable}
  end

  defp upper_bound_check(metric, observed, limit)
       when is_integer(observed) and observed >= 0 and is_integer(limit) and limit >= 0 do
    %{
      metric: metric,
      observed: observed,
      limit: limit,
      status: if(observed <= limit, do: "pass", else: "fail")
    }
  end

  defp upper_bound_check(metric, observed, limit) do
    %{metric: metric, observed: observed, limit: limit, status: "missing"}
  end

  defp ratio_check(managed, source, limit)
       when is_integer(managed) and managed >= 0 and is_integer(source) and source > 0 and
              is_integer(limit) and limit >= 0 do
    observed = div(managed * 1_000, source)

    %{
      metric: :disk_amplification_milli,
      observed: observed,
      limit: limit,
      status: if(observed <= limit, do: "pass", else: "fail")
    }
  end

  defp ratio_check(managed, source, limit) do
    %{
      metric: :disk_amplification_milli,
      observed: %{managed_disk_bytes: managed, source_disk_bytes: source},
      limit: limit,
      status: "missing"
    }
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, Atom.to_string(key)))

  defp failure_code(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code({reason, _details}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code({reason, _one, _two}) when is_atom(reason), do: Atom.to_string(reason)
  defp failure_code(_reason), do: "qualification_failed"

  defp memory_bytes, do: :erlang.memory(:total)

  defp temporary_root(opts) do
    case Keyword.get(opts, :temporary_root) do
      nil ->
        Path.join(
          System.tmp_dir!(),
          "twelvgaige-workspace-qualification-#{System.unique_integer([:positive])}"
        )

      path ->
        Path.expand(path)
    end
  end
end
