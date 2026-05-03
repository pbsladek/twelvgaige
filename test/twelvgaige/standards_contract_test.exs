defmodule Twelvgaige.StandardsContractTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.API.OpenAPI
  alias Twelvgaige.API.Router
  alias Twelvgaige.CLI.Main
  alias Twelvgaige.Round.Event
  alias Twelvgaige.Round.Snapshot
  alias Twelvgaige.Schema.ValueValidator
  alias Twelvgaige.Shell.Loader
  alias Twelvgaige.Shell.Schema
  alias Twelvgaige.Shot.State, as: ShotState

  @workflow_path "test/fixtures/shells/simple_workflow.yaml"
  @now ~U[2026-01-02 03:04:05.123456Z]

  test "CLI JSON outputs decode as RFC 8259 JSON values" do
    cases = [
      {["status", "--format", "json"], 0},
      {["shell", "validate", @workflow_path, "--format", "json"], 0},
      {["round", "show", "round_missing", "--format", "json"], 6}
    ]

    for {args, exit_code} <- cases do
      assert {:ok, output, ^exit_code} = Main.run(args)
      assert {:ok, decoded} = Jason.decode(output)
      assert is_map(decoded) or is_list(decoded)
    end
  end

  test "externally visible timestamp fields are RFC 3339 parseable" do
    snapshot =
      Snapshot.new(
        id: "round_contract",
        shell_id: "simple",
        shell_version: "1.0.0",
        status: :complete,
        started_at: @now,
        completed_at: DateTime.add(@now, 1, :second),
        shots: [
          ShotState.new(
            id: "first",
            kind: :agent,
            status: :complete,
            started_at: @now,
            completed_at: DateTime.add(@now, 250, :millisecond),
            next_retry_at: DateTime.add(@now, 10, :second)
          )
        ]
      )

    event =
      Event.new(
        id: "evt_contract",
        round_id: "round_contract",
        event_type: :round_completed,
        occurred_at: @now,
        payload: %{completed_at: @now}
      )

    audit =
      AuditEvent.to_map(%{
        id: "aud_contract",
        round_id: "round_contract",
        event_type: :tool_result,
        occurred_at: @now,
        payload: %{decided_at: @now}
      })

    assert_rfc3339_timestamps!(Snapshot.to_map(snapshot))
    assert_rfc3339_timestamps!(Event.to_map(event))
    assert_rfc3339_timestamps!(audit)
  end

  test "YAML shell fixtures load through the supported YAML contract" do
    for path <- Path.wildcard("test/fixtures/shells/*.yaml") do
      assert {:ok, _shell} = Loader.load(path)
    end
  end

  test "JSON shell fixtures load through the supported RFC 8259 shell contract" do
    for path <- Path.wildcard("test/fixtures/shells/*.json") do
      assert {:ok, _decoded} = path |> File.read!() |> Jason.decode()
      assert {:ok, _shell} = Loader.load(path)
    end
  end

  test "TOML shell fixtures load through the supported TOML 1.0 shell contract" do
    for path <- Path.wildcard("test/fixtures/shells/*.toml") do
      assert {:ok, _decoded} = path |> File.read!() |> TomlElixir.decode(spec: :"1.0.0")
      assert {:ok, _shell} = Loader.load(path)
    end
  end

  test "supported JSON Schema 2020-12 subset is accepted and unsupported keywords fail" do
    schema = %{
      "type" => "object",
      "required" => ["name"],
      "properties" => %{
        "name" => %{"type" => "string"},
        "tags" => %{"type" => "array", "items" => %{"type" => "string"}},
        "mode" => %{"enum" => ["read", "write"]}
      },
      "additionalProperties" => false
    }

    assert {:ok, %Schema{} = compiled} = Schema.from_map(schema)

    assert :ok =
             ValueValidator.validate(
               %{"name" => "cluster", "tags" => ["prod"], "mode" => "read"},
               compiled,
               error_class: :output_error,
               error_reason: :output_schema_violation
             )

    assert {:error, error} = Schema.from_map(Map.put(schema, "$ref", "#/$defs/example"))
    assert error.reason == :unsupported_schema_keyword
  end

  test "HTTP API follows problem details, bearer auth, rate-limit, and OpenAPI contracts" do
    not_found = Router.dispatch("GET", "/api/v1/not-found", "")

    assert not_found.status == 404
    assert {"content-type", "application/problem+json"} in not_found.headers

    assert %{
             "type" => "about:blank",
             "title" => "Not Found",
             "status" => 404,
             "reason" => "not_found",
             "detail" => "resource not found"
           } = Jason.decode!(not_found.body)

    missing_auth =
      Router.dispatch("GET", "/api/v1/health", "", bearer_token: "secret")

    assert missing_auth.status == 401
    assert {"www-authenticate", ~s(Bearer realm="twelvgaige")} in missing_auth.headers

    query_token =
      Router.dispatch("GET", "/api/v1/health?access_token=secret", "",
        bearer_token: "secret",
        headers: [{"authorization", "Bearer secret"}]
      )

    assert query_token.status == 400

    assert {"www-authenticate", ~s(Bearer realm="twelvgaige", error="invalid_request")} in query_token.headers

    limited =
      Router.dispatch("GET", "/api/v1/health", "",
        rate_limit: %{
          limit: 60,
          remaining: 0,
          reset: 45,
          retry_after: 30,
          policy: "60;w=60",
          limited?: true
        }
      )

    assert limited.status == 429
    assert {"RateLimit-Limit", "60"} in limited.headers
    assert {"RateLimit-Remaining", "0"} in limited.headers
    assert {"RateLimit-Reset", "45"} in limited.headers
    assert {"RateLimit-Policy", "60;w=60"} in limited.headers
    assert {"Retry-After", "30"} in limited.headers

    spec = OpenAPI.spec()

    assert spec["openapi"] == "3.1.0"
    assert spec["jsonSchemaDialect"] == "https://json-schema.org/draft/2020-12/schema"
    assert get_in(spec, ["components", "securitySchemes", "bearerAuth", "scheme"]) == "bearer"

    assert get_in(spec, ["components", "schemas", "ProblemDetails", "required"]) == [
             "type",
             "title",
             "status",
             "reason",
             "detail"
           ]
  end

  defp assert_rfc3339_timestamps!(value) do
    assert [] = collect_bad_timestamps(value)
  end

  defp collect_bad_timestamps(%{} = map) do
    Enum.flat_map(map, fn
      {key, value} when is_binary(key) ->
        key_errors(key, value) ++ collect_bad_timestamps(value)

      {_key, value} ->
        collect_bad_timestamps(value)
    end)
  end

  defp collect_bad_timestamps(values) when is_list(values) do
    Enum.flat_map(values, &collect_bad_timestamps/1)
  end

  defp collect_bad_timestamps(_value), do: []

  defp key_errors(key, value) when is_binary(value) do
    if String.ends_with?(key, "_at") and invalid_rfc3339?(value) do
      [{key, value}]
    else
      []
    end
  end

  defp key_errors(_key, _value), do: []

  defp invalid_rfc3339?(value) do
    case DateTime.from_iso8601(value) do
      {:ok, _datetime, 0} -> false
      _other -> true
    end
  end
end
