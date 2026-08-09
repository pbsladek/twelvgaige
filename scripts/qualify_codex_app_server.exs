alias Twelvgaige.DelegatedSession.Codex.{AppServerClient, Approval, Schema}

defmodule Twelvgaige.Qualification.CodexAppServer do
  @poll_ms 100

  def run do
    container = System.fetch_env!("TWELVGAIGE_CODEX_APP_CONTAINER")
    report_path = System.fetch_env!("TWELVGAIGE_CODEX_APP_REPORT")
    timeout_ms = positive_integer_env("TWELVGAIGE_PROVIDER_TIMEOUT_SECONDS", 300) * 1_000
    signing_key = :crypto.strong_rand_bytes(32)

    first = start_client(container, "codex_app_server_qualification", signing_key)

    initialize = expect_ok(AppServerClient.initialize(first), :initialize)

    thread =
      expect_ok(
        AppServerClient.request(first, "thread/start", thread_params(), timeout_ms: timeout_ms),
        :thread_start
      )

    thread_id = get_in(thread, ["thread", "id"])
    require_nonempty(thread_id, :thread_id)

    turn =
      expect_ok(
        AppServerClient.request(first, "turn/start", turn_params(thread_id),
          timeout_ms: timeout_ms
        ),
        :turn_start
      )

    turn_id = get_in(turn, ["turn", "id"])
    require_nonempty(turn_id, :turn_id)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    completion = await_completion(first, signing_key, deadline, initial_result())
    :ok = AppServerClient.close(first)

    second = start_client(container, "codex_app_server_resume_qualification", signing_key)
    _resume_initialize = expect_ok(AppServerClient.initialize(second), :resume_initialize)

    resumed =
      expect_ok(
        AppServerClient.request(
          second,
          "thread/resume",
          Map.put(thread_params(), "threadId", thread_id),
          timeout_ms: timeout_ms
        ),
        :thread_resume
      )

    resumed_thread_id = get_in(resumed, ["thread", "id"])
    :ok = AppServerClient.close(second)

    if resumed_thread_id != thread_id do
      raise "Codex resumed #{inspect(resumed_thread_id)} instead of exact thread #{inspect(thread_id)}"
    end

    if completion.approval_count < 1 do
      raise "Codex completed without exercising a native Twelvgaige approval receipt"
    end

    report = %{
      schema_version: 1,
      result: "pass",
      initialized: %{
        user_agent: initialize["userAgent"],
        platform_family: initialize["platformFamily"],
        platform_os: initialize["platformOs"]
      },
      protocol: %{
        cli_version: Schema.cli_version(),
        schema_digest: Schema.digest(),
        experimental_api: false,
        transport: "stdio",
        thread_id: thread_id,
        turn_id: turn_id,
        exact_resume_thread_id: resumed_thread_id,
        exact_resume_verified: true,
        approval_count: completion.approval_count,
        approval_methods: completion.approval_methods |> MapSet.to_list() |> Enum.sort(),
        event_types:
          completion.event_types |> MapSet.to_list() |> Enum.map(&to_string/1) |> Enum.sort(),
        digest_bound_receipts: true
      }
    }

    report_path |> Path.dirname() |> File.mkdir_p!()
    File.write!(report_path, Jason.encode!(report, pretty: true) <> "\n")
  end

  defp start_client(container, session_id, signing_key) do
    podman = System.find_executable("podman") || raise "podman executable was not found"

    environment =
      ["HOME", "PATH", "TMPDIR", "XDG_CONFIG_HOME", "XDG_RUNTIME_DIR"]
      |> Enum.flat_map(fn key ->
        case System.get_env(key) do
          nil -> []
          value -> [{key, value}]
        end
      end)

    arguments = [
      "exec",
      "--interactive",
      "--user",
      "65532:65532",
      "--env",
      "CODEX_HOME=/run/codex-home",
      "--workdir",
      "/workspace",
      container,
      "/opt/codex/bin/codex",
      "app-server",
      "--stdio",
      "--strict-config"
    ]

    {:ok, client} =
      AppServerClient.start_link(
        session_id: session_id,
        approval_signing_key: signing_key,
        policy_profile: :outer_authoritative,
        binary: podman,
        arguments: arguments,
        environment: environment,
        event_capacity: 2_048,
        critical_event_reserve: 256
      )

    client
  end

  defp thread_params do
    %{
      "cwd" => "/workspace",
      "sandbox" => "danger-full-access",
      "approvalPolicy" => "untrusted",
      "approvalsReviewer" => "user",
      "ephemeral" => false
    }
  end

  defp turn_params(thread_id) do
    %{
      "threadId" => thread_id,
      "cwd" => "/workspace",
      "approvalPolicy" => "untrusted",
      "approvalsReviewer" => "user",
      "sandboxPolicy" => %{
        "type" => "externalSandbox",
        "networkAccess" => "enabled"
      },
      "input" => [
        %{
          "type" => "text",
          "text" =>
            "Work only in /workspace. Do not inspect /run/codex-home or credential files. " <>
              "Use a shell command to create app-server-qualified.txt containing exactly " <>
              "the single line qualified. Use another shell command to verify its exact " <>
              "contents. Do not change README.md."
        }
      ]
    }
  end

  defp initial_result do
    %{approval_count: 0, approval_methods: MapSet.new(), event_types: MapSet.new()}
  end

  defp await_completion(client, signing_key, deadline, result) do
    if System.monotonic_time(:millisecond) >= deadline do
      raise "Codex App Server turn exceeded the qualification deadline"
    end

    {:ok, events} = AppServerClient.drain(client, 1_000)

    {result, terminal} =
      Enum.reduce(events, {result, nil}, fn event, {acc, terminal} ->
        acc = %{acc | event_types: MapSet.put(acc.event_types, event.event_type)}

        case event.event_type do
          :approval_required ->
            approval_id = event.payload["approvalId"] || event.payload["itemId"]
            require_nonempty(approval_id, :approval_id)
            {:ok, %{intent: intent}} = AppServerClient.approval(client, approval_id)
            receipt = Approval.receipt(intent, :accept, "qualification-local-user", signing_key)
            :ok = AppServerClient.decide(client, approval_id, receipt)

            {%{
               acc
               | approval_count: acc.approval_count + 1,
                 approval_methods: MapSet.put(acc.approval_methods, event.payload["nativeMethod"])
             }, terminal}

          :turn_completed ->
            {acc, :complete}

          :session_failed ->
            {acc, {:failed, event.payload}}

          _other ->
            {acc, terminal}
        end
      end)

    case terminal do
      :complete ->
        result

      {:failed, payload} ->
        raise "Codex App Server reported session failure: #{inspect(payload)}"

      nil ->
        Process.sleep(@poll_ms)
        await_completion(client, signing_key, deadline, result)
    end
  end

  defp expect_ok({:ok, value}, _operation), do: value

  defp expect_ok({:error, reason}, operation),
    do: raise("#{operation} failed: #{inspect(reason)}")

  defp require_nonempty(value, _field) when is_binary(value) and value != "", do: value
  defp require_nonempty(value, field), do: raise("missing #{field}: #{inspect(value)}")

  defp positive_integer_env(name, default) do
    case System.get_env(name) do
      nil ->
        default

      encoded ->
        case Integer.parse(encoded) do
          {value, ""} when value > 0 -> value
          _other -> raise "#{name} must be a positive integer"
        end
    end
  end
end

Twelvgaige.Qualification.CodexAppServer.run()
