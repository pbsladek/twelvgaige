defmodule Twelvgaige.API.RouterTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.API.Router
  alias Twelvgaige.API.WebhookReplayCache
  alias Twelvgaige.Breech
  alias Twelvgaige.Store.File, as: FileStore

  @auth_token "router-secret"

  @workflow %{
    kind: :workflow,
    id: "api_workflow",
    version: "1.0.0",
    shots: [
      %{id: "only", kind: :slug, agent: "agent", prompt: "hello"}
    ]
  }

  @safety_workflow %{
    kind: :workflow,
    id: "api_safety_workflow",
    version: "1.0.0",
    shots: [
      %{id: "approval", kind: :safety, description: "review"},
      %{id: "after", kind: :slug, agent: "agent", depends_on: ["approval"], prompt: "after"}
    ]
  }

  setup do
    dir =
      Path.join(System.tmp_dir!(), "twelvgaige_api_router_#{System.unique_integer([:positive])}")

    path = Path.join(dir, "store.etf")
    breech_name = :"api_breech_#{System.unique_integer([:positive])}"

    on_exit(fn -> File.rm_rf(dir) end)

    start_supervised!({FileStore, path: path})
    start_supervised!({Breech, name: breech_name, store: FileStore})

    %{breech: breech_name}
  end

  test "reports local health", %{breech: breech} do
    response = Router.dispatch("GET", "/api/v1/health", "", server: breech)

    assert response.status == 200
    assert %{"status" => "ok", "breech" => %{"status" => "running"}} = decode(response)
  end

  test "exposes prometheus metrics", %{breech: breech} do
    response = Router.dispatch("GET", "/api/v1/metrics", "", server: breech)

    assert response.status == 200
    assert {"content-type", "text/plain; version=0.0.4; charset=utf-8"} in response.headers
    assert response.body =~ "# TYPE twelvgaige_up gauge\n"
    assert response.body =~ "twelvgaige_up 1\n"
    assert response.body =~ ~s(twelvgaige_resource_permits_active{resource_kind="llm_call")
  end

  test "creates, lists, shows, and replays round events and audit", %{breech: breech} do
    body =
      Jason.encode!(%{
        workflow: @workflow,
        input: %{"cluster" => "dev"},
        round_id: "round_api_1"
      })

    response = Router.dispatch("POST", "/api/v1/rounds", body, auth_opts(breech))

    assert response.status == 202
    assert %{"id" => "round_api_1", "status" => "queued"} = decode(response)

    assert eventually(fn ->
             response = Router.dispatch("GET", "/api/v1/rounds/round_api_1", "", server: breech)
             response.status == 200 and decode(response)["status"] == "complete"
           end)

    response = Router.dispatch("GET", "/api/v1/rounds?status=complete", "", server: breech)
    assert response.status == 200
    assert Enum.any?(decode(response), &(&1["id"] == "round_api_1"))

    response = Router.dispatch("GET", "/api/v1/rounds/round_api_1/events", "", server: breech)
    assert response.status == 200
    assert [%{"event_type" => "round_completed"}] = decode(response)

    response =
      Router.dispatch("GET", "/api/v1/rounds/round_api_1/events?format=ndjson", "",
        server: breech
      )

    assert response.status == 200
    assert {"content-type", "application/x-ndjson; charset=utf-8"} in response.headers
    assert {"x-twelvgaige-stream-mode", "bounded-replay"} in response.headers
    assert [%{"event_type" => "round_completed"}] = decode_ndjson(response)

    response =
      Router.dispatch("GET", "/api/v1/rounds/round_api_1/events?format=sse", "", server: breech)

    assert response.status == 200
    assert {"content-type", "text/event-stream; charset=utf-8"} in response.headers
    assert {"cache-control", "no-cache"} in response.headers
    assert {"x-twelvgaige-stream-mode", "bounded-replay"} in response.headers
    assert response.body =~ "event: round_completed\n"
    assert response.body =~ ~s("event_type":"round_completed")

    response =
      Router.dispatch("GET", "/api/v1/rounds/round_api_1/events?format=cloudevents", "",
        server: breech
      )

    assert response.status == 200

    assert {"content-type", "application/cloudevents-batch+json; charset=utf-8"} in response.headers

    assert [%{"specversion" => "1.0", "type" => "dev.twelvgaige.round.round_completed"}] =
             decode(response)

    response = Router.dispatch("GET", "/api/v1/audit/round_api_1", "", server: breech)
    assert response.status == 200
    event_types = response |> decode() |> Enum.map(& &1["event_type"])
    assert "shot_attempt_started" in event_types
    assert "round_state_transition" in event_types

    response =
      Router.dispatch("GET", "/api/v1/audit/round_api_1?format=ndjson", "", server: breech)

    assert response.status == 200
    audit_event_types = response |> decode_ndjson() |> Enum.map(& &1["event_type"])
    assert "shot_attempt_started" in audit_event_types

    response =
      Router.dispatch("GET", "/api/v1/audit/round_api_1?format=checkpoint", "", server: breech)

    assert response.status == 200
    checkpoint = decode(response)
    assert checkpoint["kind"] == "twelvgaige.audit.checkpoint"
    assert checkpoint["round_id"] == "round_api_1"
    assert :ok = Twelvgaige.Audit.Checkpoint.verify(checkpoint)
  end

  test "round API output redacts canary secrets", %{breech: breech} do
    body =
      Jason.encode!(%{
        workflow: @workflow,
        input: %{"token" => "canary-secret", "cluster" => "dev"},
        round_id: "round_api_canary"
      })

    assert %{status: 202} = Router.dispatch("POST", "/api/v1/rounds", body, auth_opts(breech))

    assert eventually(fn ->
             response =
               Router.dispatch("GET", "/api/v1/rounds/round_api_canary", "", server: breech)

             response.status == 200 and decode(response)["status"] == "complete"
           end)

    response = Router.dispatch("GET", "/api/v1/rounds/round_api_canary", "", server: breech)
    assert response.status == 200
    assert decode(response)["input"]["token"] == "[REDACTED]"
    refute response.body =~ "canary-secret"
  end

  test "event replay enforces a bounded response byte cap", %{breech: breech} do
    body =
      Jason.encode!(%{
        workflow: @workflow,
        input: %{"cluster" => "dev"},
        round_id: "round_api_stream_cap"
      })

    assert %{status: 202} = Router.dispatch("POST", "/api/v1/rounds", body, auth_opts(breech))

    assert eventually(fn ->
             response =
               Router.dispatch("GET", "/api/v1/rounds/round_api_stream_cap", "", server: breech)

             response.status == 200 and decode(response)["status"] == "complete"
           end)

    response =
      Router.dispatch("GET", "/api/v1/rounds/round_api_stream_cap/events?format=ndjson", "",
        server: breech,
        max_event_stream_bytes: 8
      )

    assert response.status == 413

    assert %{
             "reason" => "event_stream_too_large",
             "max_event_stream_bytes" => 8,
             "bytes" => bytes
           } = decode(response)

    assert bytes > 8
  end

  test "bounded follow waits for the next round event and returns sse heartbeats when idle", %{
    breech: breech
  } do
    body =
      Jason.encode!(%{
        workflow: @safety_workflow,
        input: %{"cluster" => "dev"},
        round_id: "round_api_follow"
      })

    assert %{status: 202} = Router.dispatch("POST", "/api/v1/rounds", body, auth_opts(breech))

    assert eventually(fn ->
             response =
               Router.dispatch("GET", "/api/v1/rounds/round_api_follow", "", server: breech)

             response.status == 200 and decode(response)["status"] == "awaiting_safety"
           end)

    assert response =
             Router.dispatch(
               "GET",
               "/api/v1/rounds/round_api_follow/events?after_seq=1&format=sse&follow=true&timeout_ms=1",
               "",
               server: breech
             )

    assert response.status == 200
    assert response.body == ": heartbeat\n\n"

    waiter =
      Task.async(fn ->
        Router.dispatch(
          "GET",
          "/api/v1/rounds/round_api_follow/events?after_seq=1&format=sse&follow=true&timeout_ms=1000",
          "",
          server: breech
        )
      end)

    approval_body = Jason.encode!(%{reason: "reviewed", actor: "human:test"})

    assert %{status: 202} =
             Router.dispatch(
               "POST",
               "/api/v1/rounds/round_api_follow/safety/approval/approve",
               approval_body,
               auth_opts(breech)
             )

    response = Task.await(waiter)
    assert response.status == 200
    assert response.body =~ "event: round_completed\n"
  end

  test "bounded follow can continue until the round is terminal", %{breech: breech} do
    body =
      Jason.encode!(%{
        workflow: @safety_workflow,
        input: %{"cluster" => "dev"},
        round_id: "round_api_until_terminal"
      })

    assert %{status: 202} = Router.dispatch("POST", "/api/v1/rounds", body, auth_opts(breech))

    assert eventually(fn ->
             response =
               Router.dispatch("GET", "/api/v1/rounds/round_api_until_terminal", "",
                 server: breech
               )

             response.status == 200 and decode(response)["status"] == "awaiting_safety"
           end)

    waiter =
      Task.async(fn ->
        Router.dispatch(
          "GET",
          "/api/v1/rounds/round_api_until_terminal/events?format=ndjson&follow=true&until_terminal=true&timeout_ms=1000",
          "",
          server: breech
        )
      end)

    Process.sleep(10)

    approval_body = Jason.encode!(%{reason: "reviewed", actor: "human:test"})

    assert %{status: 202} =
             Router.dispatch(
               "POST",
               "/api/v1/rounds/round_api_until_terminal/safety/approval/approve",
               approval_body,
               auth_opts(breech)
             )

    response = Task.await(waiter)
    assert response.status == 200

    assert ["round_awaiting_safety", "round_completed"] =
             response
             |> decode_ndjson()
             |> Enum.map(& &1["event_type"])
  end

  test "approves safety and cancels rounds through control endpoints", %{breech: breech} do
    body =
      Jason.encode!(%{
        workflow: @safety_workflow,
        input: %{"cluster" => "dev"},
        round_id: "round_api_safety"
      })

    assert %{status: 202} = Router.dispatch("POST", "/api/v1/rounds", body, auth_opts(breech))

    assert eventually(fn ->
             response =
               Router.dispatch("GET", "/api/v1/rounds/round_api_safety", "", server: breech)

             response.status == 200 and decode(response)["status"] == "awaiting_safety"
           end)

    approval_body = Jason.encode!(%{reason: "reviewed", actor: "human:test"})

    response =
      Router.dispatch(
        "POST",
        "/api/v1/rounds/round_api_safety/safety/approval/approve",
        approval_body,
        auth_opts(breech)
      )

    assert response.status == 202
    assert %{"decision" => "approve", "status" => "accepted"} = decode(response)

    assert eventually(fn ->
             response =
               Router.dispatch("GET", "/api/v1/rounds/round_api_safety", "", server: breech)

             response.status == 200 and decode(response)["status"] == "complete"
           end)

    cancel_body =
      Jason.encode!(%{
        workflow: @safety_workflow,
        input: %{"cluster" => "dev"},
        round_id: "round_api_cancel"
      })

    assert %{status: 202} =
             Router.dispatch("POST", "/api/v1/rounds", cancel_body, auth_opts(breech))

    assert eventually(fn ->
             response =
               Router.dispatch("GET", "/api/v1/rounds/round_api_cancel", "", server: breech)

             response.status == 200 and decode(response)["status"] == "awaiting_safety"
           end)

    response =
      Router.dispatch(
        "DELETE",
        "/api/v1/rounds/round_api_cancel",
        Jason.encode!(%{reason: "operator stop", actor: "human:test"}),
        auth_opts(breech)
      )

    assert response.status == 202
    assert %{"decision" => "cancel", "status" => "accepted"} = decode(response)
  end

  test "returns problem details for missing routes and oversized bodies", %{breech: breech} do
    response = Router.dispatch("GET", "/api/v1/rounds/missing", "", server: breech)
    assert response.status == 404
    assert {"content-type", "application/problem+json"} in response.headers

    response =
      Router.dispatch("POST", "/api/v1/rounds", "{}", auth_opts(breech, max_body_bytes: 1))

    assert response.status == 413
    assert %{"reason" => "request_body_too_large"} = decode(response)

    response =
      Router.dispatch("GET", "/api/v1/rounds/missing/events?format=xml", "", server: breech)

    assert response.status == 400

    assert %{"reason" => "bad_request", "detail" => "unsupported event replay format: xml"} =
             decode(response)
  end

  test "enforces optional bearer auth without accepting query tokens", %{breech: breech} do
    response =
      Router.dispatch("GET", "/api/v1/health", "", server: breech, bearer_token: "secret")

    assert response.status == 401
    assert {"www-authenticate", ~s(Bearer realm="twelvgaige")} in response.headers
    assert %{"reason" => "daemon_auth_failed"} = decode(response)

    response =
      Router.dispatch("GET", "/api/v1/health", "",
        server: breech,
        bearer_token: "secret",
        headers: [{"authorization", "Bearer wrong"}]
      )

    assert response.status == 401

    assert {"www-authenticate", ~s(Bearer realm="twelvgaige", error="invalid_token")} in response.headers

    response =
      Router.dispatch("GET", "/api/v1/health?access_token=secret", "",
        server: breech,
        bearer_token: "secret",
        headers: [{"authorization", "Bearer secret"}]
      )

    assert response.status == 400
    assert %{"reason" => "invalid_request"} = decode(response)

    response =
      Router.dispatch("GET", "/api/v1/health", "",
        server: breech,
        bearer_token: "secret",
        headers: [{"authorization", "Bearer secret"}]
      )

    assert response.status == 200
    assert %{"status" => "ok"} = decode(response)
  end

  test "requires bearer auth for mutating control routes even when no token is configured", %{
    breech: breech
  } do
    body =
      Jason.encode!(%{
        workflow: @workflow,
        input: %{},
        round_id: "round_api_auth_required"
      })

    response = Router.dispatch("POST", "/api/v1/rounds", body, server: breech)

    assert response.status == 401
    assert {"www-authenticate", ~s(Bearer realm="twelvgaige")} in response.headers
    assert %{"reason" => "daemon_auth_failed"} = decode(response)

    response =
      Router.dispatch(
        "DELETE",
        "/api/v1/rounds/round_api_auth_required",
        "",
        server: breech
      )

    assert response.status == 401

    response =
      Router.dispatch(
        "POST",
        "/api/v1/rounds/round_api_auth_required/safety/approval/approve",
        "",
        server: breech
      )

    assert response.status == 401
  end

  test "rejects approve_all_safety over HTTP unless explicitly enabled", %{breech: breech} do
    body =
      Jason.encode!(%{
        "approve_all_safety?" => true,
        workflow: @safety_workflow,
        input: %{},
        round_id: "round_api_inline_safety_denied"
      })

    response = Router.dispatch("POST", "/api/v1/rounds", body, auth_opts(breech))

    assert response.status == 403
    assert %{"reason" => "policy_denied"} = decode(response)

    response =
      Router.dispatch(
        "POST",
        "/api/v1/rounds",
        body,
        auth_opts(breech, allow_approve_all_safety?: true)
      )

    assert response.status == 202
  end

  test "emits rate-limit headers and retry hints", %{breech: breech} do
    response =
      Router.dispatch("GET", "/api/v1/health", "",
        server: breech,
        rate_limit: %{limit: 60, remaining: 59, reset: 30, policy: "60;w=60"}
      )

    assert response.status == 200
    assert {"RateLimit-Limit", "60"} in response.headers
    assert {"RateLimit-Remaining", "59"} in response.headers
    assert {"RateLimit-Reset", "30"} in response.headers
    assert {"RateLimit-Policy", "60;w=60"} in response.headers

    response =
      Router.dispatch("GET", "/api/v1/health", "",
        server: breech,
        rate_limit: %{limit: 60, remaining: 0, reset: 45, retry_after: 45, limited?: true}
      )

    assert response.status == 429
    assert {"RateLimit-Limit", "60"} in response.headers
    assert {"RateLimit-Remaining", "0"} in response.headers
    assert {"RateLimit-Reset", "45"} in response.headers
    assert {"Retry-After", "45"} in response.headers
    assert %{"reason" => "rate_limited", "detail" => "API rate limit exceeded"} = decode(response)
  end

  test "accepts signed webhook triggers and rejects replays", %{breech: breech} do
    replay_cache = start_supervised!({WebhookReplayCache, name: nil})
    body = Jason.encode!(%{"cluster" => "dev", "alert" => "pod_crash"})
    timestamp = 1_800_000_000
    nonce = "nonce-1"
    secret = "webhook-secret"

    headers = webhook_headers(secret, timestamp, nonce, body)

    response =
      Router.dispatch("POST", "/api/v1/webhooks/incidents", body,
        server: breech,
        now_unix: timestamp,
        webhook_replay_cache: replay_cache,
        headers: headers,
        webhooks: %{
          "incidents" => %{workflow: @workflow, secret: secret}
        }
      )

    assert response.status == 202

    assert %{"id" => round_id, "status" => "queued", "webhook_id" => "incidents"} =
             decode(response)

    assert eventually(fn ->
             response = Router.dispatch("GET", "/api/v1/rounds/#{round_id}", "", server: breech)
             decoded = decode(response)

             response.status == 200 and decoded["input"]["alert"] == "pod_crash" and
               decoded["status"] == "complete"
           end)

    replay =
      Router.dispatch("POST", "/api/v1/webhooks/incidents", body,
        server: breech,
        now_unix: timestamp,
        webhook_replay_cache: replay_cache,
        headers: headers,
        webhooks: %{
          "incidents" => %{workflow: @workflow, secret: secret}
        }
      )

    assert replay.status == 403
    assert %{"reason" => "policy_denied", "detail" => "webhook replay detected"} = decode(replay)
  end

  test "rejects invalid webhook signatures", %{breech: breech} do
    replay_cache = start_supervised!({WebhookReplayCache, name: nil})
    body = Jason.encode!(%{"cluster" => "dev"})
    timestamp = 1_800_000_000

    response =
      Router.dispatch("POST", "/api/v1/webhooks/incidents", body,
        server: breech,
        now_unix: timestamp,
        webhook_replay_cache: replay_cache,
        headers: [
          {"x-twelvgaige-timestamp", Integer.to_string(timestamp)},
          {"x-twelvgaige-nonce", "nonce-2"},
          {"x-twelvgaige-signature", "sha256=bad"}
        ],
        webhooks: %{
          "incidents" => %{workflow: @workflow, secret: "webhook-secret"}
        }
      )

    assert response.status == 403

    assert %{"reason" => "policy_denied", "detail" => "webhook signature verification failed"} =
             decode(response)
  end

  defp decode(response), do: Jason.decode!(response.body)

  defp auth_opts(breech, extra \\ []) do
    [
      server: breech,
      bearer_token: @auth_token,
      headers: [{"authorization", "Bearer #{@auth_token}"}]
    ] ++ extra
  end

  defp decode_ndjson(response) do
    response.body
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  defp eventually(fun), do: eventually(fun, 30)
  defp eventually(_fun, 0), do: false

  defp eventually(fun, attempts_left) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts_left - 1)
    end
  end

  defp webhook_headers(secret, timestamp, nonce, body) do
    signature =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{nonce}.#{body}")
      |> Base.encode16(case: :lower)

    [
      {"x-twelvgaige-timestamp", Integer.to_string(timestamp)},
      {"x-twelvgaige-nonce", nonce},
      {"x-twelvgaige-signature", "sha256=#{signature}"}
    ]
  end
end
