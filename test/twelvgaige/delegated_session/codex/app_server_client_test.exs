defmodule Twelvgaige.DelegatedSession.Codex.AppServerClientTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.DelegatedSession.Codex.{AppServerClient, Approval}

  setup do
    test_pid = self()
    key = :crypto.strong_rand_bytes(32)

    client =
      start_supervised!(
        {AppServerClient,
         session_id: "session",
         approval_signing_key: key,
         send_frame: fn data ->
           send(test_pid, {:outbound, IO.iodata_to_binary(data)})
           :ok
         end}
      )

    %{client: client, key: key}
  end

  test "initializes the stable protocol with experimental API disabled", %{client: client} do
    task = Task.async(fn -> AppServerClient.initialize(client) end)

    assert_receive {:outbound, initialize}
    frame = Jason.decode!(initialize)
    assert frame["method"] == "initialize"
    assert frame["params"]["clientInfo"]["name"] == "twelvgaige"
    assert frame["params"]["capabilities"]["experimentalApi"] == false

    AppServerClient.ingest(client, %{
      "id" => frame["id"],
      "result" => %{
        "userAgent" => "codex-cli/0.146.0",
        "codexHome" => "/sandbox/codex-home",
        "platformFamily" => "unix",
        "platformOs" => "linux"
      }
    })

    assert {:ok, _result} = Task.await(task)
    assert_receive {:outbound, initialized}
    assert %{"method" => "initialized"} = Jason.decode!(initialized)
    assert {:ok, %{initialized?: true}} = AppServerClient.status(client)
  end

  test "persists exact thread and turn identities from schema-checked responses", %{
    client: client
  } do
    thread_task =
      Task.async(fn ->
        AppServerClient.request(client, "thread/start", %{
          "cwd" => "/workspace",
          "sandbox" => "workspace-write",
          "approvalPolicy" => "on-request"
        })
      end)

    assert_receive {:outbound, thread_request}
    thread_frame = Jason.decode!(thread_request)

    AppServerClient.ingest(client, %{
      "id" => thread_frame["id"],
      "result" => %{"thread" => %{"id" => "thread_exact"}}
    })

    assert {:ok, _result} = Task.await(thread_task)

    turn_task =
      Task.async(fn ->
        AppServerClient.request(client, "turn/start", %{
          "threadId" => "thread_exact",
          "input" => [%{"type" => "text", "text" => "work"}],
          "approvalPolicy" => "on-request",
          "sandboxPolicy" => %{"type" => "workspaceWrite"}
        })
      end)

    assert_receive {:outbound, turn_request}
    turn_frame = Jason.decode!(turn_request)

    AppServerClient.ingest(client, %{
      "id" => turn_frame["id"],
      "result" => %{"turn" => %{"id" => "turn_exact"}}
    })

    assert {:ok, _result} = Task.await(turn_task)

    assert {:ok, %{thread_id: "thread_exact", turn_id: "turn_exact"}} =
             AppServerClient.status(client)
  end

  test "maps native subagents and bounds protocol-event floods", %{client: client} do
    for id <- 1..1_000 do
      AppServerClient.ingest(client, %{
        "method" => "item/agentMessage/delta",
        "params" => %{
          "threadId" => "thread",
          "turnId" => "turn",
          "itemId" => "message",
          "delta" => Integer.to_string(id)
        }
      })
    end

    AppServerClient.ingest(client, %{
      "method" => "item/started",
      "params" => %{
        "threadId" => "thread",
        "turnId" => "turn",
        "item" => %{
          "id" => "subagent",
          "type" => "subAgentActivity",
          "agentThreadId" => "child-thread"
        }
      }
    })

    assert {:ok, events} = AppServerClient.drain(client, 20)
    assert Enum.any?(events, &(&1.event_type == :subagent_started))
    assert Enum.count(events, &(&1.event_type == :message_delta)) == 1
  end

  test "native approvals require an untampered digest-bound receipt", %{client: client, key: key} do
    AppServerClient.ingest(client, %{
      "jsonrpc" => "2.0",
      "id" => "rpc-approval",
      "method" => "item/commandExecution/requestApproval",
      "params" => %{
        "threadId" => "thread",
        "turnId" => "turn",
        "itemId" => "item",
        "startedAtMs" => 1,
        "command" => "mix test"
      }
    })

    assert {:ok, %{intent: intent}} = AppServerClient.approval(client, "item")
    receipt = Approval.receipt(intent, :accept, "operator", key)

    assert {:error, :approval_digest_mismatch} =
             AppServerClient.decide(client, "item", %{receipt | action_digest: "tampered"})

    assert :ok = AppServerClient.decide(client, "item", receipt)
    assert_receive {:outbound, decision}

    assert %{"id" => "rpc-approval", "result" => %{"decision" => "accept"}} =
             Jason.decode!(decision)
  end
end
