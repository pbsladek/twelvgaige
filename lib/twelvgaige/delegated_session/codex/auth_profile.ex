defmodule Twelvgaige.DelegatedSession.Codex.AuthProfile do
  @moduledoc "Admission rules for isolated interactive and brokered Codex authentication."

  @types [:local_user, :brokered_service]

  @enforce_keys [:id, :type, :revision]
  defstruct [:id, :type, :revision, :codex_home, :credential_lease_id, :broker_endpoint]

  def new(attrs) do
    profile = struct!(__MODULE__, normalize_attrs(attrs))
    if profile.type not in @types, do: raise(ArgumentError, "invalid Codex auth profile")
    profile
  end

  def validate(%__MODULE__{type: :local_user, codex_home: home}, context) do
    cond do
      Map.get(context, :mode) != :interactive -> {:error, :local_login_unattended_denied}
      not is_binary(home) or Path.type(home) != :absolute -> {:error, :codex_home_invalid}
      true -> :ok
    end
  end

  def validate(
        %__MODULE__{
          type: :brokered_service,
          credential_lease_id: lease_id,
          broker_endpoint: endpoint
        },
        _context
      ) do
    if present?(lease_id) and present?(endpoint),
      do: :ok,
      else: {:error, :brokered_auth_incomplete}
  end

  def runtime_environment(%__MODULE__{type: :local_user, codex_home: home}),
    do: [{"CODEX_HOME", home}]

  def runtime_environment(%__MODULE__{type: :brokered_service}), do: []

  defp normalize_attrs(attrs) do
    known = %{
      "id" => :id,
      "type" => :type,
      "revision" => :revision,
      "codex_home" => :codex_home,
      "credential_lease_id" => :credential_lease_id,
      "broker_endpoint" => :broker_endpoint
    }

    attrs
    |> Map.new()
    |> Enum.map(fn
      {key, value} when is_binary(key) -> {Map.get(known, key, key), normalize_value(key, value)}
      pair -> pair
    end)
    |> Map.new()
  end

  defp normalize_value("type", "local_user"), do: :local_user
  defp normalize_value("type", "brokered_service"), do: :brokered_service
  defp normalize_value(_key, value), do: value

  defp present?(value), do: is_binary(value) and value != ""
end
