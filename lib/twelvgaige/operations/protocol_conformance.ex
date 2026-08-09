defmodule Twelvgaige.Operations.ProtocolConformance do
  @moduledoc "Checked-in stable-protocol resume and approval conformance fixtures."

  alias Twelvgaige.DelegatedSession.Codex.{Approval, EventCodec, Schema}

  def codex_fixture_path(root \\ File.cwd!()),
    do: Path.join(root, "qualification/fixtures/codex/app-server-conformance.json")

  def verify_codex(path \\ codex_fixture_path()) do
    with :ok <- Schema.verify_bundle(),
         {:ok, encoded} <- File.read(path),
         {:ok, fixture} <- Jason.decode(encoded),
         :ok <- verify_identity(fixture),
         :ok <- verify_exchanges(fixture["exchanges"]),
         :ok <- verify_exact_resume(fixture),
         :ok <- verify_approval(fixture["approval"]) do
      :ok
    else
      {:error, reason} -> {:error, {:codex_conformance_failed, reason}}
      _other -> {:error, :codex_conformance_failed}
    end
  end

  defp verify_identity(%{
         "schema_version" => 1,
         "driver" => "codex_app_server",
         "cli_version" => cli_version,
         "schema_digest" => digest
       }) do
    if cli_version == Schema.cli_version() and digest == Schema.digest(),
      do: :ok,
      else: {:error, :fixture_identity_mismatch}
  end

  defp verify_identity(_fixture), do: {:error, :fixture_identity_invalid}

  defp verify_exchanges(exchanges) when is_list(exchanges) and exchanges != [] do
    Enum.reduce_while(exchanges, :ok, fn exchange, :ok ->
      method = exchange["method"]

      with :ok <- Schema.validate_request(method, exchange["params"]),
           :ok <- Schema.validate_response(method, exchange["result"]) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {method, reason}}}
      end
    end)
  end

  defp verify_exchanges(_exchanges), do: {:error, :fixture_exchanges_invalid}

  defp verify_exact_resume(fixture) do
    expected = fixture["expected_resume_thread_id"]

    resume = Enum.find(fixture["exchanges"], &(&1["method"] == "thread/resume"))
    request_id = get_in(resume || %{}, ["params", "threadId"])
    result_id = get_in(resume || %{}, ["result", "thread", "id"])

    if is_binary(expected) and request_id == expected and result_id == expected,
      do: :ok,
      else: {:error, :exact_resume_identity_mismatch}
  end

  defp verify_approval(%{"method" => method, "params" => params}) do
    context = %{
      session_id: "fixture-session",
      thread_id: params["threadId"],
      turn_id: params["turnId"],
      emitted_at_ms: 1
    }

    signing_key = :crypto.hash(:sha256, "codex-conformance-fixture-key")
    now = ~U[2026-08-01 00:00:00Z]

    with {:ok, event} <- EventCodec.decode(method, params, context),
         true <- event.event_type == :approval_required,
         intent <-
           Approval.intent(
             %{
               id: params["itemId"],
               method: method,
               session_id: context.session_id,
               thread_id: context.thread_id,
               turn_id: context.turn_id,
               native_request_id: "fixture-rpc",
               params: params,
               expires_at: DateTime.add(now, 300, :second)
             },
             signing_key
           ),
         receipt <- Approval.receipt(intent, :accept, "fixture-operator", signing_key, now: now),
         :ok <- Approval.verify(intent, receipt, signing_key, now: now),
         "accept" <- Approval.native_decision(receipt.decision) do
      :ok
    else
      false -> {:error, :approval_event_not_normalized}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :approval_fixture_invalid}
    end
  end

  defp verify_approval(_approval), do: {:error, :approval_fixture_invalid}
end
