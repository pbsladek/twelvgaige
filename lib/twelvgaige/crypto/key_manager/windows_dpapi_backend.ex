defmodule Twelvgaige.Crypto.KeyManager.WindowsDPAPIBackend do
  @moduledoc """
  Windows user-scope DPAPI key backend.

  The backend stores a DPAPI-protected JSON key payload in a local file. DPAPI
  binds the protected payload to the current Windows user profile. Plaintext is
  passed to PowerShell over stdin, not argv.
  """

  @behaviour Twelvgaige.Crypto.KeyManager

  alias Twelvgaige.Crypto.Key
  alias Twelvgaige.Crypto.KeyManager
  alias Twelvgaige.Crypto.KeyMaterial
  alias Twelvgaige.Security.FileMode

  @schema_version 1
  @default_powershell_cmd "powershell.exe"

  @impl true
  def create_key(opts) do
    with :ok <- require_windows(opts),
         key_id <- key_id(opts),
         {:ok, path} <- key_path(key_id, opts),
         :ok <- ensure_new_key_path(path),
         key <- build_key(key_id, 1, :active, KeyManager.random_key_material(), nil, path),
         {:ok, protected} <- protect_key(key, opts),
         :ok <- write_blob(path, key_id, protected) do
      {:ok, key}
    end
  end

  @impl true
  def fetch_key(key_ref, opts) do
    with :ok <- require_windows(opts),
         {:ok, path} <- key_path(key_ref, opts),
         {:ok, key} <- read_key(path, opts),
         :ok <- match_key_ref(key, key_ref) do
      case key.status do
        :active -> {:ok, key}
        :retired -> {:error, :key_retired}
      end
    end
  end

  @impl true
  def rotate_key(key_ref, opts) do
    with :ok <- require_windows(opts),
         {:ok, path} <- key_path(key_ref, opts),
         {:ok, %Key{status: :active} = key} <- read_key(path, opts),
         :ok <- match_key_ref(key, key_ref) do
      rotated =
        build_key(
          key.id,
          key.version + 1,
          :active,
          KeyManager.random_key_material(),
          :rotated,
          path
        )

      with {:ok, protected} <- protect_key(rotated, opts),
           :ok <- write_blob(path, key.id, protected) do
        {:ok, rotated}
      end
    else
      {:ok, %Key{status: :retired}} -> {:error, :key_retired}
      {:error, _reason} = error -> error
    end
  end

  @impl true
  def retire_key(key_ref, opts) do
    with :ok <- require_windows(opts),
         {:ok, path} <- key_path(key_ref, opts),
         {:ok, key} <- read_key(path, opts),
         :ok <- match_key_ref(key, key_ref) do
      retired = %{key | status: :retired, retired_at: utc_now()}

      with {:ok, protected} <- protect_key(retired, opts),
           :ok <- write_blob(path, key.id, protected) do
        {:ok, retired}
      end
    end
  end

  defp read_key(path, opts) do
    with {:ok, protected} <- read_blob(path),
         {:ok, payload} <- unprotect(protected, opts),
         {:ok, decoded} <- Jason.decode(payload),
         {:ok, key} <- decode_key(decoded, path) do
      {:ok, key}
    else
      {:error, :enoent} -> {:error, :key_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_new_key_path(path) do
    if File.exists?(path) do
      {:error, :key_already_exists}
    else
      FileMode.ensure_private_parent_dir(path)
    end
  end

  defp read_blob(path) do
    with {:ok, contents} <- File.read(path),
         {:ok, decoded} <- Jason.decode(contents),
         %{
           "schema_version" => @schema_version,
           "protected_payload" => protected
         } <- decoded,
         true <- is_binary(protected) do
      {:ok, protected}
    else
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_dpapi_key_file}
    end
  end

  defp write_blob(path, key_id, protected) when is_binary(protected) do
    contents =
      %{
        "schema_version" => @schema_version,
        "id" => key_id,
        "backend" => "windows_dpapi",
        "protected_payload" => protected
      }
      |> Jason.encode!()

    with :ok <- FileMode.ensure_private_parent_dir(path),
         :ok <- File.write(path, contents, [:write]),
         :ok <- FileMode.chmod_if_supported(path, 0o600) do
      :ok
    end
  end

  defp protect_key(%Key{} = key, opts) do
    key
    |> encode_key()
    |> Jason.encode!()
    |> protect(opts)
  end

  defp protect(payload, opts), do: run_powershell(dpapi_protect_script(), payload, opts)
  defp unprotect(payload, opts), do: run_powershell(dpapi_unprotect_script(), payload, opts)

  defp run_powershell(script, stdin, opts) do
    args = ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", script]
    runner = Keyword.get(opts, :runner, &default_runner/3)

    case runner.(args, stdin, opts) do
      {stdout, 0} when is_binary(stdout) ->
        {:ok, String.trim(stdout)}

      {stdout, status} when is_binary(stdout) and is_integer(status) ->
        {:error, %{status: status, command: "powershell", message: redact_output(stdout)}}

      {:ok, stdout} when is_binary(stdout) ->
        {:ok, String.trim(stdout)}

      {:error, _reason} = error ->
        error
    end
  end

  defp default_runner(args, stdin, opts) do
    port =
      Port.open(
        {:spawn_executable, powershell_cmd(opts)},
        [:binary, :exit_status, :stderr_to_stdout, {:args, args}]
      )

    true = Port.command(port, stdin <> "\n")
    collect_port(port, [], Keyword.get(opts, :timeout_ms, 30_000))
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
        {"powershell command timed out", 1}
    end
  end

  defp dpapi_protect_script do
    """
    $ErrorActionPreference = 'Stop';
    Add-Type -AssemblyName System.Security;
    $inputText = [Console]::In.ReadLine();
    $bytes = [Text.Encoding]::UTF8.GetBytes($inputText);
    $protected = [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser);
    [Console]::Out.Write([Convert]::ToBase64String($protected));
    """
  end

  defp dpapi_unprotect_script do
    """
    $ErrorActionPreference = 'Stop';
    Add-Type -AssemblyName System.Security;
    $inputText = [Console]::In.ReadLine();
    $protected = [Convert]::FromBase64String($inputText.Trim());
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect($protected, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser);
    [Console]::Out.Write([Text.Encoding]::UTF8.GetString($bytes));
    """
  end

  defp encode_key(%Key{} = key) do
    %{
      "schema_version" => @schema_version,
      "id" => key.id,
      "backend" => "windows_dpapi",
      "status" => Atom.to_string(key.status),
      "version" => key.version,
      "key_material" => "base64:" <> Base.encode64(key.material.bytes),
      "created_at" => encode_datetime(key.created_at),
      "rotated_at" => encode_datetime(key.rotated_at),
      "retired_at" => encode_datetime(key.retired_at),
      "metadata" => key.metadata
    }
  end

  defp decode_key(
         %{
           "schema_version" => @schema_version,
           "id" => id,
           "status" => status,
           "version" => version,
           "key_material" => "base64:" <> encoded
         } = decoded,
         path
       )
       when is_binary(id) and is_integer(version) do
    with {:ok, bytes} <- Base.decode64(encoded),
         {:ok, material} <- KeyMaterial.new(bytes),
         {:ok, status} <- decode_status(status) do
      {:ok,
       %Key{
         id: id,
         backend: :windows_dpapi,
         status: status,
         version: version,
         material: material,
         created_at: decode_datetime(decoded["created_at"]),
         rotated_at: decode_datetime(decoded["rotated_at"]),
         retired_at: decode_datetime(decoded["retired_at"]),
         metadata: decoded["metadata"] || %{"storage" => "dpapi_file", "path" => path}
       }}
    end
  end

  defp decode_key(_decoded, _path), do: {:error, :invalid_dpapi_key_payload}

  defp build_key(key_id, version, status, bytes, lifecycle, path) do
    {:ok, material} = KeyMaterial.new(bytes)
    now = utc_now()

    %Key{
      id: key_id,
      backend: :windows_dpapi,
      status: status,
      version: version,
      material: material,
      created_at: now,
      rotated_at: if(lifecycle == :rotated, do: now),
      metadata: %{"storage" => "dpapi_file", "path" => path}
    }
  end

  defp match_key_ref(%Key{id: key_id}, key_id), do: :ok
  defp match_key_ref(%Key{}, _key_id), do: {:error, :key_not_found}

  defp decode_status("active"), do: {:ok, :active}
  defp decode_status("retired"), do: {:ok, :retired}
  defp decode_status(_status), do: {:error, :invalid_key_status}

  defp key_id(opts), do: Keyword.get(opts, :id, "twelvgaige-store")

  defp key_path(key_id, opts) do
    case Keyword.get(opts, :path) do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _missing -> {:ok, Path.join([windows_data_dir(opts), "keys", "#{key_id}.dpapi.json"])}
    end
  end

  defp windows_data_dir(opts) do
    cond do
      dir = Keyword.get(opts, :data_dir) ->
        dir

      local_app_data = env(opts, "LOCALAPPDATA") ->
        Path.join(local_app_data, "Twelvgaige")

      true ->
        Path.join([System.user_home!(), "AppData", "Local", "Twelvgaige"])
    end
  end

  defp require_windows(opts) do
    case Keyword.get(opts, :platform, :os.type()) do
      {:win32, _name} -> :ok
      :windows -> :ok
      _other -> {:error, :unsupported_key_backend_platform}
    end
  end

  defp powershell_cmd(opts), do: Keyword.get(opts, :powershell_cmd, @default_powershell_cmd)

  defp env(opts, name) do
    opts |> Keyword.get(:env, %{}) |> Map.get(name) || System.get_env(name)
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

  defp redact_output(output) do
    output
    |> String.replace(~r/"key_material"\s*:\s*"[^"]+"/, ~s("key_material":"[REDACTED]"))
    |> String.replace(~r/base64:[A-Za-z0-9+\/=]+/, "base64:[REDACTED]")
  end

  defp utc_now, do: DateTime.truncate(Twelvgaige.Clock.utc_now(), :second)
end
