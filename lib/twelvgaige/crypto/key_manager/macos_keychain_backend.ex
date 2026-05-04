defmodule Twelvgaige.Crypto.KeyManager.MacOSKeychainBackend do
  @moduledoc """
  macOS Keychain backend using the system `security` command.

  This is a narrow command-wrapper integration. It stores a JSON password payload
  in a generic password item so the key version and timestamps can travel with
  the key material.
  """

  @behaviour Twelvgaige.Crypto.KeyManager

  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyManager
  alias Twelvgaige.Crypto.KeyMaterial

  @schema_version 1
  @default_service "twelvgaige.key"
  @default_security_cmd "/usr/bin/security"

  @impl true
  def create_key(opts) do
    with :ok <- require_macos(opts),
         key_id <- key_id(opts),
         {:ok, :missing} <- find_payload(key_id, opts),
         key <- build_key(key_id, 1, :active, KeyManager.random_key_material(), nil, opts),
         :ok <- write_payload(key, opts, update?: false) do
      {:ok, key}
    else
      {:ok, %Key{}} -> {:error, :key_already_exists}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def fetch_key(key_ref, opts) do
    with :ok <- require_macos(opts),
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
    with :ok <- require_macos(opts),
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

      :ok = write_payload(rotated, opts, update?: true)
      {:ok, rotated}
    else
      {:ok, :missing} -> {:error, :key_not_found}
      {:ok, %Key{status: :retired}} -> {:error, :key_retired}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def retire_key(key_ref, opts) do
    with :ok <- require_macos(opts),
         {:ok, %Key{} = key} <- find_payload(key_ref, opts),
         :ok <- delete_payload(key_ref, opts) do
      {:ok, %{key | status: :retired, retired_at: utc_now()}}
    else
      {:ok, :missing} -> {:error, :key_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp find_payload(key_ref, opts) do
    args =
      ["find-generic-password", "-a", key_ref, "-s", service(opts), "-w"] ++ keychain_args(opts)

    case run_security(args, opts) do
      {:ok, stdout} ->
        stdout
        |> String.trim_trailing()
        |> decode_payload()

      {:error, %{status: 44}} ->
        {:ok, :missing}

      {:error, %{status: 45}} ->
        {:ok, :missing}

      {:error, _reason} = error ->
        error
    end
  end

  defp write_payload(%Key{} = key, opts, update?: update?) do
    args =
      [
        "add-generic-password",
        "-a",
        key.id,
        "-s",
        service(opts),
        "-l",
        label(key.id, opts)
      ] ++
        if(update?, do: ["-U"], else: []) ++
        ["-w", encode_payload(key)] ++ keychain_args(opts)

    case run_security(args, opts) do
      {:ok, _stdout} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp delete_payload(key_ref, opts) do
    args = ["delete-generic-password", "-a", key_ref, "-s", service(opts)] ++ keychain_args(opts)

    case run_security(args, opts) do
      {:ok, _stdout} -> :ok
      {:error, %{status: status}} when status in [44, 45] -> {:error, :key_not_found}
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
         backend: :macos_keychain,
         status: status,
         version: version,
         material: material,
         created_at: decode_datetime(decoded["created_at"]),
         rotated_at: decode_datetime(decoded["rotated_at"]),
         metadata: decoded["metadata"] || %{}
       }}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_keychain_payload}
    end
  end

  defp decode_status("active"), do: {:ok, :active}
  defp decode_status("retired"), do: {:ok, :retired}
  defp decode_status(_status), do: {:error, :invalid_key_status}

  defp build_key(key_id, version, status, bytes, lifecycle, opts) do
    {:ok, material} = KeyMaterial.new(bytes)
    now = utc_now()

    %Key{
      id: key_id,
      backend: :macos_keychain,
      status: status,
      version: version,
      material: material,
      created_at: now,
      rotated_at: if(lifecycle == :rotated, do: now),
      metadata: %{"service" => service(opts)}
    }
  end

  defp run_security(args, opts) do
    runner = Keyword.get(opts, :runner, &default_runner/2)

    case runner.(args, opts) do
      {stdout, 0} when is_binary(stdout) ->
        {:ok, stdout}

      {stdout, status} when is_binary(stdout) and is_integer(status) ->
        {:error, %{status: status, command: "security", message: redact_security_output(stdout)}}

      {:ok, stdout} when is_binary(stdout) ->
        {:ok, stdout}

      {:error, _reason} = error ->
        error
    end
  end

  defp default_runner(args, opts) do
    System.cmd(security_cmd(opts), args, stderr_to_stdout: true)
  end

  defp require_macos(opts) do
    case Keyword.get(opts, :platform, :os.type()) do
      {:unix, :darwin} -> :ok
      :darwin -> :ok
      _other -> {:error, :unsupported_key_backend_platform}
    end
  end

  defp key_id(opts), do: Keyword.get(opts, :id, "twelvgaige-store")
  defp service(opts), do: Keyword.get(opts, :service, @default_service)
  defp label(key_id, opts), do: Keyword.get(opts, :label, "Twelvgaige #{key_id}")
  defp security_cmd(opts), do: Keyword.get(opts, :security_cmd, @default_security_cmd)

  defp keychain_args(opts) do
    case Keyword.get(opts, :keychain) do
      keychain when is_binary(keychain) and keychain != "" -> [keychain]
      _missing -> []
    end
  end

  defp encode_datetime(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp encode_datetime(_datetime), do: nil

  defp decode_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp decode_datetime(_value), do: nil

  defp redact_security_output(output) do
    output
    |> String.replace(~r/"key_material"\s*:\s*"[^"]+"/, ~s("key_material":"[REDACTED]"))
    |> String.replace(~r/base64:[A-Za-z0-9+\/=]+/, "base64:[REDACTED]")
  end

  defp utc_now, do: DateTime.truncate(Twelvgaige.Clock.utc_now(), :second)
end
