defmodule Twelvgaige.Round.RunnerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.ResourceLimiter
  alias Twelvgaige.Round.Runner
  alias Twelvgaige.Shell.Agent, as: ShellAgent
  alias Twelvgaige.Shell.Workflow

  defp workflow do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "simple",
        version: "1.0.0",
        shots: [
          %{id: "first", kind: :slug, agent: "agent", prompt: "first prompt"},
          %{
            id: "second",
            kind: :slug,
            agent: "agent",
            depends_on: ["first"],
            prompt: "second prompt"
          }
        ]
      })

    workflow
  end

  test "runs a simple workflow to completion" do
    assert {:ok, snapshot} = Runner.run(workflow(), %{"input" => true}, round_id: "round_test")

    assert snapshot.id == "round_test"
    assert snapshot.status == :complete
    assert Enum.map(snapshot.shots, & &1.id) == ["first", "second"]
    assert Enum.all?(snapshot.shots, &(&1.status == :complete))
  end

  test "records the effective resource profile on foreground snapshots" do
    assert {:ok, snapshot} =
             Runner.run(workflow(), %{},
               round_id: "round_profile",
               profile: :minimal
             )

    assert snapshot.status == :complete
    assert snapshot.resource_profile == :minimal
    assert snapshot.policy.resource_profile == :minimal
  end

  test "skips shots whose conditions evaluate false" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "condition_skip",
        version: "1.0.0",
        shots: [
          %{
            id: "only",
            kind: :slug,
            agent: "agent",
            condition: "input.enabled == true",
            prompt: "only"
          }
        ]
      })

    assert {:ok, snapshot} =
             Runner.run(workflow, %{"enabled" => false}, round_id: "round_condition_skip")

    assert snapshot.status == :complete
    assert [%{id: "only", status: :skipped, output: %{"skipped" => true}}] = snapshot.shots
  end

  test "uses referenced agent loadout for foreground shot execution" do
    parent = self()

    {:ok, agent} =
      ShellAgent.from_map(%{
        kind: :agent,
        id: "inspector",
        version: "1.0.0",
        provider: "mock",
        model: "agent-model",
        system_prompt: "Agent system prompt"
      })

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "agent_loadout_round",
        version: "1.0.0",
        shots: [%{id: "inspect", kind: :slug, agent: "inspector", prompt: "inspect"}]
      })

    handler = fn model, messages, _opts ->
      send(parent, {:llm_loadout, model, messages})
      "ok"
    end

    assert {:ok, snapshot} =
             Runner.run(workflow, %{},
               round_id: "round_agent_loadout",
               agents: [agent],
               mock_handler: handler
             )

    assert snapshot.status == :complete

    assert_receive {:llm_loadout, "agent-model",
                    [%{role: "system", content: "Agent system prompt"} | _]},
                   200
  end

  test "public path API discovers explicit agent shells for loadout and validation" do
    parent = self()
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.yaml")
    agent_path = Path.join(root, "agent.yaml")

    File.write!(workflow_path, workflow_yaml("inspector"))
    File.write!(agent_path, agent_yaml("inspector", "path-agent-model", "Path agent prompt"))

    handler = fn model, messages, _opts ->
      send(parent, {:path_loadout, model, messages})
      "ok"
    end

    assert {:ok, snapshot} =
             Twelvgaige.run_round_sync(workflow_path, %{},
               agent_shells: [agent_path],
               mock_handler: handler
             )

    assert snapshot.status == :complete

    assert_receive {:path_loadout, "path-agent-model",
                    [%{role: "system", content: "Path agent prompt"} | _]},
                   200
  end

  test "public path API discovers agents directory next to workflow" do
    parent = self()
    root = tmp_dir!()
    workflow_path = Path.join(root, "workflow.yaml")
    agent_dir = Path.join(root, "agents")
    agent_path = Path.join(agent_dir, "inspector.yaml")

    File.mkdir_p!(agent_dir)
    File.write!(workflow_path, workflow_yaml("inspector"))
    File.write!(agent_path, agent_yaml("inspector", "auto-agent-model", "Auto agent prompt"))

    handler = fn model, _messages, _opts ->
      send(parent, {:auto_agent_model, model})
      "ok"
    end

    assert {:ok, snapshot} =
             Twelvgaige.run_round_sync(workflow_path, %{}, mock_handler: handler)

    assert snapshot.status == :complete
    assert_receive {:auto_agent_model, "auto-agent-model"}, 200
  end

  test "validates round input before any shot executes" do
    parent = self()

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "input_schema_round",
        version: "1.0.0",
        input_schema: %{
          type: :object,
          required: ["cluster"],
          properties: %{cluster: %{type: :string}},
          additionalProperties: false
        },
        shots: [%{id: "only", kind: :slug, agent: "agent", prompt: "hello"}]
      })

    handler = fn _model, _messages, _opts ->
      send(parent, :shot_executed)
      "ok"
    end

    assert {:error, error} =
             Runner.run(workflow, %{"cluster" => 123},
               round_id: "round_input_invalid",
               mock_handler: handler
             )

    assert error.class == :input_error
    assert error.reason == :input_schema_violation
    assert error.details.path == ["cluster"]
    refute_received :shot_executed
  end

  test "runs a read-only local tool workflow with a file fixture" do
    root = tmp_dir!()
    File.write!(Path.join(root, "report.txt"), "cluster healthy")

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "tool_round",
        version: "1.0.0",
        shots: [
          %{
            id: "inspect",
            kind: :slug,
            agent: "agent",
            tools: ["shell_read"],
            choke: %{max_iterations: 2},
            prompt: "inspect report"
          }
        ]
      })

    response = %{
      content: "reading",
      tool_calls: [%{"name" => "shell_read", "input" => %{"path" => "report.txt"}}]
    }

    assert {:ok, snapshot} =
             Runner.run(workflow, %{},
               response: response,
               tool_opts: [root: root],
               limiter: nil
             )

    assert [%{output: output}] = snapshot.shots

    assert [%{"name" => "shell_read", "output" => %{"content" => "cluster healthy"}}] =
             output["tool_calls"]
  end

  test "runs read-only local and HTTP tool workflow with fake fixtures" do
    parent = self()
    root = tmp_dir!()
    File.write!(Path.join(root, "report.txt"), "cluster healthy")

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "read_only_tool_round",
        version: "1.0.0",
        shots: [
          %{
            id: "inspect",
            kind: :slug,
            agent: "agent",
            tools: ["shell_read", "http_get"],
            choke: %{max_iterations: 2},
            prompt: "inspect local and remote read-only sources"
          }
        ]
      })

    response = %{
      content: "reading",
      tool_calls: [
        %{"name" => "shell_read", "input" => %{"path" => "report.txt"}},
        %{
          "name" => "http_get",
          "input" => %{"url" => "https://example.com/status", "max_bytes" => 64}
        }
      ]
    }

    transport = fn url, opts ->
      send(parent, {:http_get_fixture_called, url, opts})
      {:ok, %{status: 200, headers: [{"content-type", "text/plain"}], body: "ok"}}
    end

    assert {:ok, snapshot} =
             Runner.run(workflow, %{},
               response: response,
               tool_opts: [root: root],
               tool_opts_by_name: %{
                 "http_get" => [
                   allowed_hosts: ["example.com"],
                   dns_resolver: fn "example.com" -> {:ok, [{93, 184, 216, 34}]} end,
                   transport: transport
                 ]
               },
               max_tool_calls_per_shot: 2,
               limiter: nil
             )

    assert snapshot.status == :complete
    assert [%{output: output}] = snapshot.shots

    tool_calls = Map.new(output["tool_calls"], &{&1["name"], &1["output"]})

    assert tool_calls["shell_read"]["content"] == "cluster healthy"
    assert tool_calls["http_get"]["status"] == 200
    assert tool_calls["http_get"]["body"] == "ok"

    assert_receive {:http_get_fixture_called, "https://example.com/status", http_opts}, 200
    assert Keyword.fetch!(http_opts, :max_bytes) == 64
    assert Keyword.fetch!(http_opts, :uri).host == "example.com"
  end

  test "runs read-only Kubernetes workflow against a kubectl fixture" do
    parent = self()

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "kubernetes_fixture_round",
        version: "1.0.0",
        shots: [
          %{
            id: "gather_pods",
            kind: :slug,
            agent: "agent",
            tools: ["kubectl_get"],
            choke: %{max_iterations: 2},
            prompt: "gather pods"
          }
        ]
      })

    response = %{
      content: "reading pods",
      tool_calls: [
        %{
          "name" => "kubectl_get",
          "input" => %{
            "context" => "kind-fixture",
            "namespace" => "payments",
            "resource" => "pods",
            "selector" => "app=payments",
            "limit" => 1
          }
        }
      ]
    }

    command_runner = fn binary, args, opts ->
      send(parent, {:kubectl_fixture_called, binary, args, opts})

      {:ok,
       %{
         status: 0,
         stdout:
           Jason.encode!(%{
             "kind" => "PodList",
             "metadata" => %{"resourceVersion" => "42"},
             "items" => [
               %{"metadata" => %{"name" => "payments-a"}},
               %{"metadata" => %{"name" => "payments-b"}}
             ]
           }),
         stderr: "",
         duration_ms: 5
       }}
    end

    assert {:ok, snapshot} =
             Runner.run(workflow, %{},
               response: response,
               tool_opts_by_name: %{
                 "kubectl_get" => [command_runner: command_runner]
               },
               limiter: nil
             )

    assert snapshot.status == :complete
    assert [%{output: output}] = snapshot.shots
    assert [%{"name" => "kubectl_get", "output" => kubectl_output}] = output["tool_calls"]

    assert kubectl_output["summary"] == %{
             "kind" => "PodList",
             "item_count" => 1,
             "resource_version" => "42"
           }

    assert [%{"metadata" => %{"name" => "payments-a"}}] = kubectl_output["items"]

    assert_receive {:kubectl_fixture_called, "kubectl",
                    [
                      "--context",
                      "kind-fixture",
                      "-n",
                      "payments",
                      "get",
                      "pods",
                      "--selector",
                      "app=payments",
                      "-o",
                      "json"
                    ], [timeout_ms: 30_000]},
                   200
  end

  test "retries retryable shot failures until success" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "retry_round",
        version: "1.0.0",
        shots: [
          %{
            id: "parse",
            kind: :slug,
            agent: "agent",
            retry: %{max_attempts: 2},
            output_schema: %{
              type: :object,
              required: ["summary"],
              properties: %{summary: %{type: :string}},
              additionalProperties: false
            }
          }
        ]
      })

    assert {:ok, snapshot} =
             Runner.run(workflow, %{},
               attempt_responses: ["not json", ~s({"summary":"ok"})],
               retry_sleep?: false
             )

    assert snapshot.status == :complete
    assert [%{attempt: 2, status: :complete, history: [_first_failure]}] = snapshot.shots
  end

  test "releases active-shot permit between retry attempts" do
    limiter =
      start_supervised!(
        {ResourceLimiter, name: nil, limits: %{active_shot: 1, active_shot_per_round: 1}}
      )

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "retry_permit_round",
        version: "1.0.0",
        shots: [
          %{
            id: "parse",
            kind: :slug,
            agent: "agent",
            retry: %{max_attempts: 2},
            output_schema: %{
              type: :object,
              required: ["summary"],
              properties: %{summary: %{type: :string}},
              additionalProperties: false
            }
          }
        ]
      })

    assert {:ok, snapshot} =
             Runner.run(workflow, %{},
               round_id: "round_retry_permit",
               attempt_responses: ["not json", ~s({"summary":"ok"})],
               retry_sleep?: false,
               limiter: limiter,
               queue_timeout_ms: 50
             )

    assert snapshot.status == :complete
    assert [%{attempt: 2, status: :complete}] = snapshot.shots
    assert ResourceLimiter.snapshot(limiter).used.active_shot == 0
  end

  test "fails the round after retry attempts are exhausted" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "retry_exhausted",
        version: "1.0.0",
        shots: [
          %{
            id: "parse",
            kind: :slug,
            agent: "agent",
            retry: %{max_attempts: 2},
            output_schema: %{
              type: :object,
              required: ["summary"],
              properties: %{summary: %{type: :string}},
              additionalProperties: false
            }
          }
        ]
      })

    assert {:ok, snapshot} =
             Runner.run(workflow, %{},
               attempt_responses: ["not json", "still not json"],
               retry_sleep?: false
             )

    assert snapshot.status == :failed
    assert snapshot.error.reason == :output_parse_error
    assert [%{attempt: 2, status: :failed}] = snapshot.shots
  end

  test "does not retry denied tool calls" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "retry_denied",
        version: "1.0.0",
        shots: [
          %{
            id: "denied",
            kind: :slug,
            agent: "agent",
            retry: %{max_attempts: 3},
            choke: %{max_iterations: 2}
          }
        ]
      })

    response = %{
      content: "",
      tool_calls: [%{"name" => "shell_read", "input" => %{"path" => "report.txt"}}]
    }

    assert {:ok, snapshot} =
             Runner.run(workflow, %{},
               response: response,
               retry_sleep?: false,
               limiter: nil
             )

    assert snapshot.status == :failed
    assert snapshot.error.reason == :tool_denied
    assert [%{attempt: 1, status: :failed}] = snapshot.shots
  end

  test "executes independent ready shots in parallel" do
    parent = self()

    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "parallel_round",
        version: "1.0.0",
        shots: [
          %{id: "first", kind: :slug, agent: "agent", prompt: "first prompt"},
          %{id: "second", kind: :slug, agent: "agent", prompt: "second prompt"}
        ]
      })

    handler = fn _model, messages, _opts ->
      shot_id =
        messages
        |> List.last()
        |> Map.fetch!(:content)
        |> then(fn content ->
          cond do
            content =~ "first prompt" -> "first"
            content =~ "second prompt" -> "second"
          end
        end)

      send(parent, {:shot_started, shot_id, self()})

      receive do
        :release -> "complete #{shot_id}"
      after
        1_000 -> exit(:mock_handler_timeout)
      end
    end

    task =
      Task.async(fn ->
        Runner.run(workflow, %{},
          round_id: "round_parallel",
          limiter: nil,
          mock_handler: handler,
          max_parallel_shots: 2
        )
      end)

    started =
      for _ <- 1..2 do
        assert_receive {:shot_started, shot_id, pid}, 1_000
        {shot_id, pid}
      end

    assert started |> Enum.map(&elem(&1, 0)) |> Enum.sort() == ["first", "second"]

    Enum.each(started, fn {_shot_id, pid} -> send(pid, :release) end)

    assert {:ok, snapshot} = Task.await(task, 1_000)

    shots = Map.new(snapshot.shots, &{&1.id, &1})
    assert snapshot.status == :complete
    assert shots["first"].status == :complete
    assert shots["second"].status == :complete
  end

  test "pauses at a safety shot without an inline decision" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "safety_pause",
        version: "1.0.0",
        shots: [
          %{id: "approval", kind: :safety, description: "review"},
          %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"]}
        ]
      })

    assert {:ok, snapshot} = Runner.run(workflow, %{})

    shots = Map.new(snapshot.shots, &{&1.id, &1})
    assert snapshot.status == :awaiting_safety
    assert [%{"shot_id" => "approval", "status" => "awaiting"}] = snapshot.awaiting_safety
    assert shots["approval"].status == :awaiting_safety
    assert shots["after"].status == :pending
  end

  test "dependency-scoped safety pause allows independent ready shots to complete" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "safety_dependency_scope",
        version: "1.0.0",
        shots: [
          %{id: "approval", kind: :safety, description: "review"},
          %{id: "independent", kind: :slug, agent: "agent"},
          %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"]}
        ]
      })

    assert {:ok, snapshot} = Runner.run(workflow, %{})

    shots = Map.new(snapshot.shots, &{&1.id, &1})
    assert snapshot.status == :awaiting_safety
    assert shots["approval"].status == :awaiting_safety
    assert shots["independent"].status == :complete
    assert shots["after"].status == :pending
  end

  test "approves a safety shot with an inline decision" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "safety_approve",
        version: "1.0.0",
        shots: [
          %{id: "approval", kind: :safety, description: "review"},
          %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"]}
        ]
      })

    assert {:ok, snapshot} =
             Runner.run(workflow, %{},
               safety_decisions: %{
                 "approval" => %{decision: "approved", reason: "looks good", actor: "human:me"}
               }
             )

    shots = Map.new(snapshot.shots, &{&1.id, &1})
    assert snapshot.status == :complete
    assert shots["approval"].status == :complete
    assert shots["approval"].output["decision"] == "approved"
    assert shots["approval"].output["actor"] == "human:me"
    assert shots["after"].status == :complete
  end

  test "halts the round when a safety shot is rejected" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "safety_reject",
        version: "1.0.0",
        shots: [
          %{id: "approval", kind: :safety, description: "review"},
          %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"]}
        ]
      })

    assert {:ok, snapshot} =
             Runner.run(workflow, %{}, safety_decisions: %{"approval" => {:reject, "too risky"}})

    shots = Map.new(snapshot.shots, &{&1.id, &1})
    assert snapshot.status == :halted
    assert snapshot.error.reason == :safety_rejected
    assert shots["approval"].status == :failed
    assert shots["after"].status == :pending
  end

  test "can fail instead of halt when safety rejection policy says fail_round" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "safety_reject_fail",
        version: "1.0.0",
        policy: %{on_safety_reject: :fail_round},
        shots: [
          %{id: "approval", kind: :safety, description: "review"}
        ]
      })

    assert {:ok, snapshot} =
             Runner.run(workflow, %{}, safety_decisions: %{"approval" => :rejected})

    assert snapshot.status == :failed
    assert snapshot.error.reason == :safety_rejected
  end

  test "resumes an awaiting safety snapshot after external approval" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "safety_resume_approve",
        version: "1.0.0",
        shots: [
          %{id: "approval", kind: :safety, description: "review"},
          %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"]}
        ]
      })

    assert {:ok, paused} = Runner.run(workflow, %{})
    assert paused.status == :awaiting_safety

    assert {:ok, snapshot} =
             Runner.approve_safety(workflow, paused, "approval",
               reason: "reviewed",
               actor: "human:test"
             )

    shots = Map.new(snapshot.shots, &{&1.id, &1})
    assert snapshot.status == :complete
    assert shots["approval"].status == :complete
    assert shots["approval"].output["reason"] == "reviewed"
    assert shots["after"].status == :complete
  end

  test "resumes an awaiting safety snapshot after external rejection" do
    {:ok, workflow} =
      Workflow.from_map(%{
        kind: :workflow,
        id: "safety_resume_reject",
        version: "1.0.0",
        shots: [
          %{id: "approval", kind: :safety, description: "review"},
          %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"]}
        ]
      })

    assert {:ok, paused} = Runner.run(workflow, %{})

    assert {:ok, snapshot} =
             Runner.reject_safety(workflow, paused, "approval",
               reason: "too risky",
               actor: "human:test"
             )

    shots = Map.new(snapshot.shots, &{&1.id, &1})
    assert snapshot.status == :halted
    assert snapshot.error.reason == :safety_rejected
    assert shots["approval"].status == :failed
    assert shots["after"].status == :pending
  end

  test "public API accepts a workflow map" do
    workflow_map = %{
      kind: :workflow,
      id: "api_simple",
      version: "1.0.0",
      shots: [
        %{id: "only", kind: :slug, agent: "agent", prompt: "hello"}
      ]
    }

    assert {:ok, snapshot} = Twelvgaige.run_round_sync(workflow_map, %{})

    assert snapshot.shell_id == "api_simple"
    assert snapshot.status == :complete
  end

  test "detached rounds submit to Breech" do
    workflow_map = %{
      kind: :workflow,
      id: "api_detached",
      version: "1.0.0",
      shots: [
        %{id: "only", kind: :slug, agent: "agent", prompt: "hello"}
      ]
    }

    assert {:ok, "round_" <> _ = round_id} = Twelvgaige.run_round(workflow_map, %{})

    assert eventually(fn ->
             match?({:ok, %{status: :complete}}, Twelvgaige.get_round(round_id))
           end)
  end

  defp eventually(fun), do: eventually(fun, 20)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts_left) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts_left - 1)
    end
  end

  defp tmp_dir! do
    path = Path.join(System.tmp_dir!(), "twelvgaige-runner-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp workflow_yaml(agent_id) do
    """
    kind: workflow
    id: path_agent_workflow
    version: 1.0.0
    shots:
      - id: inspect
        kind: slug
        agent: #{agent_id}
        prompt: inspect
    """
  end

  defp agent_yaml(agent_id, model, prompt) do
    """
    kind: agent
    id: #{agent_id}
    version: 1.0.0
    provider: mock
    model: #{model}
    system_prompt: #{prompt}
    """
  end
end
