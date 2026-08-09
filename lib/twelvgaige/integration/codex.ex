defmodule Twelvgaige.Integration.Codex do
  @moduledoc "Pinned supported Codex integration descriptor and artifact verification."

  alias Twelvgaige.DelegatedSession.Codex.Schema
  alias Twelvgaige.Integration.Descriptor

  @artifact_digest "ae1d3ffe6d48aec6a4dc3f50e7eb8e0d11962485a6a9406c5a7012139383da02"

  def descriptor do
    Descriptor.new(%{
      id: "codex-app-server-#{Schema.cli_version()}-darwin-arm64",
      kind: :delegated_agent,
      vendor: "OpenAI",
      product: "Codex App Server",
      adapter: Twelvgaige.DelegatedSession.Adapter.CodexAppServer,
      adapter_version: 1,
      artifact_path: "codex",
      artifact_version: Schema.cli_version(),
      artifact_digest: @artifact_digest,
      protocol_version: Schema.protocol_version(),
      schema_digest: Schema.digest(),
      support_status: :supported,
      catalog_revision: 1,
      capabilities: %{
        structured_protocol: true,
        exact_resume: true,
        fork: true,
        steering: true,
        native_approvals: true,
        native_subagents: true,
        external_sandbox: true,
        unified_exec_toggle: true,
        experimental_api: false,
        transport: :stdio
      },
      tested_platforms: ["darwin-arm64"],
      auth_modes: [:local_user, :brokered_service],
      endpoint_classes: [:provider, :approved_mcp]
    })
  end

  def verify_artifact(path) do
    with {:ok, contents} <- File.read(path),
         digest <- :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower),
         true <- digest == @artifact_digest do
      :ok
    else
      false -> {:error, :codex_artifact_digest_mismatch}
      {:error, reason} -> {:error, {:codex_artifact_unreadable, reason}}
    end
  end
end
