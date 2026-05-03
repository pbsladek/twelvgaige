defmodule Twelvgaige.API.OpenAPITest do
  use ExUnit.Case, async: true

  alias Twelvgaige.API.OpenAPI
  alias Twelvgaige.API.Router

  test "declares the implemented HTTP API as OpenAPI 3.1" do
    spec = OpenAPI.spec()

    assert spec["openapi"] == "3.1.0"
    assert spec["jsonSchemaDialect"] == "https://json-schema.org/draft/2020-12/schema"
    assert spec["info"]["title"] == "Twelvgaige Local Control API"
    assert spec["security"] == [%{"bearerAuth" => []}]
    assert get_in(spec, ["components", "securitySchemes", "bearerAuth", "scheme"]) == "bearer"

    paths = spec["paths"]

    for path <- [
          "/api/v1/openapi.json",
          "/api/v1/health",
          "/api/v1/metrics",
          "/api/v1/rounds",
          "/api/v1/rounds/{round_id}",
          "/api/v1/rounds/{round_id}/safety/{shot_id}/approve",
          "/api/v1/rounds/{round_id}/safety/{shot_id}/reject",
          "/api/v1/webhooks/{webhook_id}",
          "/api/v1/rounds/{round_id}/events",
          "/api/v1/audit/{round_id}"
        ] do
      assert Map.has_key?(paths, path)
    end

    assert get_in(paths, ["/api/v1/rounds", "post", "requestBody", "required"]) == true

    assert get_in(paths, [
             "/api/v1/rounds/{round_id}",
             "delete",
             "requestBody",
             "required"
           ]) == false

    event_content =
      get_in(paths, ["/api/v1/rounds/{round_id}/events", "get", "responses", "200", "content"])

    assert Map.has_key?(event_content, "application/json")
    assert Map.has_key?(event_content, "application/x-ndjson")
    assert Map.has_key?(event_content, "text/event-stream")
    assert Map.has_key?(event_content, "application/cloudevents-batch+json")

    event_response = get_in(paths, ["/api/v1/rounds/{round_id}/events", "get", "responses"])
    assert Map.has_key?(event_response, "413")

    assert get_in(event_response, [
             "200",
             "headers",
             "x-twelvgaige-stream-mode",
             "schema",
             "enum"
           ]) == ["bounded-replay", "chunked-push"]

    event_parameters = get_in(paths, ["/api/v1/rounds/{round_id}/events", "get", "parameters"])
    assert Enum.any?(event_parameters, &(&1["name"] == "format"))
    assert Enum.any?(event_parameters, &(&1["name"] == "follow"))
    assert Enum.any?(event_parameters, &(&1["name"] == "stream"))
    assert Enum.any?(event_parameters, &(&1["name"] == "until_terminal"))
    assert Enum.any?(event_parameters, &(&1["name"] == "timeout_ms"))

    format_parameter = Enum.find(event_parameters, &(&1["name"] == "format"))
    assert "sse" in format_parameter["schema"]["enum"]
    assert "cloudevents" in format_parameter["schema"]["enum"]

    cloud_event = get_in(spec, ["components", "schemas", "CloudEvent"])
    assert cloud_event["required"] == ["specversion", "id", "source", "type", "data"]

    rate_limit_response = get_in(paths, ["/api/v1/health", "get", "responses", "429"])

    assert get_in(rate_limit_response, ["headers", "RateLimit-Limit", "schema", "type"]) ==
             "integer"

    assert get_in(rate_limit_response, ["headers", "Retry-After", "schema", "minimum"]) == 0

    webhook_post = get_in(paths, ["/api/v1/webhooks/{webhook_id}", "post"])
    assert webhook_post["tags"] == ["webhooks"]

    assert get_in(webhook_post, [
             "responses",
             "202",
             "content",
             "application/json",
             "schema",
             "$ref"
           ]) == "#/components/schemas/WebhookTriggerResponse"
  end

  test "operation ids are unique" do
    operation_ids =
      OpenAPI.spec()
      |> Map.fetch!("paths")
      |> Enum.flat_map(fn {_path, methods} ->
        methods
        |> Map.values()
        |> Enum.map(& &1["operationId"])
      end)

    assert Enum.all?(operation_ids, &is_binary/1)
    assert Enum.uniq(operation_ids) == operation_ids
  end

  test "problem details schema documents router error shape" do
    problem =
      OpenAPI.spec()
      |> get_in(["components", "schemas", "ProblemDetails"])

    assert problem["required"] == ["type", "title", "status", "reason", "detail"]
    assert problem["properties"]["status"]["minimum"] == 100
    assert problem["properties"]["status"]["maximum"] == 599
  end

  test "router serves the contract as json" do
    response = Router.dispatch("GET", "/api/v1/openapi.json")

    assert response.status == 200
    assert {"content-type", "application/json"} in response.headers
    assert Jason.decode!(response.body)["openapi"] == "3.1.0"
  end
end
