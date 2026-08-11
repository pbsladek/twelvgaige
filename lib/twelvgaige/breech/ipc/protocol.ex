defmodule Twelvgaige.Breech.IPC.Protocol do
  @moduledoc """
  Length-prefixed JSON command protocol for Breech IPC.

  The transport is intentionally small and protocol-first. Unix sockets, named
  pipes, and loopback TCP can all carry the same envelope.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Security

  @api_version 1

  @spec api_version() :: pos_integer()
  def api_version, do: @api_version

  @spec request(String.t(), map(), keyword()) :: map()
  def request(command, body, opts \\ []) when is_binary(command) and is_map(body) do
    %{
      "request_id" => Keyword.get(opts, :request_id) || Twelvgaige.ID.new(:event),
      "api_version" => Keyword.get(opts, :api_version, @api_version),
      "command" => command,
      "body" => body
    }
    |> maybe_put_auth(Keyword.get(opts, :token))
  end

  @spec ok(map(), term()) :: map()
  def ok(request, body) do
    %{
      "request_id" => request_id(request),
      "ok" => true,
      "body" => body
    }
  end

  @spec error(map(), term()) :: map()
  def error(request, %Error{} = error) do
    %{
      "request_id" => request_id(request),
      "ok" => false,
      "error" => Error.to_map(error)
    }
  end

  def error(request, :daemon_auth_failed) do
    error(
      request,
      Error.new(:policy_error, :daemon_auth_failed, "daemon authentication failed")
    )
  end

  def error(request, :daemon_version_mismatch) do
    error(
      request,
      Error.new(:policy_error, :daemon_version_mismatch, "daemon API version mismatch")
    )
  end

  def error(request, :not_found) do
    %{
      "request_id" => request_id(request),
      "ok" => false,
      "error" => %{"reason" => "not_found", "message" => "round not found"}
    }
  end

  def error(request, :workspace_set_not_found) do
    %{
      "request_id" => request_id(request),
      "ok" => false,
      "error" => %{"reason" => "workspace_set_not_found", "message" => "workspace set not found"}
    }
  end

  def error(request, reason) do
    %{
      "request_id" => request_id(request),
      "ok" => false,
      "error" => %{"reason" => "unknown", "message" => inspect(reason)}
    }
  end

  @spec encode(map()) :: iodata()
  def encode(envelope) when is_map(envelope), do: Jason.encode!(envelope)

  @spec decode(binary()) :: {:ok, map()} | {:error, term()}
  def decode(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _decoded} -> {:error, :invalid_envelope}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec valid_request?(map()) :: boolean()
  def valid_request?(request) do
    is_binary(Map.get(request, "request_id")) and
      Map.get(request, "api_version") == @api_version and
      is_binary(Map.get(request, "command")) and
      is_map(Map.get(request, "body"))
  end

  @spec authorized?(map(), String.t() | nil) :: boolean()
  def authorized?(_request, nil), do: true

  def authorized?(request, token) when is_binary(token) do
    Security.secure_equal?(get_in(request, ["auth", "bearer"]), token)
  end

  defp maybe_put_auth(request, nil), do: request

  defp maybe_put_auth(request, token) when is_binary(token) do
    Map.put(request, "auth", %{"bearer" => token})
  end

  defp request_id(%{"request_id" => request_id}) when is_binary(request_id), do: request_id
  defp request_id(_request), do: nil
end
