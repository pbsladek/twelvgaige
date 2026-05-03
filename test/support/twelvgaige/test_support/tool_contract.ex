defmodule Twelvgaige.TestSupport.ToolContract do
  @moduledoc false

  import ExUnit.Assertions

  alias Twelvgaige.Error
  alias Twelvgaige.Tool
  alias Twelvgaige.Tool.Catalog
  alias Twelvgaige.Tool.Executor
  alias Twelvgaige.Tool.Idempotency
  alias Twelvgaige.Tool.Safety

  def assert_metadata_contract do
    for {name, module} <- Catalog.all() do
      assert tool_behaviour?(module)
      assert module.name() == name
      assert is_binary(module.description())
      assert module.description() != ""

      assert %{"type" => "object", "properties" => properties} = module.input_schema()
      assert is_map(properties)

      assert module.safety_level() in Safety.levels()
      assert %Idempotency{} = module.idempotency()
      assert module.idempotency().class in Idempotency.classes()

      assert module.idempotency().reconciliation_strategy in Idempotency.reconciliation_strategies()

      assert module.idempotency().side_effect_phase in Idempotency.side_effect_phases()
    end
  end

  def assert_invalid_input_contract do
    for name <- Catalog.names() do
      assert {:error, %Error{} = error} =
               Executor.execute(name, %{},
                 allowed_tools: [name],
                 max_safety: :irreversible,
                 limiter: nil
               )

      assert error.class == :tool_error
      assert error.reason == :tool_input_invalid
    end
  end

  def assert_success_contract(root) do
    for case_spec <- success_cases(root) do
      assert {:ok, output} =
               Executor.execute(case_spec.name, case_spec.input,
                 allowed_tools: [case_spec.name],
                 max_safety: :read_only,
                 limiter: nil,
                 max_output_bytes: 128 * 1024,
                 tool_opts: case_spec.opts
               )

      assert is_map(output)
      case_spec.assert_output.(output)
    end
  end

  defp success_cases(root) do
    [
      %{
        name: "shell_read",
        input: %{"path" => "sample.txt", "max_bytes" => 64},
        opts: [root: root],
        assert_output: fn output ->
          assert output["path"] == "sample.txt"
          assert output["content"] == "tool contract file\n"
          refute output["truncated"]
        end
      },
      %{
        name: "http_get",
        input: %{"url" => "https://example.test/health", "max_bytes" => 64},
        opts: [
          allowed_hosts: ["example.test"],
          dns_resolver: fn "example.test" -> {:ok, [{93, 184, 216, 34}]} end,
          transport: fn "https://example.test/health", opts ->
            assert Keyword.fetch!(opts, :max_bytes) == 64
            {:ok, %{status: 200, headers: [{"content-type", "text/plain"}], body: "ok"}}
          end
        ],
        assert_output: fn output ->
          assert output["status"] == 200
          assert output["body"] == "ok"
          assert output["bytes"] == 2
        end
      },
      %{
        name: "kubectl_get",
        input: %{"context" => "kind-contract", "namespace" => "default", "resource" => "pods"},
        opts: [
          command_runner:
            kubectl_runner(~s({"kind":"PodList","items":[{"metadata":{"name":"pod-a"}}]}))
        ],
        assert_output: fn output ->
          assert output["verb"] == "get"
          assert output["summary"]["kind"] == "PodList"
          assert [%{"metadata" => %{"name" => "pod-a"}}] = output["items"]
        end
      },
      %{
        name: "kubectl_describe",
        input: %{
          "context" => "kind-contract",
          "namespace" => "default",
          "resource" => "pods",
          "name" => "pod-a"
        },
        opts: [command_runner: kubectl_runner("Name: pod-a\npassword=secret\n")],
        assert_output: fn output ->
          assert output["verb"] == "describe"
          assert output["text_excerpt"] =~ "Name: pod-a"
          assert output["text_excerpt"] =~ "password=[REDACTED]"
        end
      },
      %{
        name: "kubectl_events",
        input: %{"context" => "kind-contract", "namespace" => "default"},
        opts: [
          command_runner:
            kubectl_runner(
              ~s({"items":[{"type":"Warning","reason":"BackOff","message":"backing off","count":2,"eventTime":"2026-05-02T12:00:00Z","involvedObject":{"name":"pod-a"}}]})
            )
        ],
        assert_output: fn output ->
          assert output["verb"] == "events"
          assert output["summary"]["event_count"] == 1

          assert [%{"reason" => "BackOff", "involved_object" => %{"name" => "pod-a"}}] =
                   output["items"]
        end
      },
      %{
        name: "kubectl_logs",
        input: %{"context" => "kind-contract", "namespace" => "default", "name" => "pod-a"},
        opts: [command_runner: kubectl_runner("line one\ntoken=secret\n")],
        assert_output: fn output ->
          assert output["verb"] == "logs"
          assert output["line_count"] == 2
          assert output["log_excerpt"] =~ "line one"
          assert output["log_excerpt"] =~ "token=[REDACTED]"
        end
      }
    ]
  end

  defp kubectl_runner(stdout) do
    fn "kubectl", args, opts ->
      assert is_list(args)
      assert Keyword.fetch!(opts, :timeout_ms) > 0
      {:ok, %{status: 0, stdout: stdout, stderr: "", duration_ms: 7}}
    end
  end

  defp tool_behaviour?(module) do
    module.module_info(:attributes)
    |> Keyword.get(:behaviour, [])
    |> Enum.member?(Tool)
  end
end
