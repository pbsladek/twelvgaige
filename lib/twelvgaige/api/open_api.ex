defmodule Twelvgaige.API.OpenAPI do
  @moduledoc """
  OpenAPI 3.1 contract for the transport-neutral control API.

  This module is intentionally static and dependency-free. It documents the API
  behavior implemented by `Twelvgaige.API.Router`; concrete socket/listener
  adapters should serve this contract unchanged.
  """

  @spec json() :: String.t()
  def json, do: Jason.encode!(spec())

  @spec spec() :: map()
  def spec do
    %{
      "openapi" => "3.1.0",
      "jsonSchemaDialect" => "https://json-schema.org/draft/2020-12/schema",
      "info" => %{
        "title" => "Twelvgaige Local Control API",
        "version" => Twelvgaige.version(),
        "description" =>
          "Local-first API for running, inspecting, controlling, and auditing Twelvgaige rounds."
      },
      "servers" => [
        %{
          "url" => "http://127.0.0.1:{port}",
          "description" => "Local loopback listener when an HTTP transport adapter is enabled.",
          "variables" => %{"port" => %{"default" => "7443"}}
        }
      ],
      "tags" => [
        %{"name" => "system", "description" => "Daemon health, metrics, and API metadata."},
        %{"name" => "rounds", "description" => "Round lifecycle and control operations."},
        %{"name" => "webhooks", "description" => "Opt-in signed workflow triggers."},
        %{"name" => "audit", "description" => "Durable audit replay."}
      ],
      "security" => [%{"bearerAuth" => []}],
      "paths" => paths(),
      "components" => components()
    }
  end

  defp paths do
    %{
      "/api/v1/openapi.json" => %{
        "get" =>
          operation("getOpenApi", "system", "Return the OpenAPI 3.1 contract.",
            responses: %{
              "200" => json_response("OpenAPI contract.", "OpenAPIContract")
            }
          )
      },
      "/api/v1/health" => %{
        "get" =>
          operation("getHealth", "system", "Return local daemon health.",
            responses: %{
              "200" => json_response("Daemon is reachable.", "HealthResponse"),
              "503" => problem_response("Daemon is unavailable.")
            }
          )
      },
      "/api/v1/metrics" => %{
        "get" =>
          operation("getMetrics", "system", "Return Prometheus text exposition.",
            responses: %{
              "200" => %{
                "description" => "Prometheus text exposition.",
                "content" => %{
                  "text/plain; version=0.0.4; charset=utf-8" => %{
                    "schema" => %{"type" => "string"}
                  }
                }
              },
              "503" => problem_response("Daemon is unavailable.")
            }
          )
      },
      "/api/v1/rounds" => %{
        "get" =>
          operation("listRounds", "rounds", "List known rounds.",
            parameters: [status_query()],
            responses: %{
              "200" =>
                json_response("Round snapshots.", %{
                  "type" => "array",
                  "items" => ref("RoundSnapshot")
                }),
              "503" => problem_response("Store or daemon is unavailable.")
            }
          ),
        "post" =>
          operation(
            "createRound",
            "rounds",
            "Start a round from a workflow map or workflow path.",
            request_body: request_body("RoundCreateRequest"),
            responses: %{
              "202" => json_response("Round accepted.", "RoundCreateResponse"),
              "400" => problem_response("Request body is invalid."),
              "413" => problem_response("Request body exceeds the configured limit."),
              "503" => problem_response("Store or daemon is unavailable.")
            }
          )
      },
      "/api/v1/rounds/{round_id}" => %{
        "get" =>
          operation("getRound", "rounds", "Return a round snapshot.",
            parameters: [round_id_path()],
            responses: %{
              "200" => json_response("Round snapshot.", "RoundSnapshot"),
              "404" => problem_response("Round was not found."),
              "503" => problem_response("Store or daemon is unavailable.")
            }
          ),
        "delete" =>
          operation("cancelRound", "rounds", "Cancel an active or paused round.",
            parameters: [round_id_path()],
            request_body: optional_request_body("ControlReasonRequest"),
            responses: %{
              "202" => json_response("Cancellation accepted.", "ControlDecisionResponse"),
              "400" => problem_response("Request body is invalid."),
              "404" => problem_response("Round was not found."),
              "503" => problem_response("Store or daemon is unavailable.")
            }
          )
      },
      "/api/v1/rounds/{round_id}/safety/{shot_id}/approve" => %{
        "post" =>
          operation("approveSafetyShot", "rounds", "Approve a paused safety shot.",
            parameters: [round_id_path(), shot_id_path()],
            request_body: optional_request_body("ControlReasonRequest"),
            responses: safety_responses("Approval accepted.")
          )
      },
      "/api/v1/rounds/{round_id}/safety/{shot_id}/reject" => %{
        "post" =>
          operation("rejectSafetyShot", "rounds", "Reject a paused safety shot.",
            parameters: [round_id_path(), shot_id_path()],
            request_body: optional_request_body("ControlReasonRequest"),
            responses: safety_responses("Rejection accepted.")
          )
      },
      "/api/v1/webhooks/{webhook_id}" => %{
        "post" =>
          operation("triggerWebhook", "webhooks", "Trigger a configured workflow webhook.",
            parameters: [webhook_id_path()],
            request_body: request_body("WebhookTriggerRequest"),
            responses: %{
              "202" => json_response("Webhook accepted.", "WebhookTriggerResponse"),
              "400" => problem_response("Webhook request is invalid."),
              "403" => problem_response("Webhook signature or replay policy denied the request."),
              "404" => problem_response("Webhook endpoint was not configured."),
              "413" => problem_response("Webhook body exceeds the configured limit."),
              "503" => problem_response("Store or daemon is unavailable.")
            }
          )
      },
      "/api/v1/rounds/{round_id}/events" => %{
        "get" =>
          operation("listRoundEvents", "rounds", "Replay durable round events.",
            parameters: [
              round_id_path(),
              after_seq_query(),
              limit_query(),
              format_query(),
              follow_query(),
              stream_query(),
              until_terminal_query(),
              timeout_ms_query()
            ],
            responses: %{
              "200" => event_replay_response("Round events.", "RoundEvent"),
              "400" => problem_response("Requested replay format is invalid."),
              "404" => problem_response("Round was not found."),
              "413" =>
                problem_response("Encoded event replay body exceeds the configured limit."),
              "503" => problem_response("Store or daemon is unavailable.")
            }
          )
      },
      "/api/v1/audit/{round_id}" => %{
        "get" =>
          operation("listAuditEvents", "audit", "Replay durable audit events for a round.",
            parameters: [round_id_path(), after_seq_query(), limit_query(), format_query()],
            responses: %{
              "200" => event_replay_response("Audit events.", "AuditEvent"),
              "400" => problem_response("Requested replay format is invalid."),
              "404" => problem_response("Round was not found."),
              "413" =>
                problem_response("Encoded event replay body exceeds the configured limit."),
              "503" => problem_response("Store or daemon is unavailable.")
            }
          )
      }
    }
  end

  defp components do
    %{
      "securitySchemes" => %{
        "bearerAuth" => %{
          "type" => "http",
          "scheme" => "bearer",
          "description" =>
            "Required for all mutating control-plane routes and whenever the HTTP API is configured with a bearer token. Tokens are accepted only in the Authorization header."
        }
      },
      "schemas" => %{
        "OpenAPIContract" => %{
          "type" => "object",
          "additionalProperties" => true,
          "required" => ["openapi", "info", "paths"]
        },
        "ProblemDetails" => %{
          "type" => "object",
          "additionalProperties" => true,
          "required" => ["type", "title", "status", "reason", "detail"],
          "properties" => %{
            "type" => %{"type" => "string", "format" => "uri-reference"},
            "title" => %{"type" => "string"},
            "status" => %{"type" => "integer", "minimum" => 100, "maximum" => 599},
            "reason" => %{"type" => "string"},
            "detail" => %{"type" => "string"},
            "error" => %{"type" => "object", "additionalProperties" => true}
          }
        },
        "HealthResponse" => %{
          "type" => "object",
          "required" => ["status", "breech"],
          "properties" => %{
            "status" => %{"type" => "string", "const" => "ok"},
            "breech" => %{"type" => "object", "additionalProperties" => true}
          }
        },
        "RoundCreateRequest" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "workflow" => %{"type" => "object", "additionalProperties" => true},
            "workflow_path" => %{"type" => "string", "minLength" => 1},
            "input" => %{"type" => "object", "additionalProperties" => true, "default" => %{}},
            "round_id" => %{"type" => "string", "minLength" => 1},
            "approve_all_safety?" => %{"type" => "boolean"}
          },
          "anyOf" => [
            %{"required" => ["workflow"]},
            %{"required" => ["workflow_path"]}
          ]
        },
        "RoundCreateResponse" => %{
          "type" => "object",
          "required" => ["id", "status"],
          "properties" => %{
            "id" => %{"type" => "string"},
            "status" => %{"type" => "string", "const" => "queued"}
          }
        },
        "ControlReasonRequest" => %{
          "type" => "object",
          "additionalProperties" => false,
          "properties" => %{
            "reason" => %{"type" => "string"},
            "actor" => %{"type" => "string"}
          }
        },
        "ControlDecisionResponse" => %{
          "type" => "object",
          "required" => ["status", "decision", "round_id"],
          "properties" => %{
            "status" => %{"type" => "string", "const" => "accepted"},
            "decision" => %{"type" => "string", "enum" => ["approve", "reject", "cancel"]},
            "round_id" => %{"type" => "string"},
            "shot_id" => %{"type" => "string"}
          }
        },
        "WebhookTriggerRequest" => %{
          "type" => "object",
          "description" =>
            "Webhook payload. The configured webhook decides whether the whole object or its input field becomes round input.",
          "additionalProperties" => true
        },
        "WebhookTriggerResponse" => %{
          "type" => "object",
          "required" => ["id", "status", "webhook_id"],
          "properties" => %{
            "id" => %{"type" => "string"},
            "status" => %{"type" => "string", "const" => "queued"},
            "webhook_id" => %{"type" => "string"}
          }
        },
        "RoundSnapshot" => event_like_schema(),
        "RoundEvent" => event_like_schema(["seq", "round_id", "event_type", "occurred_at"]),
        "AuditEvent" => event_like_schema(["seq", "round_id", "event_type", "occurred_at"]),
        "AuditCheckpoint" => %{
          "type" => "object",
          "required" => [
            "kind",
            "schema_version",
            "algorithm",
            "scope",
            "event_count",
            "root_hash",
            "events"
          ],
          "properties" => %{
            "kind" => %{"type" => "string", "const" => "twelvgaige.audit.checkpoint"},
            "schema_version" => %{"type" => "integer", "const" => 1},
            "algorithm" => %{"type" => "string", "const" => "sha256-chain-v1"},
            "scope" => %{"type" => "string", "enum" => ["audit", "round"]},
            "round_id" => %{"type" => "string"},
            "event_count" => %{"type" => "integer", "minimum" => 0},
            "first_seq" => %{"type" => "integer", "nullable" => true},
            "last_seq" => %{"type" => "integer", "nullable" => true},
            "root_hash" => %{"type" => "string", "minLength" => 64, "maxLength" => 64},
            "generated_at" => %{"type" => "string", "format" => "date-time"},
            "events" => %{
              "type" => "array",
              "items" => %{
                "allOf" => [
                  event_like_schema(),
                  %{
                    "type" => "object",
                    "required" => ["previous_hash", "event_hash"],
                    "properties" => %{
                      "previous_hash" => %{
                        "type" => "string",
                        "minLength" => 64,
                        "maxLength" => 64
                      },
                      "event_hash" => %{
                        "type" => "string",
                        "minLength" => 64,
                        "maxLength" => 64
                      }
                    }
                  }
                ]
              }
            }
          }
        },
        "CloudEvent" => %{
          "type" => "object",
          "required" => ["specversion", "id", "source", "type", "data"],
          "properties" => %{
            "specversion" => %{"type" => "string", "const" => "1.0"},
            "id" => %{"type" => "string"},
            "source" => %{"type" => "string"},
            "type" => %{"type" => "string"},
            "subject" => %{"type" => "string"},
            "time" => %{"type" => "string", "format" => "date-time"},
            "datacontenttype" => %{"type" => "string"},
            "data" => %{"type" => "object", "additionalProperties" => true}
          }
        }
      }
    }
  end

  defp operation(operation_id, tag, summary, opts) do
    responses =
      opts
      |> Keyword.fetch!(:responses)
      |> Map.put_new("429", rate_limit_response())

    %{
      "operationId" => operation_id,
      "tags" => [tag],
      "summary" => summary,
      "responses" => responses
    }
    |> maybe_put("parameters", Keyword.get(opts, :parameters))
    |> maybe_put("requestBody", Keyword.get(opts, :request_body))
  end

  defp safety_responses(description) do
    %{
      "202" => json_response(description, "ControlDecisionResponse"),
      "400" => problem_response("Request body is invalid."),
      "404" => problem_response("Round or shot was not found."),
      "503" => problem_response("Store or daemon is unavailable.")
    }
  end

  defp request_body(schema_name) do
    %{
      "required" => true,
      "content" => %{
        "application/json" => %{"schema" => ref(schema_name)}
      }
    }
  end

  defp optional_request_body(schema_name) do
    request_body(schema_name)
    |> Map.put("required", false)
  end

  defp json_response(description, schema_name) when is_binary(schema_name) do
    json_response(description, ref(schema_name))
  end

  defp json_response(description, schema) when is_map(schema) do
    %{
      "description" => description,
      "content" => %{"application/json" => %{"schema" => schema}}
    }
  end

  defp event_replay_response(description, item_schema_name) do
    %{
      "description" => description,
      "headers" => %{
        "x-twelvgaige-stream-mode" => %{
          "schema" => %{"type" => "string", "enum" => ["bounded-replay", "chunked-push"]},
          "description" =>
            "bounded-replay is a fixed-length router response. chunked-push is used by the concrete HTTP listener when stream=true."
        },
        "x-twelvgaige-stream-max-bytes" => %{
          "schema" => %{"type" => "integer", "minimum" => 1},
          "description" => "Maximum encoded event response size for bounded replay requests."
        }
      },
      "content" => %{
        "application/json" => %{
          "schema" => %{"type" => "array", "items" => ref(item_schema_name)}
        },
        "application/x-ndjson" => %{
          "schema" => %{
            "type" => "string",
            "description" => "One JSON event object per LF-terminated line."
          }
        },
        "text/event-stream" => %{
          "schema" => %{
            "type" => "string",
            "description" =>
              "Server-Sent Events using id, event, data, and heartbeat comment framing."
          }
        },
        "application/cloudevents-batch+json" => %{
          "schema" => %{
            "type" => "array",
            "items" => ref("CloudEvent")
          }
        },
        "application/json; profile=\"twelvgaige.audit.checkpoint\"" => %{
          "schema" => ref("AuditCheckpoint")
        }
      }
    }
  end

  defp problem_response(description) do
    %{
      "description" => description,
      "content" => %{"application/problem+json" => %{"schema" => ref("ProblemDetails")}}
    }
  end

  defp rate_limit_response do
    %{
      "description" => "API rate limit exceeded.",
      "headers" => %{
        "RateLimit-Limit" => integer_header("Total requests permitted in the current window."),
        "RateLimit-Remaining" => integer_header("Remaining requests in the current window."),
        "RateLimit-Reset" => integer_header("Seconds until the current window resets."),
        "Retry-After" => integer_header("Seconds to wait before retrying.")
      },
      "content" => %{"application/problem+json" => %{"schema" => ref("ProblemDetails")}}
    }
  end

  defp integer_header(description) do
    %{
      "description" => description,
      "schema" => %{"type" => "integer", "minimum" => 0}
    }
  end

  defp round_id_path, do: path_param("round_id", "Round identifier.")
  defp shot_id_path, do: path_param("shot_id", "Safety shot identifier.")
  defp webhook_id_path, do: path_param("webhook_id", "Configured webhook identifier.")

  defp path_param(name, description) do
    %{
      "name" => name,
      "in" => "path",
      "required" => true,
      "description" => description,
      "schema" => %{"type" => "string", "minLength" => 1}
    }
  end

  defp status_query do
    %{
      "name" => "status",
      "in" => "query",
      "required" => false,
      "description" => "Filter by round status.",
      "schema" => %{"type" => "string"}
    }
  end

  defp after_seq_query do
    %{
      "name" => "after_seq",
      "in" => "query",
      "required" => false,
      "description" => "Return events with sequence numbers greater than this cursor.",
      "schema" => %{"type" => "integer", "minimum" => 0}
    }
  end

  defp limit_query do
    %{
      "name" => "limit",
      "in" => "query",
      "required" => false,
      "description" => "Maximum number of items to return.",
      "schema" => %{"type" => "integer", "minimum" => 1}
    }
  end

  defp format_query do
    %{
      "name" => "format",
      "in" => "query",
      "required" => false,
      "description" => "Replay format.",
      "schema" => %{
        "type" => "string",
        "enum" => ["json", "ndjson", "sse", "cloudevents", "checkpoint"],
        "default" => "json"
      }
    }
  end

  defp follow_query do
    %{
      "name" => "follow",
      "in" => "query",
      "required" => false,
      "description" =>
        "When true for round events, wait up to timeout_ms for the next event if replay is empty. stream=true implies repeated follow at the HTTP listener boundary.",
      "schema" => %{"type" => "boolean", "default" => false}
    }
  end

  defp stream_query do
    %{
      "name" => "stream",
      "in" => "query",
      "required" => false,
      "description" =>
        "When true on the concrete HTTP listener, stream round events with HTTP/1.1 chunked transfer encoding. Only format=sse and format=ndjson are supported.",
      "schema" => %{"type" => "boolean", "default" => false}
    }
  end

  defp until_terminal_query do
    %{
      "name" => "until_terminal",
      "in" => "query",
      "required" => false,
      "description" =>
        "When true with follow=true or stream=true, continue advancing the cursor until the round reaches a terminal state, the idle/deadline bound expires, or the limit is reached.",
      "schema" => %{"type" => "boolean", "default" => false}
    }
  end

  defp timeout_ms_query do
    %{
      "name" => "timeout_ms",
      "in" => "query",
      "required" => false,
      "description" => "Maximum bounded-follow wait in milliseconds.",
      "schema" => %{"type" => "integer", "minimum" => 0, "default" => 30000}
    }
  end

  defp event_like_schema(required \\ []) do
    %{
      "type" => "object",
      "additionalProperties" => true,
      "required" => required,
      "properties" => %{
        "id" => %{"type" => "string"},
        "seq" => %{"type" => "integer", "minimum" => 0},
        "round_id" => %{"type" => "string"},
        "event_type" => %{"type" => "string"},
        "status" => %{"type" => "string"},
        "occurred_at" => %{"type" => "string", "format" => "date-time"}
      }
    }
  end

  defp ref(schema_name), do: %{"$ref" => "#/components/schemas/#{schema_name}"}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
