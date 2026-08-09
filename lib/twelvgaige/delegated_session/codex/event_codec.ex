defmodule Twelvgaige.DelegatedSession.Codex.EventCodec do
  @moduledoc "Maps stable Codex App Server notifications into delegated-session events."

  alias Twelvgaige.DelegatedSession.Event

  @approval_methods [
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval",
    "mcpServer/elicitation/request"
  ]

  def decode(method, params, context \\ %{}) when is_binary(method) and is_map(params) do
    event_type = event_type(method, params)

    if is_nil(event_type) do
      :ignore
    else
      {:ok,
       Event.new(
         session_id: Map.fetch!(context, :session_id),
         event_type: event_type,
         native_session_id: params["threadId"] || context[:thread_id],
         native_turn_id: turn_id(params) || context[:turn_id],
         native_event_id: native_event_id(method, params, context),
         payload: redact(Map.put(params, "nativeMethod", method)),
         occurred_at: occurred_at(context),
         event_class: event_class(method, event_type)
       )}
    end
  end

  defp event_type("error", _params), do: :session_failed
  defp event_type("thread/started", _params), do: :session_started
  defp event_type("thread/closed", _params), do: :session_stopped
  defp event_type("turn/started", _params), do: :turn_started
  defp event_type("turn/completed", _params), do: :turn_completed
  defp event_type("turn/plan/updated", _params), do: :plan_updated
  defp event_type("item/plan/delta", _params), do: :plan_updated
  defp event_type("item/agentMessage/delta", _params), do: :message_delta
  defp event_type("thread/tokenUsage/updated", _params), do: :usage_updated
  defp event_type("turn/diff/updated", _params), do: :artifact_created
  defp event_type(method, _params) when method in @approval_methods, do: :approval_required

  defp event_type("item/started", %{"item" => %{"type" => type}})
       when type in ["collabAgentToolCall", "subAgentActivity"],
       do: :subagent_started

  defp event_type("item/completed", %{"item" => %{"type" => type}})
       when type in ["collabAgentToolCall", "subAgentActivity"],
       do: :subagent_finished

  defp event_type("item/started", _params), do: :tool_started
  defp event_type("item/completed", _params), do: :tool_finished
  defp event_type("process/exited", _params), do: :tool_finished
  defp event_type(_method, _params), do: nil

  defp event_class(method, _event_type) when method in @approval_methods, do: :critical
  defp event_class("error", _event_type), do: :critical
  defp event_class("turn/completed", _event_type), do: :critical
  defp event_class("thread/closed", _event_type), do: :critical
  defp event_class("item/agentMessage/delta", _event_type), do: :presentation
  defp event_class("item/plan/delta", _event_type), do: :presentation
  defp event_class(_method, _event_type), do: :operational

  defp native_event_id(method, params, context) do
    material = {
      method,
      params["itemId"] || get_in(params, ["item", "id"]),
      turn_id(params),
      context[:emitted_at_ms],
      params
    }

    :crypto.hash(:sha256, :erlang.term_to_binary(material))
    |> Base.encode16(case: :lower)
  end

  defp turn_id(%{"turnId" => turn_id}), do: turn_id
  defp turn_id(%{"turn" => %{"id" => turn_id}}), do: turn_id
  defp turn_id(_params), do: nil

  defp occurred_at(%{emitted_at_ms: milliseconds}) when is_integer(milliseconds),
    do: DateTime.from_unix!(milliseconds, :millisecond)

  defp occurred_at(_context), do: Twelvgaige.Clock.utc_now()

  defp redact(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp redact(map) when is_map(map) do
    Map.new(map, fn {key, value} ->
      if sensitive_key?(key), do: {key, "[REDACTED]"}, else: {key, redact(value)}
    end)
  end

  defp redact(list) when is_list(list), do: Enum.map(list, &redact/1)
  defp redact(value), do: value

  defp sensitive_key?(key) do
    key = key |> to_string() |> String.downcase()

    Enum.any?(
      ~w(token secret password authorization api_key apikey credential),
      &String.contains?(key, &1)
    )
  end
end
