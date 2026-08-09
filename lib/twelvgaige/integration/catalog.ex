defmodule Twelvgaige.Integration.Catalog do
  @moduledoc "Revisioned integration resolution and deterministic support-policy admission."

  alias Twelvgaige.Integration.Descriptor

  @spec resolve([Descriptor.t()], String.t(), keyword()) ::
          {:ok, Descriptor.t()} | {:error, term()}
  def resolve(descriptors, id, opts \\ []) do
    with {:ok, descriptor} <- fetch(descriptors, id),
         :ok <- admit_status(descriptor, opts),
         :ok <- require_capabilities(descriptor, Keyword.get(opts, :required_capabilities, [])),
         :ok <- require_platform(descriptor, Keyword.get(opts, :platform)) do
      {:ok, descriptor}
    end
  end

  defp fetch(descriptors, id) do
    case Enum.find(descriptors, &(&1.id == id)) do
      nil -> {:error, :integration_not_found}
      descriptor -> {:ok, descriptor}
    end
  end

  defp admit_status(%Descriptor{support_status: :supported, revoked_at: nil}, _opts), do: :ok

  defp admit_status(%Descriptor{support_status: :experimental, revoked_at: nil}, opts) do
    if Keyword.get(opts, :unattended?, true),
      do: {:error, :experimental_integration_unattended},
      else: :ok
  end

  defp admit_status(%Descriptor{support_status: :deprecated, revoked_at: nil}, opts) do
    if Keyword.get(opts, :resume?, false),
      do: :ok,
      else: {:error, :deprecated_integration_new_work}
  end

  defp admit_status(%Descriptor{support_status: status}, _opts)
       when status in [:blocked, :removed],
       do: {:error, {:integration_blocked, status}}

  defp admit_status(%Descriptor{revoked_at: revoked_at}, _opts) when not is_nil(revoked_at),
    do: {:error, :integration_revoked}

  defp require_capabilities(descriptor, required) do
    missing = Enum.reject(required, &capability?(descriptor.capabilities, &1))
    if missing == [], do: :ok, else: {:error, {:integration_capability_missing, missing}}
  end

  defp capability?(capabilities, key) do
    Map.get(capabilities, key, Map.get(capabilities, to_string(key), false)) == true
  end

  defp require_platform(_descriptor, nil), do: :ok

  defp require_platform(descriptor, platform) do
    if platform in descriptor.tested_platforms,
      do: :ok,
      else: {:error, {:integration_platform_unsupported, platform}}
  end
end
