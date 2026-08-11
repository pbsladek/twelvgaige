defmodule Twelvgaige.Manager.VerificationExecutor do
  @moduledoc "Runs independent verification inside a fresh, networkless sandbox copy."

  @default_limits %{cpu: 2, memory_bytes: 4 * 1_073_741_824, pids: 512}

  @spec from_options(keyword()) :: (map() -> {:ok, map()} | {:error, term()}) | nil
  def from_options(opts) when is_list(opts) do
    if configured?(opts), do: &execute(&1, opts), else: nil
  end

  def from_options(_opts), do: nil

  @spec execute(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def execute(request, opts) when is_map(request) and is_list(opts) do
    with :ok <- validate_request(request),
         {:ok, backend} <- backend(opts),
         {:ok, backend_opts} <- backend_options(request, opts),
         {:ok, manifest} <- backend.prepare(sandbox_spec(request, opts), backend_opts),
         {:ok, resource_id, _resource} <-
           backend.create(
             manifest,
             Keyword.put(backend_opts, :command, verification_command(request))
           ) do
      run_created(backend, resource_id, manifest, request, backend_opts)
    end
  end

  def execute(_request, _opts), do: {:error, :verification_executor_options_invalid}

  defp run_created(backend, resource_id, manifest, request, opts) do
    started_at = Twelvgaige.Clock.utc_now()
    runtime_opts = Keyword.put(opts, :manifest, manifest)

    result =
      with :ok <- callback_available(backend, :await),
           :ok <- callback_available(backend, :logs),
           {:ok, _process} <- backend.start(resource_id, runtime_opts),
           {:ok, wait_evidence} <- backend.await(resource_id, runtime_opts),
           {:ok, logs} <- backend.logs(resource_id, runtime_opts),
           {:ok, commands} <- command_evidence(logs, request) do
        {:ok,
         %{
           request_digest: request.request_digest,
           backend: backend_name(backend, manifest),
           network_mode: :none,
           credentials_present: false,
           provider_environment_present: false,
           workspace_copy: true,
           commands: commands,
           runtime_exit_status: value(wait_evidence, :exit_status),
           started_at: started_at,
           finished_at: Twelvgaige.Clock.utc_now()
         }}
      end

    cleanup_result = backend.destroy(resource_id, runtime_opts)
    combine_result(result, cleanup_result)
  end

  defp configured?(opts) do
    is_atom(Keyword.get(opts, :backend)) and present?(Keyword.get(opts, :image_reference)) and
      valid_digest?(Keyword.get(opts, :image_digest)) and
      is_list(Keyword.get(opts, :allowed_roots))
  end

  defp validate_request(request) do
    cond do
      value(request, :workspace_copy) != true ->
        {:error, :verification_workspace_not_independent}

      value(request, :network_mode) not in [:none, "none"] ->
        {:error, :verification_network_boundary_failed}

      not is_nil(value(request, :credential_lease_id)) ->
        {:error, :verification_credentials_present}

      value(request, :provider_environment) != false ->
        {:error, :verification_provider_environment_present}

      value(request, :environment_names, []) != [] ->
        {:error, :verification_environment_unsafe}

      not File.dir?(value(request, :source_path, "")) ->
        {:error, :verification_source_path_missing}

      not present?(value(request, :request_digest)) ->
        {:error, :verification_request_digest_missing}

      true ->
        :ok
    end
  end

  defp backend(opts) do
    case Keyword.get(opts, :backend) do
      backend when is_atom(backend) -> {:ok, backend}
      _invalid -> {:error, :verification_backend_invalid}
    end
  end

  defp backend_options(request, opts) do
    roots = Keyword.get(opts, :allowed_roots, []) |> Enum.map(&Path.expand/1)
    source = request |> value(:source_path) |> Path.expand()

    if Enum.any?(roots, &(source == &1 or String.starts_with?(source, &1 <> "/"))) do
      {:ok,
       opts
       |> Keyword.get(:backend_opts, [])
       |> Keyword.put(:allowed_roots, roots)
       |> Keyword.put(:timeout_ms, value(request, :timeout_ms, 900_000))
       |> Keyword.put(:verification_command_count, length(value(request, :commands, [])))}
    else
      {:error, :verification_source_outside_allowed_roots}
    end
  end

  defp sandbox_spec(request, opts) do
    now = Twelvgaige.Clock.utc_now()

    %{
      profile: :integration_test,
      image_reference: Keyword.fetch!(opts, :image_reference),
      image_digest: Keyword.fetch!(opts, :image_digest),
      workspace_transport: :copy_snapshot,
      mounts: [
        %{source: value(request, :source_path), destination: "/workspace", mode: :read_write}
      ],
      network_mode: :none,
      allowed_destinations: [],
      limits: Keyword.get(opts, :limits, @default_limits),
      deadline: DateTime.add(now, value(request, :timeout_ms, 900_000), :millisecond),
      credential_lease_id: nil,
      policy_revision: Keyword.get(opts, :policy_revision, "verification-v1"),
      created_at: now,
      environment_names: [],
      labels: %{
        "io.twelvgaige.purpose" => "independent-verification",
        "io.twelvgaige.workspace" => value(request, :workspace_id)
      }
    }
  end

  defp verification_command(request) do
    marker = marker(request)

    body =
      request
      |> value(:commands, [])
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {argv, index} ->
        command = Enum.map_join(argv, " ", &shell_quote/1)

        "#{command}\n" <>
          "command_status=$?\n" <>
          "printf '\\n#{marker}_#{index}=%s\\n' \"$command_status\"\n" <>
          "[ \"$command_status\" -eq 0 ] || overall_status=1"
      end)

    [
      "/bin/sh",
      "-c",
      "set +e\noverall_status=0\n#{body}\nprintf '#{marker}_done=%s\\n' \"$overall_status\"\nexit \"$overall_status\""
    ]
  end

  defp command_evidence(logs, request) when is_binary(logs) do
    marker = Regex.escape(marker(request))
    matches = Regex.scan(~r/^#{marker}_(\d+)=(\d+)$/m, logs, capture: :all_but_first)
    done = Regex.run(~r/^#{marker}_done=(\d+)$/m, logs, capture: :all_but_first)
    commands = value(request, :commands, [])

    parsed =
      Map.new(matches, fn [index, status] ->
        {String.to_integer(index), String.to_integer(status)}
      end)

    if map_size(parsed) == length(commands) and is_list(done) do
      {:ok,
       commands
       |> Enum.with_index()
       |> Enum.map(fn {argv, index} -> %{argv: argv, exit_status: Map.fetch!(parsed, index)} end)}
    else
      {:error,
       {:verification_command_evidence_incomplete,
        %{
          log_bytes: byte_size(logs),
          marker_lines: marker_lines(logs, marker(request)),
          observed_commands: map_size(parsed),
          expected_commands: length(commands),
          done_marker: is_list(done)
        }}}
    end
  end

  defp command_evidence(_logs, _request),
    do: {:error, :verification_command_evidence_incomplete}

  defp marker_lines(logs, marker) do
    logs
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(String.trim(&1), marker))
    |> Enum.map(&String.trim/1)
    |> Enum.take(100)
  end

  defp marker(request) do
    suffix =
      :sha256
      |> :crypto.hash(value(request, :request_digest))
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 16)

    "__TWELVGAIGE_VERIFY_#{suffix}"
  end

  defp callback_available(backend, callback) do
    if function_exported?(backend, callback, 2),
      do: :ok,
      else: {:error, {:verification_backend_callback_missing, callback}}
  end

  defp combine_result({:ok, evidence}, :ok), do: {:ok, evidence}
  defp combine_result({:error, reason}, :ok), do: {:error, reason}

  defp combine_result({:ok, _evidence}, {:error, cleanup_reason}),
    do: {:error, {:verification_cleanup_failed, cleanup_reason}}

  defp combine_result({:error, reason}, {:error, cleanup_reason}),
    do: {:error, {:verification_failed_with_cleanup_error, reason, cleanup_reason}}

  defp backend_name(_backend, %{backend: name}), do: name
  defp backend_name(backend, _manifest), do: backend

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp present?(value), do: is_binary(value) and value != ""

  defp valid_digest?("sha256:" <> digest), do: Regex.match?(~r/^[0-9a-f]{64}$/, digest)
  defp valid_digest?(_digest), do: false

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
