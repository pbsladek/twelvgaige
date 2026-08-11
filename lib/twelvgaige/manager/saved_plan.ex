defmodule Twelvgaige.Manager.SavedPlan do
  @moduledoc """
  Digest-bound, owner-only handoff between `session plan` and `session start`.

  The document stores the fully resolved request plus the source and capability
  evidence observed by planning. The daemon verifies the document again before
  allocating a session and reports the first drifted field.
  """

  alias Twelvgaige.Workspace.Canonical

  @schema "twelvgaige.session-plan"
  @schema_version 1
  @digest_contract "session-plan"
  @max_bytes 1_048_576

  @resolution_fields ~w(
    repository base_ref base_commit source_mode source_state_token sandbox sandbox_profile
    network allowed_paths write capabilities configuration_provenance
  )

  @spec build(map(), map()) :: {:ok, map()} | {:error, term()}
  def build(request, planned) when is_map(request) and is_map(planned) do
    payload = %{
      "schema" => @schema,
      "schema_version" => @schema_version,
      "request" => request |> stringify_keys() |> Map.delete("saved_plan"),
      "resolution" => Map.new(@resolution_fields, fn field -> {field, value(planned, field)} end)
    }

    with {:ok, digest} <- digest(payload) do
      {:ok, Map.put(payload, "plan_digest", digest)}
    end
  end

  @spec verify(term()) :: {:ok, map()} | {:error, term()}
  def verify(%{} = plan) do
    plan = stringify_keys(plan)

    with @schema <- plan["schema"],
         @schema_version <- plan["schema_version"],
         request when is_map(request) <- plan["request"],
         resolution when is_map(resolution) <- plan["resolution"],
         true <- Enum.all?(@resolution_fields, &Map.has_key?(resolution, &1)),
         expected when is_binary(expected) <- plan["plan_digest"],
         {:ok, actual} <- digest(Map.delete(plan, "plan_digest")),
         true <- secure_equal?(expected, actual) do
      {:ok, plan}
    else
      false -> {:error, :session_saved_plan_digest_mismatch}
      {:error, _reason} = error -> error
      _invalid -> {:error, :session_saved_plan_invalid}
    end
  end

  def verify(_plan), do: {:error, :session_saved_plan_invalid}

  @spec optional(term()) :: {:ok, map() | nil} | {:error, term()}
  def optional(nil), do: {:ok, nil}
  def optional(plan), do: verify(plan)

  @spec validate_request(map() | nil, map()) :: :ok | {:error, term()}
  def validate_request(nil, _request), do: :ok

  def validate_request(plan, request) do
    expected = plan["request"]
    actual = request |> stringify_keys() |> Map.delete("saved_plan")
    compare_maps(expected, actual, "request")
  end

  @spec validate_resolution(map() | nil, map()) :: :ok | {:error, term()}
  def validate_resolution(nil, _resolution), do: :ok

  def validate_resolution(plan, resolution) do
    actual = stringify_keys(resolution)

    Enum.reduce_while(@resolution_fields, :ok, fn field, :ok ->
      expected = plan["resolution"][field]
      observed = actual[field]

      if expected == observed,
        do: {:cont, :ok},
        else: {:halt, {:error, {:session_saved_plan_drift, field}}}
    end)
  end

  @spec load(Path.t()) :: {:ok, map()} | {:error, term()}
  def load(path) when is_binary(path) and path != "" do
    path = Path.expand(path)

    with {:ok, stat} <- File.lstat(path),
         :ok <- validate_file(stat),
         {:ok, contents} <- File.read(path),
         true <- byte_size(contents) <= @max_bytes,
         {:ok, decoded} <- Jason.decode(contents),
         {:ok, plan} <- verify(decoded) do
      {:ok, plan}
    else
      false -> {:error, :session_saved_plan_too_large}
      {:error, :enoent} -> {:error, :session_saved_plan_not_found}
      {:error, %Jason.DecodeError{}} -> {:error, :session_saved_plan_invalid_json}
      {:error, _reason} = error -> error
    end
  end

  def load(_path), do: {:error, :session_saved_plan_path_invalid}

  @spec save(Path.t(), map()) :: :ok | {:error, term()}
  def save(path, plan) when is_binary(path) and path != "" do
    path = Path.expand(path)
    parent = Path.dirname(path)
    staging = Path.join(parent, ".#{Path.basename(path)}.tmp-#{unique_suffix()}")

    with {:ok, verified} <- verify(plan) do
      result = write_exclusive(parent, staging, path, verified)
      if match?({:error, _reason}, result), do: File.rm(staging)
      result
    end
  end

  def save(_path, _plan), do: {:error, :session_saved_plan_path_invalid}

  @spec digest(map()) :: {:ok, String.t()} | {:error, term()}
  def digest(payload), do: Canonical.digest(@digest_contract, @schema_version, payload)

  defp write_staging(device, staging, plan) do
    try do
      with :ok <- File.chmod(staging, 0o600),
           :ok <- IO.binwrite(device, [Jason.encode_to_iodata!(plan, pretty: true), "\n"]),
           :ok <- :file.sync(device) do
        :ok
      end
    after
      _ = File.close(device)
    end
  end

  defp write_exclusive(parent, staging, path, plan) do
    with :ok <- File.mkdir_p(parent),
         {:ok, device} <- File.open(staging, [:write, :binary, :exclusive]),
         :ok <- write_staging(device, staging, plan),
         :ok <- File.ln(staging, path),
         :ok <- File.rm(staging) do
      :ok
    else
      {:error, :eexist} -> {:error, :session_saved_plan_destination_exists}
      {:error, reason} -> {:error, {:session_saved_plan_write_failed, reason}}
    end
  end

  defp validate_file(%{type: :regular, size: size, mode: mode})
       when size <= @max_bytes do
    if Bitwise.band(mode, 0o077) == 0,
      do: :ok,
      else: {:error, :session_saved_plan_permissions_invalid}
  end

  defp validate_file(%{size: size}) when size > @max_bytes,
    do: {:error, :session_saved_plan_too_large}

  defp validate_file(_stat), do: {:error, :session_saved_plan_type_invalid}

  defp compare_maps(expected, actual, prefix) do
    fields = (Map.keys(expected) ++ Map.keys(actual)) |> Enum.uniq() |> Enum.sort()

    Enum.reduce_while(fields, :ok, fn field, :ok ->
      if expected[field] == actual[field],
        do: {:cont, :ok},
        else: {:halt, {:error, {:session_saved_plan_drift, "#{prefix}.#{field}"}}}
    end)
  end

  defp stringify_keys(%{} = map),
    do: Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)

  defp stringify_keys(value) when is_atom(value) and value not in [true, false, nil],
    do: Atom.to_string(value)

  defp stringify_keys(value), do: value

  defp secure_equal?(left, right) when byte_size(left) == byte_size(right),
    do: :crypto.hash_equals(left, right)

  defp secure_equal?(_left, _right), do: false

  defp value(map, key) when is_binary(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, String.to_existing_atom(key))
    end
  end

  defp value(map, key), do: Map.get(map, key, Map.get(map, to_string(key)))

  defp unique_suffix do
    12
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
