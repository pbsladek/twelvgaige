defmodule Twelvgaige.API.Router do
  @moduledoc """
  Pure HTTP API router for the local control plane.

  The router intentionally has no socket dependency. It accepts a method, target
  path, request body, and options, then returns a response struct. This keeps
  API semantics testable while a concrete listener is added later.
  """

  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.API.EventStream
  alias Twelvgaige.API.OpenAPI
  alias Twelvgaige.API.Response
  alias Twelvgaige.API.Webhook
  alias Twelvgaige.Breech
  alias Twelvgaige.Error
  alias Twelvgaige.Metrics.Prometheus
  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Round.Watch
  alias Twelvgaige.Security

  @default_max_body_bytes 4 * 1024 * 1024
  @default_max_event_stream_bytes 1 * 1024 * 1024

  @type method :: String.t() | atom()

  @spec dispatch(method(), String.t(), iodata(), keyword()) :: Response.t()
  def dispatch(method, target, body \\ "", opts \\ [])
      when is_binary(target) and is_list(opts) do
    method = normalize_method(method)
    uri = URI.parse(target)
    path = uri.path || "/"
    query = URI.decode_query(uri.query || "")
    segments = path_segments(path)

    case authenticate(method, segments, query, opts) do
      :ok ->
        case rate_limit_decision(opts) do
          :ok ->
            case route(method, segments, query, IO.iodata_to_binary(body), opts) do
              %Response{} = response -> standard_headers(response, opts)
              {:ok, status, payload} -> status |> json(payload) |> standard_headers(opts)
              {:error, reason} -> reason |> error_response() |> standard_headers(opts)
            end

          {:limited, rate_limit} ->
            rate_limit_error_response(rate_limit)
        end

      {:error, reason} ->
        auth_error_response(reason)
    end
  rescue
    error ->
      error_response({:internal_error, Exception.message(error)})
  end

  defp route("GET", ["api", "v1", "health"], _query, _body, opts) do
    server = server(opts)

    case Breech.status(server) do
      {:ok, status} -> {:ok, 200, %{status: "ok", breech: status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp route("GET", ["api", "v1", "openapi.json"], _query, _body, _opts) do
    %Response{status: 200, body: OpenAPI.json()}
  end

  defp route("GET", ["api", "v1", "metrics"], _query, _body, opts) do
    case Prometheus.snapshot(server: server(opts)) do
      {:ok, body} ->
        %Response{
          status: 200,
          headers: [{"content-type", "text/plain; version=0.0.4; charset=utf-8"}],
          body: body
        }

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp route("GET", ["api", "v1", "rounds"], query, _body, opts) do
    list_opts =
      [server: server(opts)]
      |> maybe_put(:status, Map.get(query, "status"))

    case Breech.list_rounds(list_opts) do
      {:ok, rounds} -> {:ok, 200, Enum.map(rounds, &Snapshot.to_map/1)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp route("POST", ["api", "v1", "rounds"], _query, body, opts) do
    with {:ok, payload} <- decode_json_body(body, opts),
         {:ok, workflow} <- workflow_payload(payload),
         input when is_map(input) <- Map.get(payload, "input", %{}),
         {:ok, round_opts} <- round_opts(payload, opts),
         {:ok, round_id} <- Breech.start_round(workflow, input, round_opts) do
      {:ok, 202, %{id: round_id, status: "queued"}}
    else
      {:error, reason} -> {:error, reason}
      _invalid -> {:error, {:bad_request, "round input must be an object"}}
    end
  end

  defp route("POST", ["api", "v1", "webhooks", webhook_id], _query, body, opts) do
    webhook_body_opts =
      Keyword.put(opts, :max_body_bytes, Keyword.get(opts, :webhook_max_body_bytes, 1024 * 1024))

    with {:ok, config} <- Webhook.fetch_config(webhook_id, opts),
         {:ok, payload} <- decode_json_body(body, webhook_body_opts),
         :ok <- Webhook.verify(webhook_id, config, body, opts),
         {:ok, workflow} <- webhook_workflow(config),
         input when is_map(input) <- Webhook.round_input(payload, config),
         {:ok, round_id} <- Breech.start_round(workflow, input, Webhook.round_opts(config, opts)) do
      {:ok, 202, %{id: round_id, status: "queued", webhook_id: webhook_id}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp route("GET", ["api", "v1", "rounds", round_id], _query, _body, opts) do
    case Breech.get_round(round_id, server: server(opts)) do
      {:ok, snapshot} -> {:ok, 200, Snapshot.to_map(snapshot)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp route("DELETE", ["api", "v1", "rounds", round_id], _query, body, opts) do
    with {:ok, payload} <- decode_optional_json_body(body, opts) do
      cancel_opts =
        [server: server(opts)]
        |> maybe_put(:reason, Map.get(payload, "reason"))
        |> maybe_put(:actor, Map.get(payload, "actor"))

      case Breech.cancel_round(round_id, cancel_opts) do
        :ok -> {:ok, 202, %{status: "accepted", decision: "cancel", round_id: round_id}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp route(
         "POST",
         ["api", "v1", "rounds", round_id, "safety", shot_id, "approve"],
         _query,
         body,
         opts
       ) do
    safety_decision(:approve, round_id, shot_id, body, opts)
  end

  defp route(
         "POST",
         ["api", "v1", "rounds", round_id, "safety", shot_id, "reject"],
         _query,
         body,
         opts
       ) do
    safety_decision(:reject, round_id, shot_id, body, opts)
  end

  defp route("GET", ["api", "v1", "rounds", round_id, "events"], query, _body, opts) do
    with {:ok, format} <- event_replay_format(query) do
      event_opts =
        []
        |> maybe_put(:after_seq, parse_non_negative_integer(Map.get(query, "after_seq")))
        |> maybe_put(:limit, parse_positive_integer(Map.get(query, "limit")))
        |> maybe_put(:timeout_ms, parse_non_negative_integer(Map.get(query, "timeout_ms")))
        |> Keyword.put(:source, Breech)
        |> Keyword.put(:source_opts, server: server(opts))
        |> Keyword.put(:follow?, follow?(query))
        |> Keyword.put(:until_terminal?, until_terminal?(query))

      case Watch.collect(round_id, event_opts) do
        {:ok, events} ->
          event_replay_response(format, Enum.map(events, &Event.to_map/1), :round, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp route("GET", ["api", "v1", "audit", round_id], query, _body, opts) do
    with {:ok, format} <- event_replay_format(query) do
      audit_opts =
        [server: server(opts)]
        |> maybe_put(:after_seq, parse_non_negative_integer(Map.get(query, "after_seq")))
        |> maybe_put(:limit, parse_positive_integer(Map.get(query, "limit")))

      case Breech.list_audit_events(round_id, audit_opts) do
        {:ok, events} ->
          event_replay_response(format, Enum.map(events, &AuditEvent.to_map/1), :audit, opts)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp route(_method, _segments, _query, _body, _opts), do: {:error, :not_found}

  defp safety_decision(decision, round_id, shot_id, body, opts) do
    with {:ok, payload} <- decode_optional_json_body(body, opts) do
      decision_opts =
        [server: server(opts)]
        |> maybe_put(:reason, Map.get(payload, "reason"))
        |> maybe_put(:actor, Map.get(payload, "actor"))

      result =
        case decision do
          :approve -> Breech.approve_safety(round_id, shot_id, decision_opts)
          :reject -> Breech.reject_safety(round_id, shot_id, decision_opts)
        end

      case result do
        :ok ->
          {:ok, 202,
           %{
             status: "accepted",
             decision: Atom.to_string(decision),
             round_id: round_id,
             shot_id: shot_id
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp event_replay_format(query) do
    case Map.get(query, "format", "json") do
      "json" -> {:ok, :json}
      "ndjson" -> {:ok, :ndjson}
      "sse" -> {:ok, :sse}
      "cloudevents" -> {:ok, :cloudevents}
      "checkpoint" -> {:ok, :checkpoint}
      other -> {:error, {:bad_request, "unsupported event replay format: #{other}"}}
    end
  end

  defp event_replay_response(:json, events, _kind, opts) do
    bounded_event_response(Jason.encode!(events), [], opts)
  end

  defp event_replay_response(:ndjson, events, _kind, opts) do
    bounded_event_response(
      EventStream.ndjson(events),
      [{"content-type", EventStream.ndjson_content_type()}],
      opts
    )
  end

  defp event_replay_response(:sse, [], _kind, opts) do
    bounded_event_response(
      EventStream.heartbeat(),
      [
        {"content-type", EventStream.sse_content_type()},
        {"cache-control", "no-cache"}
      ],
      opts
    )
  end

  defp event_replay_response(:sse, events, _kind, opts) do
    bounded_event_response(
      EventStream.sse(events),
      [
        {"content-type", EventStream.sse_content_type()},
        {"cache-control", "no-cache"}
      ],
      opts
    )
  end

  defp event_replay_response(:cloudevents, events, kind, opts) do
    bounded_event_response(
      Jason.encode!(EventStream.cloud_events(events, kind: kind)),
      [{"content-type", EventStream.cloud_events_content_type()}],
      opts
    )
  end

  defp event_replay_response(:checkpoint, events, kind, opts) do
    bounded_event_response(
      events
      |> Twelvgaige.Audit.Checkpoint.export(scope: kind)
      |> Jason.encode!(),
      [{"content-type", "application/json; profile=\"twelvgaige.audit.checkpoint\""}],
      opts
    )
  end

  defp bounded_event_response(body, headers, opts) do
    max_bytes = Keyword.get(opts, :max_event_stream_bytes, @default_max_event_stream_bytes)

    if byte_size(body) <= max_bytes do
      %Response{
        status: 200,
        headers:
          headers ++
            [
              {"x-twelvgaige-stream-mode", "bounded-replay"},
              {"x-twelvgaige-stream-max-bytes", Integer.to_string(max_bytes)}
            ],
        body: body
      }
    else
      problem(
        413,
        "Payload Too Large",
        "event_stream_too_large",
        "event stream response exceeds configured byte limit",
        bytes: byte_size(body),
        max_event_stream_bytes: max_bytes
      )
    end
  end

  defp workflow_payload(%{"workflow" => workflow}) when is_map(workflow), do: {:ok, workflow}
  defp workflow_payload(%{"workflow_path" => path}) when is_binary(path), do: {:ok, path}

  defp workflow_payload(_payload),
    do: {:error, {:bad_request, "workflow or workflow_path is required"}}

  defp webhook_workflow(config) do
    case Webhook.workflow(config) do
      nil -> {:error, {:bad_request, "webhook workflow is required"}}
      workflow -> {:ok, workflow}
    end
  end

  defp authenticate(method, segments, query, opts) do
    token = Keyword.get(opts, :bearer_token, Keyword.get(opts, :auth_token))

    cond do
      Map.has_key?(query, "access_token") ->
        {:error, :query_token_denied}

      is_nil(token) and mutating_control_route?(method, segments, opts) ->
        {:error, :auth_missing}

      is_nil(token) ->
        :ok

      true ->
        verify_bearer_token(Keyword.get(opts, :headers, []), token)
    end
  end

  defp verify_bearer_token(headers, expected_token) do
    case authorization_values(headers) do
      [] ->
        {:error, :auth_missing}

      ["Bearer " <> token] ->
        if secure_equal?(token, expected_token), do: :ok, else: {:error, :auth_invalid}

      [_other] ->
        {:error, :auth_invalid}

      _multiple ->
        {:error, :auth_invalid}
    end
  end

  defp authorization_values(headers) when is_map(headers) do
    headers
    |> Enum.filter(fn {key, _value} -> header_name(key) == "authorization" end)
    |> Enum.map(fn {_key, value} -> to_string(value) end)
  end

  defp authorization_values(headers) when is_list(headers) do
    headers
    |> Enum.filter(fn
      {key, _value} -> header_name(key) == "authorization"
      _other -> false
    end)
    |> Enum.map(fn {_key, value} -> to_string(value) end)
  end

  defp authorization_values(_headers), do: []

  defp secure_equal?(left, right) when is_binary(left) and is_binary(right) do
    Security.secure_equal?(left, right)
  end

  defp secure_equal?(_left, _right), do: false

  defp mutating_control_route?(_method, ["api", "v1", "webhooks" | _rest], _opts), do: false
  defp mutating_control_route?("GET", _segments, _opts), do: false
  defp mutating_control_route?("HEAD", _segments, _opts), do: false
  defp mutating_control_route?("OPTIONS", _segments, _opts), do: false

  defp mutating_control_route?(_method, ["api", "v1" | _rest], opts) do
    not Keyword.get(opts, :allow_unauthenticated_mutation?, false)
  end

  defp mutating_control_route?(_method, _segments, _opts), do: false

  defp header_name(name) when is_atom(name), do: name |> Atom.to_string() |> String.downcase()
  defp header_name(name), do: name |> to_string() |> String.downcase()

  defp rate_limit_decision(opts) do
    case normalize_rate_limit(opts) do
      nil ->
        :ok

      %{limited?: true} = rate_limit ->
        {:limited, rate_limit}

      _rate_limit ->
        :ok
    end
  end

  defp normalize_rate_limit(opts) do
    opts
    |> Keyword.get(:rate_limit, Keyword.get(opts, :api_rate_limit))
    |> case do
      nil -> nil
      value when is_list(value) -> value |> Map.new() |> normalize_rate_limit_map()
      value when is_map(value) -> normalize_rate_limit_map(value)
      _value -> nil
    end
  end

  defp normalize_rate_limit_map(rate_limit) do
    %{
      limit: rate_limit_value(rate_limit, :limit),
      remaining: rate_limit_value(rate_limit, :remaining),
      reset: rate_limit_value(rate_limit, :reset),
      retry_after: rate_limit_value(rate_limit, :retry_after),
      policy: rate_limit_value(rate_limit, :policy),
      limited?:
        truthy?(rate_limit_value(rate_limit, :limited?)) or
          truthy?(rate_limit_value(rate_limit, :limited))
    }
  end

  defp rate_limit_value(rate_limit, key) do
    Map.get(rate_limit, key, Map.get(rate_limit, Atom.to_string(key)))
  end

  defp truthy?(value), do: value in [true, "true", 1, "1"]

  defp follow?(query), do: truthy?(Map.get(query, "follow"))
  defp until_terminal?(query), do: truthy?(Map.get(query, "until_terminal"))

  defp round_opts(payload, opts) do
    with :ok <- ensure_approve_all_safety_allowed(payload, opts) do
      {:ok,
       [server: server(opts)]
       |> maybe_put(:round_id, Map.get(payload, "round_id"))
       |> maybe_put(:approve_all_safety?, Map.get(payload, "approve_all_safety?"))}
    end
  end

  defp ensure_approve_all_safety_allowed(%{"approve_all_safety?" => true}, opts) do
    if Keyword.get(opts, :allow_approve_all_safety?, false) do
      :ok
    else
      {:error,
       Twelvgaige.Error.new(
         :policy_error,
         :policy_denied,
         "approve_all_safety? is not accepted over the HTTP control plane",
         safety_required: true,
         details: %{required: "allow_approve_all_safety?"}
       )}
    end
  end

  defp ensure_approve_all_safety_allowed(_payload, _opts), do: :ok

  defp decode_optional_json_body("", _opts), do: {:ok, %{}}
  defp decode_optional_json_body(body, opts), do: decode_json_body(body, opts)

  defp decode_json_body(body, opts) do
    max_body_bytes = Keyword.get(opts, :max_body_bytes, @default_max_body_bytes)

    cond do
      byte_size(body) > max_body_bytes ->
        {:error, :request_body_too_large}

      body == "" ->
        {:error, {:bad_request, "request body is required"}}

      true ->
        case Jason.decode(body) do
          {:ok, payload} when is_map(payload) -> {:ok, payload}
          {:ok, _other} -> {:error, {:bad_request, "request body must be a JSON object"}}
          {:error, error} -> {:error, {:bad_request, Exception.message(error)}}
        end
    end
  end

  defp json(status, payload) do
    %Response{status: status, body: Jason.encode!(payload)}
  end

  defp error_response(:not_found) do
    problem(404, "Not Found", "not_found", "resource not found")
  end

  defp error_response(:request_body_too_large) do
    problem(413, "Payload Too Large", "request_body_too_large", "request body is too large")
  end

  defp error_response(:daemon_unavailable) do
    problem(503, "Service Unavailable", "daemon_unavailable", "Breech daemon is unavailable")
  end

  defp error_response({:bad_request, detail}) do
    problem(400, "Bad Request", "bad_request", detail)
  end

  defp error_response({:internal_error, detail}) do
    problem(500, "Internal Server Error", "internal_error", detail)
  end

  defp error_response(%Error{} = error) do
    status =
      case error.class do
        :input_error -> 400
        :policy_error -> 403
        :store_error -> 503
        _other -> 500
      end

    problem(status, error.class |> Atom.to_string() |> titleize(), error.reason, error.message,
      error: Error.to_map(error)
    )
  end

  defp error_response(reason),
    do: problem(500, "Internal Server Error", "unknown", inspect(reason))

  defp rate_limit_error_response(rate_limit) do
    %{
      retry_after: retry_after,
      reset: reset
    } = rate_limit

    retry_after = retry_after || reset

    problem(
      429,
      "Too Many Requests",
      "rate_limited",
      "API rate limit exceeded",
      [],
      rate_limit_headers(rate_limit) ++ retry_after_headers(retry_after)
    )
  end

  defp auth_error_response(:query_token_denied) do
    problem(
      400,
      "Bad Request",
      "invalid_request",
      "bearer tokens are not accepted in query strings",
      [],
      [{"www-authenticate", ~s(Bearer realm="twelvgaige", error="invalid_request")}]
    )
  end

  defp auth_error_response(:auth_missing) do
    problem(
      401,
      "Unauthorized",
      "daemon_auth_failed",
      "bearer token is required",
      [],
      [{"www-authenticate", ~s(Bearer realm="twelvgaige")}]
    )
  end

  defp auth_error_response(:auth_invalid) do
    problem(
      401,
      "Unauthorized",
      "daemon_auth_failed",
      "bearer token is invalid",
      [],
      [{"www-authenticate", ~s(Bearer realm="twelvgaige", error="invalid_token")}]
    )
  end

  defp problem(status, title, reason, detail, extra \\ []) do
    problem(status, title, reason, detail, extra, [])
  end

  defp problem(status, title, reason, detail, extra, headers) do
    body =
      %{
        type: "about:blank",
        title: title,
        status: status,
        reason: stringify(reason),
        detail: detail
      }
      |> Map.merge(Map.new(extra))

    %Response{
      status: status,
      headers: [{"content-type", "application/problem+json"} | headers],
      body: Jason.encode!(body)
    }
  end

  defp standard_headers(%Response{} = response, opts) do
    headers =
      opts
      |> normalize_rate_limit()
      |> rate_limit_headers()

    %{response | headers: response.headers ++ headers}
  end

  defp rate_limit_headers(nil), do: []

  defp rate_limit_headers(%{} = rate_limit) do
    []
    |> maybe_header("RateLimit-Limit", rate_limit.limit)
    |> maybe_header("RateLimit-Remaining", rate_limit.remaining)
    |> maybe_header("RateLimit-Reset", rate_limit.reset)
    |> maybe_header("RateLimit-Policy", rate_limit.policy)
  end

  defp retry_after_headers(nil), do: []
  defp retry_after_headers(value), do: [{"Retry-After", to_header_value(value)}]

  defp maybe_header(headers, _name, nil), do: headers
  defp maybe_header(headers, name, value), do: headers ++ [{name, to_header_value(value)}]

  defp to_header_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_header_value(value), do: to_string(value)

  defp path_segments(path), do: String.split(path, "/", trim: true)

  defp normalize_method(method) when is_atom(method),
    do: method |> Atom.to_string() |> String.upcase()

  defp normalize_method(method) when is_binary(method), do: String.upcase(method)

  defp server(opts), do: Keyword.get(opts, :server, Breech)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp parse_non_negative_integer(nil), do: nil
  defp parse_non_negative_integer(value) when is_integer(value) and value >= 0, do: value

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> integer
      _other -> nil
    end
  end

  defp parse_non_negative_integer(_value), do: nil

  defp parse_positive_integer(nil), do: nil
  defp parse_positive_integer(value) when is_integer(value) and value > 0, do: value

  defp parse_positive_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> nil
    end
  end

  defp parse_positive_integer(_value), do: nil

  defp titleize(value) do
    value
    |> String.replace("_", " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp stringify(value) when is_atom(value), do: Atom.to_string(value)
  defp stringify(value), do: to_string(value)
end
