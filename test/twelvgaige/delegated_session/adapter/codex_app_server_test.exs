defmodule Twelvgaige.DelegatedSession.Adapter.CodexAppServerTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.DelegatedSession.Adapter.CodexAppServer

  defmodule FakeClient do
    def initialize(_client, _opts),
      do:
        {:ok,
         %{
           "userAgent" => "codex",
           "codexHome" => "/tmp",
           "platformFamily" => "unix",
           "platformOs" => "linux"
         }}

    def request(client, method, params) do
      Agent.get_and_update(client, fn state ->
        response =
          case method do
            "thread/start" ->
              {:ok, %{"thread" => %{"id" => "thread-1"}}}

            "thread/resume" ->
              {:ok, %{"thread" => %{"id" => state.resume_id || params["threadId"]}}}

            "thread/fork" ->
              {:ok, %{"thread" => %{"id" => "thread-fork"}}}

            "turn/start" ->
              {:ok, %{"turn" => %{"id" => "turn-1"}}}

            "turn/steer" ->
              {:ok, %{}}

            "turn/interrupt" ->
              {:ok, %{}}
          end

        {response, %{state | requests: state.requests ++ [{method, params}]}}
      end)
    end

    def status(_client),
      do:
        {:ok,
         %{
           thread_id: "thread-1",
           turn_id: "turn-1",
           schema_digest: Twelvgaige.DelegatedSession.Codex.Schema.digest(),
           buffer: %{},
           overloaded?: false
         }}

    def decide(_client, _approval_id, _receipt), do: :ok
    def drain(_client, _limit), do: {:ok, []}
    def close(_client), do: :ok
  end

  setup do
    client = start_supervised!({Agent, fn -> %{requests: [], resume_id: nil} end})
    %{client: client}
  end

  test "starts and controls an exact session while preserving native auto-review flags", %{
    client: client
  } do
    spec = spec(client, objective: "Implement the bounded objective")

    assert {:ok, prepared} = CodexAppServer.prepare(spec)
    assert {:ok, authenticated} = CodexAppServer.authenticate(prepared, %{profile: "service"})

    assert {:ok, handle, %{external_session_id: "thread-1", external_turn_id: "turn-1"}} =
             CodexAppServer.start(authenticated, spec)

    assert :ok = CodexAppServer.steer(handle, "turn-1", "Use the verifier output")
    assert :ok = CodexAppServer.cancel(handle, :operator_cancelled)
    assert {:ok, "thread-fork"} = CodexAppServer.fork(handle, last_turn_id: "turn-1")

    requests = Agent.get(client, & &1.requests)

    assert {"thread/start", start_params} = Enum.find(requests, &(elem(&1, 0) == "thread/start"))
    assert start_params["approvalPolicy"] == "on-request"
    assert start_params["approvalsReviewer"] == "auto_review"
    assert start_params["sandbox"] == "workspace-write"

    assert Enum.any?(requests, fn {method, params} ->
             method == "turn/interrupt" and
               params == %{"threadId" => "thread-1", "turnId" => "turn-1"}
           end)
  end

  test "resume rejects a different native thread identity", %{client: client} do
    Agent.update(client, &%{&1 | resume_id: "wrong-thread"})
    spec = spec(client)

    assert {:ok, prepared} = CodexAppServer.prepare(spec)

    assert {:error, {:codex_resume_identity_mismatch, "thread-expected", "wrong-thread"}} =
             CodexAppServer.resume("thread-expected", prepared, spec)
  end

  test "uses the documented external sandbox policy when the attested outer VM is authoritative",
       %{
         client: client
       } do
    spec =
      spec(client,
        objective: "Run inside the outer boundary",
        sandbox_authority: :outer,
        external_network_access: "restricted"
      )

    assert {:ok, prepared} = CodexAppServer.prepare(spec)
    assert {:ok, authenticated} = CodexAppServer.authenticate(prepared, %{profile: "service"})
    assert {:ok, _handle, _identity} = CodexAppServer.start(authenticated, spec)

    requests = Agent.get(client, & &1.requests)
    {"turn/start", params} = Enum.find(requests, &(elem(&1, 0) == "turn/start"))

    assert params["sandboxPolicy"] == %{
             "type" => "externalSandbox",
             "networkAccess" => "restricted"
           }

    refute params["sandboxPolicy"]["type"] == "workspaceWrite"
  end

  defp spec(client, opts \\ []) do
    config = %{
      client: client,
      client_module: FakeClient,
      runtime_version: "0.146.0",
      cwd: "/workspace",
      objective: Keyword.get(opts, :objective),
      sandbox_authority: Keyword.get(opts, :sandbox_authority),
      external_network_access: Keyword.get(opts, :external_network_access, "restricted"),
      approvals_reviewer: "auto_review",
      auth_profile: %{
        id: "service",
        type: :brokered_service,
        revision: 1,
        credential_lease_id: "lease",
        broker_endpoint: "https://broker.invalid"
      }
    }

    %{
      id: "session",
      deadline: DateTime.add(Twelvgaige.Clock.utc_now(), 60, :second),
      capabilities: %{codex: config}
    }
  end
end
