defmodule Twelvgaige.Manager.VerificationSandbox do
  @moduledoc "Contract for credential-free verification in a fresh sandbox workspace copy."

  alias Twelvgaige.Workspace.Canonical

  @forbidden_environment_fragments ~w(KEY TOKEN SECRET CREDENTIAL AUTH PROXY AWS GITHUB OPENAI CODEX)

  def verify(workspace, commands, opts) when is_list(commands) do
    with :ok <- valid_commands(commands),
         executor when is_function(executor, 1) <- Keyword.get(opts, :verification_executor),
         {:ok, request} <- request(workspace, commands, opts),
         {:ok, evidence} <- executor.(request),
         :ok <- validate_evidence(evidence, request) do
      {:ok,
       %{
         status: :passed,
         request_digest: request.request_digest,
         backend: value(evidence, :backend),
         commands: value(evidence, :commands),
         started_at: value(evidence, :started_at),
         finished_at: value(evidence, :finished_at)
       }}
    else
      nil -> {:error, :verification_executor_unavailable}
      {:error, _reason} = error -> error
      _invalid -> {:error, :verification_sandbox_evidence_invalid}
    end
  end

  def verify(_workspace, _commands, _opts), do: {:error, :verification_commands_invalid}

  defp request(workspace, commands, opts) do
    attrs = %{
      "schema_version" => 1,
      "workspace_id" => workspace.id,
      "source_path" => Canonical.path(workspace.path),
      "workspace_copy" => true,
      "network_mode" => "none",
      "credential_lease_id" => nil,
      "provider_environment" => false,
      "environment_names" => Keyword.get(opts, :verification_environment_names, []),
      "commands" => commands,
      "timeout_ms" => Keyword.get(opts, :verification_timeout_ms, 900_000)
    }

    with :ok <- safe_environment(attrs["environment_names"]),
         {:ok, digest} <- Canonical.digest("verification-sandbox-request", 1, attrs) do
      {:ok,
       %{
         schema_version: 1,
         workspace_id: workspace.id,
         source_path: workspace.path,
         workspace_copy: true,
         network_mode: :none,
         credential_lease_id: nil,
         provider_environment: false,
         environment_names: attrs["environment_names"],
         commands: commands,
         timeout_ms: attrs["timeout_ms"],
         request_digest: digest
       }}
    end
  end

  defp validate_evidence(evidence, request) when is_map(evidence) do
    command_results = value(evidence, :commands, [])

    cond do
      value(evidence, :request_digest) != request.request_digest ->
        {:error, :verification_request_digest_mismatch}

      value(evidence, :network_mode) not in [:none, "none"] ->
        {:error, :verification_network_boundary_failed}

      value(evidence, :credentials_present) != false ->
        {:error, :verification_credentials_present}

      value(evidence, :provider_environment_present) != false ->
        {:error, :verification_provider_environment_present}

      value(evidence, :workspace_copy) != true ->
        {:error, :verification_workspace_not_independent}

      not is_list(command_results) or length(command_results) != length(request.commands) ->
        {:error, :verification_command_evidence_incomplete}

      not Enum.all?(command_results, &(value(&1, :exit_status) == 0)) ->
        {:error, {:verification_commands_failed, command_results}}

      true ->
        :ok
    end
  end

  defp validate_evidence(_evidence, _request),
    do: {:error, :verification_sandbox_evidence_invalid}

  defp valid_commands([]), do: :ok

  defp valid_commands(commands) do
    if Enum.all?(commands, fn command ->
         is_list(command) and command != [] and Enum.all?(command, &valid_argument?/1)
       end) do
      :ok
    else
      {:error, :verification_commands_invalid}
    end
  end

  defp valid_argument?(argument),
    do: is_binary(argument) and argument != "" and not String.contains?(argument, <<0>>)

  defp safe_environment(names) when is_list(names) do
    unsafe? =
      Enum.any?(names, fn name ->
        not is_binary(name) or
          Enum.any?(@forbidden_environment_fragments, &String.contains?(String.upcase(name), &1))
      end)

    if unsafe?, do: {:error, :verification_environment_unsafe}, else: :ok
  end

  defp safe_environment(_names), do: {:error, :verification_environment_unsafe}

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
