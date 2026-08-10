defmodule Twelvgaige.Manager.SessionRetry do
  @moduledoc "Creates a bounded retry using the original session's exact authority."

  alias Twelvgaige.Manager.SessionStart
  alias Twelvgaige.Operations.SessionControl

  def retry(session_id, attrs \\ %{}, opts \\ []) do
    repair? = value(attrs, "repair", false) == true
    operations = Keyword.fetch!(opts, :session_control)

    case SessionControl.reserve_retry(session_id, control_opts(operations, repair?, opts)) do
      {:ok, original} -> start_retry(original, session_id, repair?, operations, opts)
      {:error, _reason} = error -> error
    end
  end

  defp start_retry(original, session_id, repair?, operations, opts) do
    request = retry_request(original.start_request, original, repair?)
    starter = Keyword.get(opts, :start_fun, &SessionStart.start/2)

    start_opts =
      Keyword.merge(opts,
        server: Keyword.get(opts, :server),
        session_control: operations,
        require_inventory?: true,
        retry_of_session_id: session_id,
        retry_mode: if(repair?, do: :repair, else: :retry)
      )

    case starter.(request, start_opts) do
      {:ok, result} ->
        {:ok,
         Map.merge(result, %{
           retry_of_session_id: session_id,
           retry_mode: if(repair?, do: :repair, else: :retry)
         })}

      {:error, _reason} = error ->
        _ = SessionControl.release_retry(session_id, control_opts(operations, repair?, opts))
        error
    end
  end

  defp control_opts(operations, repair?, opts) do
    [server: operations, repair?: repair?]
    |> maybe_put(:uid, Keyword.get(opts, :uid))
    |> maybe_put(:username, Keyword.get(opts, :username))
  end

  defp retry_request(request, original, true) do
    evidence =
      Map.get(original, :error) || Map.get(original, :exit_reason) ||
        "the prior session did not complete successfully"

    evidence = if is_binary(evidence), do: evidence, else: inspect(evidence)

    Map.update!(request, "task", fn objective ->
      "Repair the prior attempt. Preserve its authority boundary. First inspect existing evidence, then address only the failure and rerun verification.\n\nPrior failure: #{evidence}\n\nOriginal objective:\n#{objective}"
    end)
  end

  defp retry_request(request, _original, false), do: request

  defp value(map, key, default),
    do: Map.get(map, key, Map.get(map, String.to_existing_atom(key), default))

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
