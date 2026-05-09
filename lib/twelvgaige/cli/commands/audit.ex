defmodule Twelvgaige.CLI.Commands.Audit do
  @moduledoc false

  alias Twelvgaige.Audit.Event, as: AuditEvent
  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers,
    only: [
      format_command_error: 2,
      parse_format: 1,
      parse_non_negative_integer: 1,
      parse_positive_integer: 1,
      value: 2,
      value: 3
    ]

  @spec round(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def round(round_id, args) do
    with {:ok, opts} <- parse_audit_opts(args) do
      case Twelvgaige.list_audit_events(round_id, Keyword.take(opts, [:after_seq, :limit])) do
        {:ok, events} ->
          case format_audit_events(events, opts) do
            {:ok, output} ->
              {:ok, output, 0}

            {:error, error} ->
              {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
          end

        {:error, error} ->
          {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
      end
    else
      {:error, error} -> {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  @spec verify_checkpoint(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  def verify_checkpoint(path, args) do
    case parse_audit_verify_opts(args) do
      {:ok, opts} ->
        with {:ok, contents} <- read_audit_checkpoint(path),
             {:ok, checkpoint} <- decode_audit_checkpoint(contents, path) do
          case Twelvgaige.Audit.Checkpoint.verify(checkpoint) do
            :ok ->
              case maybe_verify_checkpoint_hmac(checkpoint, opts) do
                :ok ->
                  {:ok, format_audit_verify_ok(checkpoint, opts[:format]), 0}

                {:error, %Twelvgaige.Error{} = error} ->
                  {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}

                {:error, reason} ->
                  {:ok, format_audit_verify_error(reason, opts[:format]), 1}
              end

            {:error, reason} ->
              {:ok, format_audit_verify_error(reason, opts[:format]), 1}
          end
        else
          {:error, error} ->
            {:ok, format_command_error(error, opts[:format]), ExitCode.for_error(error)}
        end

      {:error, error} ->
        {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
    end
  end

  defp parse_audit_opts(args),
    do: parse_audit_opts(args, format: :human, after_seq: 0, limit: 100, sign_hmac_env: nil)

  defp parse_audit_opts([], opts), do: {:ok, opts}

  defp parse_audit_opts(["--format", format | rest], opts) do
    parse_audit_opts(rest, Keyword.put(opts, :format, parse_audit_format(format)))
  end

  defp parse_audit_opts(["--after-seq", seq | rest], opts) do
    case parse_non_negative_integer(seq) do
      {:ok, seq} ->
        parse_audit_opts(rest, Keyword.put(opts, :after_seq, seq))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--after-seq must be >= 0")}
    end
  end

  defp parse_audit_opts(["--limit", limit | rest], opts) do
    case parse_positive_integer(limit) do
      {:ok, limit} ->
        parse_audit_opts(rest, Keyword.put(opts, :limit, limit))

      :error ->
        {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "--limit must be > 0")}
    end
  end

  defp parse_audit_opts(["--sign-hmac-env", env | rest], opts) do
    parse_audit_opts(rest, Keyword.put(opts, :sign_hmac_env, env))
  end

  defp parse_audit_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp parse_audit_verify_opts(args),
    do: parse_audit_verify_opts(args, format: :human, hmac_env: nil)

  defp parse_audit_verify_opts([], opts), do: {:ok, opts}

  defp parse_audit_verify_opts(["--format", format | rest], opts) do
    parse_audit_verify_opts(rest, Keyword.put(opts, :format, parse_format(format)))
  end

  defp parse_audit_verify_opts(["--hmac-env", env | rest], opts) do
    parse_audit_verify_opts(rest, Keyword.put(opts, :hmac_env, env))
  end

  defp parse_audit_verify_opts([unknown | _rest], _opts) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "unknown option #{unknown}")}
  end

  defp format_audit_events(events, opts) when is_list(opts) do
    format = opts[:format]
    sign_hmac_env = opts[:sign_hmac_env]

    cond do
      is_binary(sign_hmac_env) and sign_hmac_env != "" and format != :checkpoint ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "--sign-hmac-env requires --format checkpoint"
         )}

      is_binary(sign_hmac_env) and sign_hmac_env != "" ->
        with {:ok, key} <- hmac_key_from_env(sign_hmac_env),
             {:ok, signed} <-
               events
               |> Twelvgaige.Audit.Checkpoint.export(scope: :audit)
               |> Twelvgaige.Audit.Checkpoint.sign_hmac(key, key_ref: sign_hmac_env) do
          {:ok, signed |> Jason.encode!() |> Kernel.<>("\n")}
        end

      true ->
        {:ok, format_audit_events(events, format)}
    end
  end

  defp format_audit_events([], :human), do: "No audit events.\n"
  defp format_audit_events([], :ndjson), do: ""

  defp format_audit_events(events, :json) do
    events
    |> Enum.map(&AuditEvent.to_map/1)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_audit_events(events, :checkpoint) do
    events
    |> Twelvgaige.Audit.Checkpoint.export(scope: :audit)
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_audit_events(events, :ndjson) do
    events
    |> Enum.map(fn event -> event |> AuditEvent.to_map() |> Jason.encode!() end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_audit_events(events, :human) do
    events
    |> Enum.map(fn event ->
      event = AuditEvent.to_map(event)
      seq = value(event, :seq, "?")
      event_type = value(event, :event_type, "unknown")
      actor = value(event, :actor)
      shot_id = value(event, :shot_id)

      detail =
        [
          if(actor, do: "actor=#{actor}"),
          if(shot_id, do: "shot=#{shot_id}")
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join(" ")

      ["##{seq}", event_type, detail]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")
    end)
    |> Enum.join("\n")
    |> Kernel.<>("\n")
  end

  defp format_audit_verify_ok(checkpoint, :json) do
    %{
      status: "ok",
      valid: true,
      kind: checkpoint["kind"],
      algorithm: checkpoint["algorithm"],
      scope: checkpoint["scope"],
      round_id: checkpoint["round_id"],
      event_count: checkpoint["event_count"],
      first_seq: checkpoint["first_seq"],
      last_seq: checkpoint["last_seq"],
      root_hash: checkpoint["root_hash"],
      generated_at: checkpoint["generated_at"],
      signature: checkpoint["signature"]
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_audit_verify_ok(checkpoint, :human) do
    round_id = checkpoint["round_id"] || "unknown"
    event_count = checkpoint["event_count"] || 0
    root_hash = checkpoint["root_hash"] || "unknown"
    signature = value(checkpoint["signature"], :algorithm, "unsigned")

    "valid audit checkpoint: round=#{round_id} events=#{event_count} root_hash=#{root_hash} signature=#{signature}\n"
  end

  defp format_audit_verify_error(reason, :json) do
    %{
      status: "failed",
      valid: false,
      reason: audit_verify_reason(reason),
      details: audit_verify_details(reason)
    }
    |> Jason.encode!()
    |> Kernel.<>("\n")
  end

  defp format_audit_verify_error(reason, :human) do
    "invalid audit checkpoint: #{audit_verify_reason(reason)}#{audit_verify_detail_text(reason)}\n"
  end

  defp read_audit_checkpoint("-"), do: {:ok, IO.read(:stdio, :eof)}

  defp read_audit_checkpoint(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} ->
        {:ok, contents}

      {:error, reason} ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "unable to read audit checkpoint",
           details: %{path: path, reason: inspect(reason)}
         )}
    end
  end

  defp decode_audit_checkpoint(contents, source) do
    case Jason.decode(contents) do
      {:ok, checkpoint} when is_map(checkpoint) ->
        {:ok, checkpoint}

      {:ok, _other} ->
        {:error,
         Twelvgaige.Error.new(
           :input_error,
           :invalid_shell,
           "audit checkpoint must be a JSON object",
           details: %{source: source}
         )}

      {:error, error} ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "invalid audit checkpoint JSON",
           details: %{source: source, reason: Exception.message(error)}
         )}
    end
  end

  defp maybe_verify_checkpoint_hmac(checkpoint, opts) do
    case opts[:hmac_env] do
      nil ->
        :ok

      env ->
        with {:ok, key} <- hmac_key_from_env(env) do
          Twelvgaige.Audit.Checkpoint.verify_hmac(checkpoint, key)
        end
    end
  end

  defp hmac_key_from_env(env) when is_binary(env) and env != "" do
    case System.get_env(env) do
      nil ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "HMAC key env is not set",
           details: %{env: env}
         )}

      "" ->
        {:error,
         Twelvgaige.Error.new(:input_error, :invalid_shell, "HMAC key env is empty",
           details: %{env: env}
         )}

      "base64:" <> encoded ->
        case Base.decode64(encoded) do
          {:ok, key} ->
            {:ok, key}

          :error ->
            {:error,
             Twelvgaige.Error.new(:input_error, :invalid_shell, "HMAC key env is invalid base64",
               details: %{env: env}
             )}
        end

      key ->
        {:ok, key}
    end
  end

  defp hmac_key_from_env(_env) do
    {:error, Twelvgaige.Error.new(:input_error, :invalid_shell, "HMAC key env is required")}
  end

  defp parse_audit_format("json"), do: :json
  defp parse_audit_format("checkpoint"), do: :checkpoint
  defp parse_audit_format(format), do: parse_watch_format(format)

  defp parse_watch_format("ndjson"), do: :ndjson
  defp parse_watch_format(format), do: parse_format(format)

  defp audit_verify_reason({reason, _seq}) when is_atom(reason), do: Atom.to_string(reason)
  defp audit_verify_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp audit_verify_reason(reason), do: inspect(reason)

  defp audit_verify_details({_reason, seq}), do: %{seq: seq}
  defp audit_verify_details(_reason), do: %{}

  defp audit_verify_detail_text({_reason, seq}), do: " seq=#{seq}"
  defp audit_verify_detail_text(_reason), do: ""
end
