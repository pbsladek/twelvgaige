defmodule Twelvgaige.Crypto.KeyManager.LinuxSecretServiceBackend do
  @moduledoc """
  Desktop Linux Secret Service key backend.

  This backend wraps `secret-tool`, which uses the FreeDesktop Secret Service
  API through a user D-Bus session. It is intended for desktop Linux sessions,
  not containers, WSL, or headless servers without an unlocked secret service.
  """

  @behaviour Twelvgaige.Crypto.KeyManager

  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyManager
  alias Twelvgaige.Crypto.KeyMaterial

  @schema_version 1
  @default_secret_tool_cmd "secret-tool"
  @default_service "twelvgaige.key"

  @impl true
  def create_key(opts) do
    with :ok <- require_linux(opts),
         key_id <- key_id(opts),
         {:ok, :missing} <- find_payload(key_id, opts),
         key <- build_key(key_id, 1, :active, KeyManager.random_key_material(), nil, opts),
         :ok <- store_payload(key, opts) do
      {:ok, key}
    else
      {:ok, %Key{}} -> {:error, :key_already_exists}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def fetch_key(key_ref, opts) do
    with :ok <- require_linux(opts),
         {:ok, %Key{} = key} <- find_payload(key_ref, opts) do
      case key.status do
        :active -> {:ok, key}
        :retired -> {:error, :key_retired}
      end
    else
      {:ok, :missing} -> {:error, :key_not_found}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def rotate_key(key_ref, opts) do
    with :ok <- require_linux(opts),
         {:ok, %Key{status: :active} = key} <- find_payload(key_ref, opts) do
      rotated =
        build_key(
          key.id,
          key.version + 1,
          :active,
          KeyManager.random_key_material(),
          :rotated,
          opts
        )

      with :ok <- clear_payload(key.id, opts),
           :ok <- store_payload(rotated, opts) do
        {:ok, rotated}
      end
    else
      {:ok, :missing} -> {:error, :key_not_found}
      {:ok, %Key{status: :retired}} -> {:error, :key_retired}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def retire_key(key_ref, opts) do
    with :ok <- require_linux(opts),
         {:ok, %Key{} = key} <- find_payload(key_ref, opts),
         :ok <- clear_payload(key_ref, opts) do
      {:ok, %{key | status: :retired, retired_at: utc_now()}}
    else
      {:ok, :missing} -> {:error, :key_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp find_payload(key_ref, opts) do
    args = ["lookup" | attribute_args(key_ref, opts)]

    case run_secret_tool(args, nil, opts) do
      {:ok, stdout} ->
        stdout
        |> String.trim_trailing()
        |> decode_payload()

      {:error, %{status: status}} when status in [1, 2] ->
        {:ok, :missing}

      {:error, _reason} = error ->
        error
    end
  end

  defp store_payload(%Key{} = key, opts) do
    args =
      ["store", "--label", label(key.id, opts) | attribute_args(key.id, opts)]

    case run_secret_tool(args, encode_payload(key), opts) do
      {:ok, _stdout} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp clear_payload(key_ref, opts) do
    args = ["clear" | attribute_args(key_ref, opts)]

    case run_secret_tool(args, nil, opts) do
      {:ok, _stdout} -> :ok
      {:error, %{status: status}} when status in [1, 2] -> {:error, :key_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp encode_payload(%Key{} = key) do
    %{
      "schema_version" => @schema_version,
      "id" => key.id,
      "status" => Atom.to_string(key.status),
      "version" => key.version,
      "key_material" => "base64:" <> Base.encode64(key.material.bytes),
      "created_at" => encode_datetime(key.created_at),
      "rotated_at" => encode_datetime(key.rotated_at),
      "retired_at" => encode_datetime(key.retired_at),
      "metadata" => key.metadata
    }
    |> Jason.encode!()
  end

  defp decode_payload(payload) do
    with {:ok, decoded} <- Jason.decode(payload),
         %{
           "schema_version" => @schema_version,
           "id" => id,
           "status" => status,
           "version" => version,
           "key_material" => "base64:" <> encoded
         } <- decoded,
         {:ok, bytes} <- Base.decode64(encoded),
         {:ok, material} <- KeyMaterial.new(bytes),
         {:ok, status} <- decode_status(status) do
      {:ok,
       %Key{
         id: id,
         backend: :linux_secret_service,
         status: status,
         version: version,
         material: material,
         created_at: decode_datetime(decoded["created_at"]),
         rotated_at: decode_datetime(decoded["rotated_at"]),
         retired_at: decode_datetime(decoded["retired_at"]),
         metadata: decoded["metadata"] || %{}
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_secret_service_payload}
    end
  end

  defp build_key(key_id, version, status, bytes, lifecycle, opts) do
    {:ok, material} = KeyMaterial.new(bytes)
    now = utc_now()

    %Key{
      id: key_id,
      backend: :linux_secret_service,
      status: status,
      version: version,
      material: material,
      created_at: now,
      rotated_at: if(lifecycle == :rotated, do: now),
      metadata: %{"service" => service(opts), "storage" => "secret_service"}
    }
  end

  defp run_secret_tool(args, stdin, opts) do
    runner = Keyword.get(opts, :runner, &default_runner/3)

    case runner.(args, stdin, opts) do
      {stdout, 0} when is_binary(stdout) ->
        {:ok, stdout}

      {stdout, status} when is_binary(stdout) and is_integer(status) ->
        {:error, %{status: status, command: "secret-tool", message: redact_output(stdout)}}

      {:ok, stdout} when is_binary(stdout) ->
        {:ok, stdout}

      {:error, _reason} = error ->
        error
    end
  end

  defp default_runner(args, stdin, opts) do
    port =
      Port.open(
        {:spawn_executable, secret_tool_cmd(opts)},
        [:binary, :exit_status, :stderr_to_stdout, {:args, args}]
      )

    if is_binary(stdin) do
      true = Port.command(port, stdin <> "\n")
    end

    collect_port(port, [], Keyword.get(opts, :timeout_ms, 30_000))
  rescue
    error ->
      {:error, {:secret_tool_failed_to_start, Exception.message(error)}}
  end

  defp collect_port(port, chunks, timeout_ms) do
    receive do
      {^port, {:data, data}} ->
        collect_port(port, [data | chunks], timeout_ms)

      {^port, {:exit_status, status}} ->
        {chunks |> Enum.reverse() |> IO.iodata_to_binary(), status}
    after
      timeout_ms ->
        Port.close(port)
        {"secret-tool command timed out", 1}
    end
  end

  defp require_linux(opts) do
    case Keyword.get(opts, :platform, :os.type()) do
      {:unix, :linux} -> :ok
      :linux -> :ok
      _other -> {:error, :unsupported_key_backend_platform}
    end
  end

  defp key_id(opts), do: Keyword.get(opts, :id, "twelvgaige-store")
  defp service(opts), do: Keyword.get(opts, :service, @default_service)
  defp label(key_id, opts), do: Keyword.get(opts, :label, "Twelvgaige #{key_id}")
  defp secret_tool_cmd(opts), do: Keyword.get(opts, :secret_tool_cmd, @default_secret_tool_cmd)

  defp attribute_args(key_id, opts) do
    ["application", "twelvgaige", "service", service(opts), "id", key_id]
  end

  defp decode_status("active"), do: {:ok, :active}
  defp decode_status("retired"), do: {:ok, :retired}
  defp decode_status(_status), do: {:error, :invalid_key_status}

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(_datetime), do: nil

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp decode_datetime(_value), do: nil

  defp redact_output(output) do
    output
    |> String.replace(~r/"key_material"\s*:\s*"[^"]+"/, ~s("key_material":"[REDACTED]"))
    |> String.replace(~r/base64:[A-Za-z0-9+\/=]+/, "base64:[REDACTED]")
  end

  defp utc_now, do: DateTime.truncate(Twelvgaige.Clock.utc_now(), :second)
end
