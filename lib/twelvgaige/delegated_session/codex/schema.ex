defmodule Twelvgaige.DelegatedSession.Codex.Schema do
  @moduledoc "Pinned Codex App Server schema identity and stable-method validation."

  @cli_version "0.146.0"
  @protocol_version "2"
  @schema_digest "2d40289dea67cdef56c4de0b4f8caba4a4dcf4c1b73d16bb3711e88988e732f2"
  @bundle "codex_app_server_protocol.v2.schemas.json"

  @required_params %{
    "initialize" => ["clientInfo"],
    "thread/resume" => ["threadId"],
    "thread/fork" => ["threadId"],
    "turn/start" => ["threadId", "input"],
    "turn/steer" => ["threadId", "expectedTurnId", "input"],
    "turn/interrupt" => ["threadId", "turnId"]
  }

  @supported_requests MapSet.new([
                        "initialize",
                        "thread/start",
                        "thread/resume",
                        "thread/fork",
                        "thread/read",
                        "thread/archive",
                        "turn/start",
                        "turn/steer",
                        "turn/interrupt",
                        "model/list",
                        "modelProvider/capabilities/read",
                        "account/read"
                      ])

  def cli_version, do: @cli_version
  def protocol_version, do: @protocol_version
  def digest, do: @schema_digest

  def bundle_path do
    Application.app_dir(
      :twelvgaige,
      "priv/integrations/codex/#{@cli_version}/schema/#{@bundle}"
    )
  end

  def verify_bundle(path \\ bundle_path()) do
    with {:ok, contents} <- File.read(path),
         true <- sha256(contents) == @schema_digest,
         {:ok, %{"definitions" => definitions}} <- Jason.decode(contents),
         true <- is_map(definitions) do
      :ok
    else
      false -> {:error, :codex_schema_digest_mismatch}
      {:ok, _invalid} -> {:error, :codex_schema_bundle_invalid}
      {:error, reason} -> {:error, {:codex_schema_unreadable, reason}}
    end
  end

  def validate_request(method, params) when is_binary(method) and is_map(params) do
    cond do
      String.starts_with?(method, "experimental") ->
        {:error, :codex_experimental_method_denied}

      not MapSet.member?(@supported_requests, method) ->
        {:error, {:codex_unsupported_stable_method, method}}

      true ->
        validate_required(method, params)
    end
  end

  def validate_request(_method, _params), do: {:error, :codex_request_invalid}

  def validate_response("initialize", result) when is_map(result) do
    require_keys(result, ~w(userAgent codexHome platformFamily platformOs))
  end

  def validate_response("thread/start", result), do: validate_thread_response(result)
  def validate_response("thread/resume", result), do: validate_thread_response(result)
  def validate_response("thread/fork", result), do: validate_thread_response(result)

  def validate_response("turn/start", %{"turn" => %{"id" => id}}) when is_binary(id), do: :ok

  def validate_response(_method, result) when is_map(result), do: :ok
  def validate_response(_method, _result), do: {:error, :codex_response_schema_invalid}

  def validate_policy(method, params, :restricted)
      when method in ["thread/start", "thread/resume", "thread/fork"] do
    sandbox = value(params, "sandbox")
    approval = value(params, "approvalPolicy")

    cond do
      sandbox in [nil, "danger-full-access"] -> {:error, :codex_sandbox_policy_denied}
      approval in [nil, "never"] -> {:error, :codex_approval_policy_denied}
      true -> :ok
    end
  end

  def validate_policy("turn/start", params, :restricted) do
    approval = value(params, "approvalPolicy")
    sandbox = value(params, "sandboxPolicy")

    cond do
      approval in [nil, "never"] -> {:error, :codex_approval_policy_denied}
      is_nil(sandbox) -> {:error, :codex_sandbox_policy_required}
      danger_full_access?(sandbox) -> {:error, :codex_sandbox_policy_denied}
      true -> :ok
    end
  end

  def validate_policy(_method, _params, _profile), do: :ok

  defp validate_required(method, params) do
    require_keys(params, Map.get(@required_params, method, []))
  end

  defp validate_thread_response(%{"thread" => %{"id" => id}}) when is_binary(id), do: :ok
  defp validate_thread_response(_result), do: {:error, :codex_response_schema_invalid}

  defp require_keys(map, keys) do
    case Enum.reject(keys, &Map.has_key?(map, &1)) do
      [] -> :ok
      missing -> {:error, {:codex_schema_required_fields_missing, missing}}
    end
  end

  defp danger_full_access?("danger-full-access"), do: true
  defp danger_full_access?(%{"type" => "dangerFullAccess"}), do: true
  defp danger_full_access?(%{type: "dangerFullAccess"}), do: true
  defp danger_full_access?(_sandbox), do: false

  defp value(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(map, fn
          {candidate, value} when is_atom(candidate) ->
            if Atom.to_string(candidate) == key, do: {:found, value}

          _entry ->
            nil
        end)
        |> case do
          {:found, value} -> value
          nil -> nil
        end
    end
  end

  defp sha256(contents),
    do: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
end
