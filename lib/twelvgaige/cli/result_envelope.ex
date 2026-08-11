defmodule Twelvgaige.CLI.ResultEnvelope do
  @moduledoc false

  @result_schema "twelvgaige.cli.result"
  @event_schema "twelvgaige.cli.event"
  @schema_version 1
  @max_legacy_message_bytes 2_048

  @resource_keys ~w(session_id workspace_id workspace_set_id round_id operation_id plan_id)

  @spec wrap({:ok, String.t(), non_neg_integer()}, [String.t()]) ::
          {:ok, String.t(), non_neg_integer()}
  def wrap({:ok, output, code} = result, args) do
    case requested_format(args) do
      :json -> wrap_json(output, code, command(args))
      :ndjson -> wrap_ndjson(output, code, command(args))
      _format -> result
    end
  end

  @spec result_schema() :: String.t()
  def result_schema, do: @result_schema

  @spec event_schema() :: String.t()
  def event_schema, do: @event_schema

  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @spec requested_format([String.t()]) :: :json | :ndjson | :checkpoint | :other
  def requested_format(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.find_value(:other, fn
      ["--format", "json"] -> :json
      ["--format", "ndjson"] -> :ndjson
      ["--format", "checkpoint"] -> :checkpoint
      _pair -> nil
    end)
  end

  @spec machine_format?([String.t()]) :: boolean()
  def machine_format?(args), do: requested_format(args) in [:json, :ndjson, :checkpoint]

  @spec result(map()) :: {:ok, term()} | {:error, term()}
  def result(%{
        "schema" => @result_schema,
        "schema_version" => @schema_version,
        "result" => result
      }),
      do: {:ok, result}

  def result(%{
        "schema" => @result_schema,
        "schema_version" => @schema_version,
        "error" => error
      }),
      do: {:error, error}

  def result(_envelope), do: {:error, :invalid_cli_result_envelope}

  @spec encode_event(term(), String.t(), non_neg_integer()) :: String.t()
  def encode_event(payload, command, index) do
    %{
      schema: @event_schema,
      schema_version: @schema_version,
      command: command,
      event_index: index,
      event_type: event_type(payload),
      terminal: false,
      event: payload
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  @spec encode_terminal(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def encode_terminal(command, code, event_count) do
    %{
      schema: @event_schema,
      schema_version: @schema_version,
      command: command,
      event_index: event_count,
      event_type: "terminal",
      terminal: true,
      disposition: disposition(code),
      exit_code: code,
      event_count: event_count
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  @spec command([String.t()]) :: String.t()
  def command(args) do
    case Enum.take_while(args, &(&1 != "--format")) do
      ["workspace", section, action | _rest] when section in ["set", "review", "retention"] ->
        Enum.join(["workspace", section, action], " ")

      ["operations", section, action | _rest]
      when section in ["audit", "store", "retention", "artifact", "release"] ->
        Enum.join(["operations", section, action], " ")

      ["daemon", "token", action | _rest] ->
        Enum.join(["daemon", "token", action], " ")

      ["shell", section, action | _rest]
      when section in ["scaffold", "author", "patch", "metadata", "bulk"] ->
        Enum.join(["shell", section, action], " ")

      ["shot", "library", action | _rest] ->
        Enum.join(["shot", "library", action], " ")

      command_args ->
        command_args
        |> Enum.reject(&String.starts_with?(&1, "-"))
        |> Enum.take(2)
        |> Enum.join(" ")
        |> case do
          "" -> "help"
          name -> name
        end
    end
  end

  defp wrap_json(output, code, command) do
    case Jason.decode(output) do
      {:ok, payload} ->
        {:ok, encode_result(payload, code, command), code}

      {:error, _reason} ->
        effective_code = if code == 0, do: 8, else: code

        error = %{
          reason: "unstructured_command_output",
          message: legacy_message(output)
        }

        {:ok, encode_error(error, effective_code, command), effective_code}
    end
  end

  defp wrap_ndjson(output, code, command) do
    lines = String.split(output, "\n", trim: true)

    {events, invalid?} =
      lines
      |> Enum.with_index()
      |> Enum.map_reduce(false, fn {line, index}, invalid? ->
        case Jason.decode(line) do
          {:ok, payload} ->
            {encode_event(payload, command, index), invalid?}

          {:error, _reason} ->
            payload = %{
              error: %{
                reason: "unstructured_command_output",
                message: legacy_message(line)
              }
            }

            {encode_event(payload, command, index), true}
        end
      end)

    effective_code = if invalid? and code == 0, do: 8, else: code
    terminal = encode_terminal(command, effective_code, length(lines))
    {:ok, IO.iodata_to_binary([events, terminal]), effective_code}
  end

  defp encode_result(%{"error" => error} = payload, code, command) when is_map(error) do
    envelope = base(command, code) |> Map.put(:error, error)
    encode_envelope(envelope, payload)
  end

  defp encode_result(payload, code, command) do
    envelope = base(command, code) |> Map.put(:result, payload)
    encode_envelope(envelope, payload)
  end

  defp encode_error(error, code, command) do
    command
    |> base(code)
    |> Map.put(:error, error)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp base(command, code) do
    %{
      schema: @result_schema,
      schema_version: @schema_version,
      command: command,
      disposition: disposition(code),
      exit_code: code
    }
  end

  defp encode_envelope(envelope, payload) do
    envelope
    |> maybe_put_request_id(payload)
    |> maybe_put_resource_ids(payload)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp maybe_put_request_id(envelope, %{} = payload) do
    case value(payload, "request_id") do
      request_id when is_binary(request_id) and request_id != "" ->
        Map.put(envelope, :request_id, request_id)

      _request_id ->
        envelope
    end
  end

  defp maybe_put_request_id(envelope, _payload), do: envelope

  defp maybe_put_resource_ids(envelope, %{} = payload) do
    resource_ids =
      Enum.reduce(@resource_keys, %{}, fn key, acc ->
        case value(payload, key) do
          id when is_binary(id) and id != "" -> Map.put(acc, key, id)
          _id -> acc
        end
      end)

    resource_ids = maybe_put_inferred_id(resource_ids, payload, envelope.command)

    if map_size(resource_ids) == 0,
      do: envelope,
      else: Map.put(envelope, :resource_ids, resource_ids)
  end

  defp maybe_put_resource_ids(envelope, _payload), do: envelope

  defp maybe_put_inferred_id(resource_ids, payload, command) do
    with id when is_binary(id) and id != "" <- value(payload, "id"),
         key when not is_nil(key) <- inferred_id_key(command),
         false <- Map.has_key?(resource_ids, key) do
      Map.put(resource_ids, key, id)
    else
      _other -> resource_ids
    end
  end

  defp inferred_id_key("session " <> _action), do: "session_id"
  defp inferred_id_key("workspace " <> _action), do: "workspace_id"
  defp inferred_id_key("round " <> _action), do: "round_id"
  defp inferred_id_key(_command), do: nil

  defp disposition(0), do: "succeeded"
  defp disposition(_code), do: "failed"

  defp event_type(%{} = payload) do
    case value(payload, "event_type") do
      type when is_binary(type) and type != "" -> type
      _type -> if(is_map(value(payload, "error")), do: "error", else: "data")
    end
  end

  defp event_type(_payload), do: "data"

  defp legacy_message(output) do
    output
    |> String.trim()
    |> case do
      "" -> "command produced no JSON output"
      message -> binary_part(message, 0, min(byte_size(message), @max_legacy_message_bytes))
    end
  end

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {map_key, value} when is_atom(map_key) ->
            if Atom.to_string(map_key) == key, do: {:found, value}, else: nil

          _entry ->
            nil
        end)
        |> case do
          {:found, value} -> value
          nil -> nil
        end
    end
  end
end
