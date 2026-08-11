alias Twelvgaige.Manager.VerificationExecutor
alias Twelvgaige.Sandbox.Backend.{AppleContainer, Podman}

defmodule Twelvgaige.VerificationExecutorQualification do
  @image_reference "localhost/twelvgaige/worker:codex-0.146.0"
  @image_digest "sha256:c3edda97f103f9db0d61d0873589f4e08c093dae04030adc0c6b90deabc105c4"

  def run do
    root = Path.expand("..", __DIR__)
    data_root = data_root()
    runtime_root = Path.join(data_root, "qualification-verification")
    File.mkdir_p!(runtime_root)
    File.chmod!(runtime_root, 0o700)

    backends = [
      {:podman, Podman,
       [machine_name: System.get_env("TWELVGAIGE_PODMAN_MACHINE", "twelvgaige")]},
      {:apple_container, AppleContainer, []}
    ]

    Enum.each(backends, fn {name, backend, backend_opts} ->
      qualify!(root, runtime_root, name, backend, backend_opts)
    end)
  end

  defp qualify!(root, runtime_root, name, backend, backend_opts) do
    workspace =
      Path.join(runtime_root, "#{backend_slug(name)}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(workspace)
    File.chmod!(workspace, 0o700)
    File.write!(Path.join(workspace, "verification-input.txt"), "qualified\n")

    request = %{
      workspace_id: "ws_live_verification_#{backend_slug(name)}",
      source_path: workspace,
      workspace_copy: true,
      network_mode: :none,
      credential_lease_id: nil,
      provider_environment: false,
      environment_names: [],
      commands: [
        ["/bin/sh", "-c", "test \"$(cat verification-input.txt)\" = qualified"],
        [
          "/bin/sh",
          "-c",
          "! env | grep -E '^(OPENAI|CODEX|AWS|GITHUB|HTTP_PROXY|HTTPS_PROXY)='"
        ],
        ["/bin/sh", "-c", "! grep -qE '^[[:space:]]*eth[0-9]+:' /proc/net/dev"]
      ],
      timeout_ms: 120_000,
      request_digest: request_digest(name)
    }

    opts = [
      backend: backend,
      image_reference: @image_reference,
      image_digest: @image_digest,
      allowed_roots: [runtime_root],
      backend_opts: backend_opts,
      limits: %{cpu: 1, memory_bytes: 1_073_741_824, pids: 128},
      policy_revision: "verification-live-v1"
    ]

    result = VerificationExecutor.execute(request, opts)
    File.rm_rf!(workspace)
    refute_managed_source!(workspace, runtime_root)

    evidence = evidence!(name, result)
    destination = evidence_path(root, name)
    File.mkdir_p!(Path.dirname(destination))
    File.write!(destination, Jason.encode_to_iodata!(evidence, pretty: true))
    IO.puts("Independent verification passed for #{name}; evidence: #{destination}")
  end

  defp evidence!(name, {:ok, evidence}) do
    command_evidence_complete =
      length(evidence.commands) == 3 and Enum.all?(evidence.commands, &(&1.exit_status == 0))

    if evidence.network_mode != :none or evidence.credentials_present != false or
         evidence.provider_environment_present != false or evidence.workspace_copy != true or
         not command_evidence_complete do
      raise "independent verification evidence failed closed for #{name}: #{inspect(evidence)}"
    end

    %{
      schema_version: 1,
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second),
      result: "pass",
      backend: name,
      image: %{reference: @image_reference, digest: @image_digest},
      executor: json_safe(evidence),
      security: %{
        copy_snapshot: "pass",
        network_none: "pass",
        credential_free: "pass",
        provider_environment_absent: "pass",
        command_evidence_complete: "pass",
        cleanup_complete: "pass"
      }
    }
  end

  defp evidence!(name, {:error, reason}),
    do: raise("independent verification failed for #{name}: #{inspect(reason)}")

  defp refute_managed_source!(workspace, runtime_root) do
    unless String.starts_with?(workspace, runtime_root <> "/") and not File.exists?(workspace) do
      raise "verification fixture cleanup could not be proven"
    end
  end

  defp evidence_path(root, :podman),
    do: Path.join(root, "qualification/evidence/verification/podman-live-qualification.json")

  defp evidence_path(root, :apple_container),
    do:
      Path.join(
        root,
        "qualification/evidence/verification/apple-container-live-qualification.json"
      )

  defp request_digest(name) do
    digest = :crypto.hash(:sha256, "verification-live-v1:#{name}")
    "sha256:" <> Base.encode16(digest, case: :lower)
  end

  defp data_root do
    System.get_env("TWELVGAIGE_DATA_ROOT") ||
      Path.join([System.user_home!(), "Library", "Application Support", "Twelvgaige"])
  end

  defp backend_slug(name), do: name |> Atom.to_string() |> String.replace("_", "-")

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%_{} = value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(value) when is_map(value),
    do: Map.new(value, fn {key, child} -> {key, json_safe(child)} end)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when value in [true, false, nil], do: value
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value
end

Twelvgaige.VerificationExecutorQualification.run()
