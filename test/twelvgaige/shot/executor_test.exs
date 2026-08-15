defmodule Twelvgaige.Shot.ExecutorTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Shell.Workflow
  alias Twelvgaige.Shot.Attempt
  alias Twelvgaige.Shot.Executor
  alias Twelvgaige.ResourceLimiter

  defp shot(attrs \\ %{}) do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "tool_workflow",
        version: "1.0.0",
        shots: [
          Map.merge(
            %{
              id: "inspect_file",
              kind: :slug,
              agent: "agent",
              tools: ["shell_read"],
              choke: %{max_iterations: 2}
            },
            attrs
          )
        ]
      })

    hd(workflow.shots)
  end

  defp attempt(shot) do
    Attempt.new(
      round_id: "round_1",
      shot_id: shot.id,
      attempt: 1,
      definition: shot,
      loadout: %{provider: :mock, model: "mock-model", system_prompt: "test"},
      input: %{},
      dependency_outputs: %{}
    )
  end

  test "executes normalized tool calls and returns final content" do
    root = tmp_dir!()
    File.write!(Path.join(root, "report.txt"), "status ok")

    response = %{
      content: "read the report",
      tool_calls: [
        %{"name" => "shell_read", "input" => %{"path" => "report.txt"}}
      ]
    }

    assert {:ok, result} =
             shot()
             |> attempt()
             |> Executor.run(response: response, tool_opts: [root: root], limiter: nil)

    assert result.content =~ "mock response:"

    assert [%{"name" => "shell_read", "output" => %{"content" => "status ok"}}] =
             result.tool_calls

    assert Enum.any?(result.messages, &(&1.role == "tool" and &1.source == :tool_execution))
  end

  test "redacts tool result messages before they re-enter LLM context" do
    root = tmp_dir!()
    File.write!(Path.join(root, "secrets.txt"), "api_key=secret-token\nstatus ok")

    response = %{
      content: "read secrets",
      tool_calls: [
        %{"name" => "shell_read", "input" => %{"path" => "secrets.txt"}}
      ]
    }

    assert {:ok, result} =
             shot()
             |> attempt()
             |> Executor.run(response: response, tool_opts: [root: root], limiter: nil)

    tool_message = Enum.find(result.messages, &(&1.role == "tool"))

    assert tool_message.content =~ "[REDACTED]"
    refute tool_message.content =~ "secret-token"
  end

  test "caps tool result messages before they re-enter LLM context" do
    root = tmp_dir!()
    File.write!(Path.join(root, "large.txt"), String.duplicate("x", 1_000))

    response = %{
      content: "read large",
      tool_calls: [
        %{"name" => "shell_read", "input" => %{"path" => "large.txt"}}
      ]
    }

    assert {:ok, result} =
             shot()
             |> attempt()
             |> Executor.run(
               response: response,
               tool_opts: [root: root],
               tool_result_message_max_bytes: 128,
               limiter: nil
             )

    tool_message = Enum.find(result.messages, &(&1.role == "tool"))

    assert byte_size(tool_message.content) <= 128
    assert tool_message.content =~ "truncated"
  end

  test "enforces aggregate tool output bytes across a shot" do
    root = tmp_dir!()
    File.write!(Path.join(root, "large.txt"), String.duplicate("x", 1_000))

    response = %{
      content: "read large",
      tool_calls: [
        %{"name" => "shell_read", "input" => %{"path" => "large.txt"}}
      ]
    }

    assert {:error, error} =
             shot()
             |> attempt()
             |> Executor.run(
               response: response,
               tool_opts: [root: root],
               tool_max_output_bytes: 2_000,
               tool_max_output_bytes_per_shot: 128,
               limiter: nil
             )

    assert error.class == :output_error
    assert error.reason == :output_too_large
    assert error.details.max_output_bytes_per_shot == 128
    assert error.details.output_bytes > 128
  end

  test "validates final output when a shot declares an output schema" do
    shot =
      shot(%{
        output_schema: %{
          type: :object,
          required: ["summary", "ok"],
          properties: %{
            summary: %{type: :string},
            ok: %{type: :boolean}
          },
          additionalProperties: false
        }
      })

    assert {:ok, result} =
             shot
             |> attempt()
             |> Executor.run(response: ~s({"summary":"green","ok":true}), limiter: nil)

    assert result.output == %{"summary" => "green", "ok" => true}
  end

  test "rejects malformed final output when an output schema is declared" do
    shot =
      shot(%{
        output_schema: %{
          type: :object,
          required: ["summary"],
          properties: %{summary: %{type: :string}},
          additionalProperties: false
        }
      })

    assert {:error, error} =
             shot
             |> attempt()
             |> Executor.run(response: "plain text", limiter: nil)

    assert error.reason == :output_parse_error
  end

  test "rejects final output that violates its output schema" do
    shot =
      shot(%{
        output_schema: %{
          type: :object,
          required: ["summary"],
          properties: %{summary: %{type: :string}},
          additionalProperties: false
        }
      })

    assert {:error, error} =
             shot
             |> attempt()
             |> Executor.run(response: ~s({"summary":false}), limiter: nil)

    assert error.reason == :output_schema_violation
    assert error.details.path == ["summary"]
  end

  test "bounds LLM calls through the configured resource limiter" do
    limiter = start_supervised!({ResourceLimiter, name: nil, limits: %{llm_call: 1}})
    assert {:ok, permit} = ResourceLimiter.acquire(:llm_call, %{}, server: limiter)

    assert {:error, error} =
             shot()
             |> attempt()
             |> Executor.run(response: "will not run", limiter: limiter)

    assert error.class == :timeout_error
    assert error.reason == :resource_queue_timeout
    assert error.retryable
    assert :ok = ResourceLimiter.release(permit)
  end

  test "rejects oversized LLM message context before provider call" do
    assert {:error, error} =
             shot()
             |> attempt()
             |> Executor.run(response: "will not run", max_llm_message_bytes: 16, limiter: nil)

    assert error.class == :llm_error
    assert error.reason == :llm_context_too_large
    assert error.details.max_message_bytes == 16
    assert error.details.message_bytes > 16
  end

  test "rejects provider usage that exceeds the token budget" do
    response = %{
      content: "done",
      usage: %{input_tokens: 8, output_tokens: 5, total_tokens: 13}
    }

    assert {:error, error} =
             shot(%{choke: %{token_budget: 10}})
             |> attempt()
             |> Executor.run(response: response, limiter: nil)

    assert error.class == :llm_error
    assert error.reason == :llm_context_too_large
    assert error.details.token_budget == 10
    assert error.details.total_tokens == 13
  end

  test "enforces token budget cumulatively across tool iterations" do
    root = tmp_dir!()
    File.write!(Path.join(root, "report.txt"), "ok")

    responses = [
      %{
        content: "read",
        tool_calls: [
          %{"id" => "call_1", "name" => "shell_read", "input" => %{path: "report.txt"}}
        ],
        usage: %{input_tokens: 3, output_tokens: 3, total_tokens: 6}
      },
      %{
        content: "done",
        usage: %{input_tokens: 3, output_tokens: 3, total_tokens: 6}
      }
    ]

    assert {:error, error} =
             shot(%{choke: %{token_budget: 10, max_iterations: 2}})
             |> attempt()
             |> Executor.run(responses: responses, tool_opts: [root: root], limiter: nil)

    assert error.reason == :llm_context_too_large
    assert error.details.token_budget == 10
    assert error.details.total_tokens == 12
  end

  test "passes tool and structured-output schemas plus remaining budget to the provider" do
    parent = self()

    transport = fn request ->
      send(parent, {:provider_request, request})

      {:ok,
       %{
         status: 200,
         headers: [],
         body: %{
           "choices" => [%{"message" => %{"content" => ~s({"summary":"green"})}}],
           "usage" => %{"prompt_tokens" => 2, "completion_tokens" => 2}
         }
       }}
    end

    shot =
      shot(%{
        choke: %{token_budget: 10},
        output_schema: %{
          type: "object",
          required: ["summary"],
          properties: %{summary: %{type: "string"}}
        }
      })

    attempt =
      shot
      |> attempt()
      |> Map.put(:loadout, %{provider: :openai, model: "gpt-test", system_prompt: "test"})

    assert {:ok, result} = Executor.run(attempt, transport: transport, limiter: nil)
    assert result.output == %{"summary" => "green"}

    assert_receive {:provider_request, request}
    assert request.body["max_completion_tokens"] == 10
    refute Map.has_key?(request.body, "max_tokens")
    assert get_in(request.body, ["tools", Access.at(0), "function", "name"]) == "shell_read"

    assert get_in(request.body, ["response_format", "json_schema", "schema", "type"]) ==
             "object"
  end

  test "denies tool calls outside the shot allowlist" do
    response = %{
      content: "",
      tool_calls: [%{"name" => "http_get", "input" => %{"url" => "https://example.com"}}]
    }

    assert {:error, error} =
             shot()
             |> attempt()
             |> Executor.run(response: response, limiter: nil)

    assert error.reason == :tool_denied
  end

  test "enforces per-shot tool call budget" do
    response = %{
      content: "",
      tool_calls: [
        %{"name" => "shell_read", "input" => %{"path" => "a.txt"}},
        %{"name" => "shell_read", "input" => %{"path" => "b.txt"}}
      ]
    }

    assert {:error, error} =
             shot()
             |> attempt()
             |> Executor.run(response: response, limiter: nil)

    assert error.class == :policy_error
    assert error.reason == :policy_denied
  end

  test "classifies max ReAct iteration exhaustion" do
    root = tmp_dir!()
    File.write!(Path.join(root, "a.txt"), "ok")

    response = %{
      content: "",
      tool_calls: [%{"name" => "shell_read", "input" => %{"path" => "a.txt"}}]
    }

    shot = shot(%{choke: %{max_iterations: 1}})

    assert {:error, error} =
             shot
             |> attempt()
             |> Executor.run(response: response, tool_opts: [root: root], limiter: nil)

    assert shot.choke.max_iterations == 1
    assert error.class == :output_error
    assert error.reason == :output_parse_error
  end

  test "agent limits restrict a more permissive shot" do
    root = tmp_dir!()
    File.write!(Path.join(root, "a.txt"), "ok")

    response = %{
      content: "",
      tool_calls: [%{"name" => "shell_read", "input" => %{"path" => "a.txt"}}]
    }

    attempt =
      shot(%{choke: %{max_iterations: 6, token_budget: 100}})
      |> attempt()
      |> Map.update!(:loadout, fn loadout ->
        Map.put(loadout, :choke, %{max_iterations: 1, token_budget: 10})
      end)

    assert {:error, iteration_error} =
             Executor.run(attempt,
               response: response,
               tool_opts: [root: root],
               limiter: nil
             )

    assert iteration_error.message =~ "max ReAct iterations"
    assert iteration_error.details.max_iterations == 1

    assert {:error, budget_error} =
             Executor.run(attempt,
               response: %{content: "done", usage: %{total_tokens: 11}},
               limiter: nil
             )

    assert budget_error.details.token_budget == 10
  end

  test "agent tool policy is enforced again at execution" do
    response = %{
      content: "",
      tool_calls: [%{"name" => "shell_read", "input" => %{"path" => "a.txt"}}]
    }

    attempt =
      shot()
      |> attempt()
      |> Map.update!(:loadout, &Map.put(&1, :tool_policy, %{allowed: [], denied: []}))

    assert {:error, error} = Executor.run(attempt, response: response, limiter: nil)
    assert error.reason == :tool_denied
  end

  defp tmp_dir! do
    path =
      Path.join(
        System.tmp_dir!(),
        "twelvgaige-shot-executor-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
