defmodule Twelvgaige.DelegatedSession.Codex.AppServerClient do
  @moduledoc "Bounded JSON-RPC client for the Codex App Server stdio transport."

  use GenServer

  alias Twelvgaige.DelegatedSession.Codex.{Approval, EventCodec, Schema}
  alias Twelvgaige.Event.Buffer

  @approval_methods [
    "item/commandExecution/requestApproval",
    "item/fileChange/requestApproval",
    "item/permissions/requestApproval",
    "mcpServer/elicitation/request"
  ]

  defstruct [
    :port,
    :send_frame,
    :close_transport,
    :session_id,
    :thread_id,
    :turn_id,
    :signing_key,
    :policy_profile,
    :schema_path,
    :exit_reason,
    next_id: 1,
    pending: %{},
    approvals: %{},
    buffer: nil,
    overloaded?: false,
    initialized?: false
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def initialize(server, opts \\ []) do
    params = %{
      "clientInfo" => %{
        "name" => Keyword.get(opts, :client_name, "twelvgaige"),
        "title" => Keyword.get(opts, :client_title, "Twelvgaige"),
        "version" => Keyword.get(opts, :client_version, "0.0.3")
      },
      "capabilities" => %{"experimentalApi" => false}
    }

    with {:ok, result} <- request(server, "initialize", params, opts),
         :ok <- notify(server, "initialized", %{}) do
      {:ok, result}
    end
  end

  def request(server, method, params, opts \\ []),
    do: GenServer.call(server, {:request, method, params, opts}, :infinity)

  def notify(server, method, params \\ %{}),
    do: GenServer.call(server, {:notify, method, params})

  def ingest(server, frame), do: GenServer.cast(server, {:ingest, frame})
  def drain(server, limit \\ 100), do: GenServer.call(server, {:drain, limit})
  def status(server), do: GenServer.call(server, :status)
  def approval(server, approval_id), do: GenServer.call(server, {:approval, approval_id})

  def decide(server, approval_id, receipt),
    do: GenServer.call(server, {:decide, approval_id, receipt})

  def close(server), do: GenServer.stop(server, :normal)

  @impl true
  def init(opts) do
    state = %__MODULE__{
      session_id: Keyword.fetch!(opts, :session_id),
      signing_key:
        Keyword.get_lazy(opts, :approval_signing_key, fn -> :crypto.strong_rand_bytes(32) end),
      policy_profile: Keyword.get(opts, :policy_profile, :restricted),
      schema_path: Keyword.get(opts, :schema_path, Schema.bundle_path()),
      buffer:
        Buffer.new(
          capacity: Keyword.get(opts, :event_capacity, 512),
          critical_reserve: Keyword.get(opts, :critical_event_reserve, 64)
        )
    }

    with :ok <- Schema.verify_bundle(state.schema_path),
         {:ok, transport} <- start_transport(opts) do
      {:ok,
       %{
         state
         | port: transport[:port],
           send_frame: transport.send,
           close_transport: transport.close
       }}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call({:request, method, params, opts}, from, state) do
    with false <- state.overloaded? and work_method?(method),
         :ok <- Schema.validate_request(method, params),
         :ok <- Schema.validate_policy(method, params, state.policy_profile) do
      id = state.next_id
      frame = %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
      timeout_ms = Keyword.get(opts, :timeout_ms, 30_000)

      case send_json(state, frame) do
        :ok ->
          timer = Process.send_after(self(), {:request_timeout, id}, timeout_ms)
          pending = Map.put(state.pending, id, %{from: from, method: method, timer: timer})
          {:noreply, %{state | next_id: id + 1, pending: pending}}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    else
      true -> {:reply, {:error, :codex_protocol_overloaded}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:notify, method, params}, _from, state) do
    frame = %{"jsonrpc" => "2.0", "method" => method}
    frame = if params == %{}, do: frame, else: Map.put(frame, "params", params)
    {:reply, send_json(state, frame), state}
  end

  def handle_call({:drain, limit}, _from, state) do
    {events, buffer} = drain_buffer(state.buffer, limit, [])
    overloaded? = state.overloaded? and Buffer.size(buffer) >= div(buffer.capacity, 2)
    {:reply, {:ok, events}, %{state | buffer: buffer, overloaded?: overloaded?}}
  end

  def handle_call(:status, _from, state) do
    {:reply,
     {:ok,
      %{
        initialized?: state.initialized?,
        thread_id: state.thread_id,
        turn_id: state.turn_id,
        buffer: Buffer.stats(state.buffer),
        overloaded?: state.overloaded?,
        exit_reason: state.exit_reason,
        schema_digest: Schema.digest()
      }}, state}
  end

  def handle_call({:approval, approval_id}, _from, state),
    do: {:reply, Map.fetch(state.approvals, approval_id), state}

  def handle_call({:decide, approval_id, receipt}, _from, state) do
    case Map.fetch(state.approvals, approval_id) do
      {:ok, %{intent: intent, request_id: request_id}} ->
        with :ok <- Approval.verify(intent, receipt, state.signing_key),
             :ok <-
               send_json(state, %{
                 "jsonrpc" => "2.0",
                 "id" => request_id,
                 "result" => %{"decision" => Approval.native_decision(receipt.decision)}
               }) do
          {:reply, :ok, %{state | approvals: Map.delete(state.approvals, approval_id)}}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      :error ->
        {:reply, {:error, :approval_not_found}, state}
    end
  end

  @impl true
  def handle_cast({:ingest, frame}, state), do: {:noreply, ingest_frame(frame, state)}

  @impl true
  def handle_info({port, {:data, {:eol, line}}}, %{port: port} = state),
    do: {:noreply, ingest_frame(line, state)}

  def handle_info({port, {:data, {:noeol, _line}}}, %{port: port} = state),
    do: {:stop, :codex_protocol_line_too_large, state}

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = fail_pending(state, {:codex_app_server_exited, status})
    {:noreply, %{state | exit_reason: {:exit_status, status}, port: nil}}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :codex_request_timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if is_function(state.close_transport, 0), do: state.close_transport.()
    :ok
  end

  defp ingest_frame(frame, state) when is_binary(frame) do
    case Jason.decode(frame) do
      {:ok, decoded} -> ingest_decoded(decoded, state)
      {:error, _reason} -> %{state | exit_reason: :codex_protocol_invalid_json}
    end
  end

  defp ingest_frame(frame, state) when is_map(frame), do: ingest_decoded(frame, state)

  defp ingest_decoded(%{"id" => id, "result" => result}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {%{from: from, method: method, timer: timer}, pending} ->
        Process.cancel_timer(timer)

        reply =
          case Schema.validate_response(method, result) do
            :ok -> {:ok, result}
            {:error, reason} -> {:error, reason}
          end

        GenServer.reply(from, reply)

        state
        |> Map.put(:pending, pending)
        |> capture_identity(method, result)
        |> maybe_mark_initialized(method, reply)
    end
  end

  defp ingest_decoded(%{"id" => id, "error" => error}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        state

      {%{from: from, timer: timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:error, {:codex_rpc_error, error}})
        %{state | pending: pending}
    end
  end

  defp ingest_decoded(%{"id" => id, "method" => method, "params" => params}, state)
       when method in @approval_methods do
    approval_id = params["approvalId"] || params["itemId"] || "#{method}:#{id}"

    intent =
      Approval.intent(
        %{
          id: approval_id,
          method: method,
          session_id: state.session_id,
          thread_id: params["threadId"] || state.thread_id,
          turn_id: params["turnId"] || state.turn_id,
          native_request_id: id,
          params: params,
          expires_at: DateTime.add(Twelvgaige.Clock.utc_now(), 300, :second)
        },
        state.signing_key
      )

    approvals = Map.put(state.approvals, approval_id, %{intent: intent, request_id: id})
    params = Map.put(params, "approvalIntent", intent)
    enqueue(method, params, %{state | approvals: approvals}, :critical)
  end

  defp ingest_decoded(%{"method" => method, "params" => params} = frame, state) do
    state = capture_notification_identity(method, params, state)
    enqueue(method, params, state, nil, frame["emittedAtMs"])
  end

  defp ingest_decoded(_frame, state), do: state

  defp enqueue(method, params, state, class, emitted_at_ms \\ nil) do
    context = %{
      session_id: state.session_id,
      thread_id: state.thread_id,
      turn_id: state.turn_id,
      emitted_at_ms: emitted_at_ms
    }

    case EventCodec.decode(method, params, context) do
      :ignore ->
        state

      {:ok, event} ->
        event_class = class || event.event_class

        opts =
          [class: event_class]
          |> maybe_coalesce(event_class, method, params)

        case Buffer.push(state.buffer, event, opts) do
          {:ok, buffer} -> %{state | buffer: buffer}
          {:overload, buffer, _reason} -> %{state | buffer: buffer, overloaded?: true}
        end
    end
  end

  defp capture_identity(state, method, result)
       when method in ["thread/start", "thread/resume", "thread/fork"] do
    %{state | thread_id: get_in(result, ["thread", "id"])}
  end

  defp capture_identity(state, "turn/start", result),
    do: %{state | turn_id: get_in(result, ["turn", "id"])}

  defp capture_identity(state, _method, _result), do: state

  defp capture_notification_identity("thread/started", params, state),
    do: %{state | thread_id: get_in(params, ["thread", "id"]) || params["threadId"]}

  defp capture_notification_identity("turn/started", params, state),
    do: %{state | turn_id: get_in(params, ["turn", "id"]) || params["turnId"]}

  defp capture_notification_identity(_method, _params, state), do: state

  defp maybe_mark_initialized(state, "initialize", {:ok, _result}),
    do: %{state | initialized?: true}

  defp maybe_mark_initialized(state, _method, _reply), do: state

  defp send_json(state, frame) do
    encoded = Jason.encode_to_iodata!(frame)
    state.send_frame.([encoded, "\n"])
  rescue
    error -> {:error, {:codex_transport_write_failed, Exception.message(error)}}
  end

  defp start_transport(opts) do
    case Keyword.get(opts, :send_frame) do
      send_frame when is_function(send_frame, 1) ->
        {:ok, %{send: send_frame, close: Keyword.get(opts, :close_transport, fn -> :ok end)}}

      nil ->
        open_port(opts)
    end
  end

  defp open_port(opts) do
    binary = Keyword.get(opts, :binary, System.find_executable("codex"))
    env_binary = System.find_executable("env")

    cond do
      not is_binary(binary) ->
        {:error, :codex_binary_not_found}

      not is_binary(env_binary) ->
        {:error, :env_binary_not_found}

      true ->
        environment = Keyword.get(opts, :environment, [])
        assignments = Enum.map(environment, fn {key, value} -> "#{key}=#{value}" end)

        arguments =
          Keyword.get(opts, :arguments, ["app-server", "--stdio", "--strict-config"])

        args = ["-i"] ++ assignments ++ [binary | arguments]

        port =
          Port.open(
            {:spawn_executable, env_binary},
            [:binary, :exit_status, :use_stdio, {:line, 1_048_576}, {:args, args}]
          )

        {:ok,
         %{
           port: port,
           send: fn data -> if Port.command(port, data), do: :ok, else: {:error, :closed} end,
           close: fn -> if Port.info(port), do: Port.close(port), else: :ok end
         }}
    end
  rescue
    error -> {:error, {:codex_transport_start_failed, Exception.message(error)}}
  end

  defp fail_pending(state, reason) do
    Enum.each(state.pending, fn {_id, %{from: from, timer: timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, reason})
    end)

    %{state | pending: %{}}
  end

  defp drain_buffer(buffer, 0, acc), do: {Enum.reverse(acc), buffer}

  defp drain_buffer(buffer, remaining, acc) do
    case Buffer.pop(buffer) do
      {:ok, event, buffer} -> drain_buffer(buffer, remaining - 1, [event | acc])
      :empty -> {Enum.reverse(acc), buffer}
    end
  end

  defp work_method?(method), do: method in ["thread/start", "turn/start", "turn/steer"]

  defp maybe_coalesce(opts, :presentation, method, params) do
    key =
      {method, params["threadId"], params["turnId"],
       params["itemId"] || get_in(params, ["item", "id"])}

    Keyword.put(opts, :coalesce_key, key)
  end

  defp maybe_coalesce(opts, _class, _method, _params), do: opts
end
