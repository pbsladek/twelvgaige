defmodule Twelvgaige.DelegatedSession.Codex.SchemaTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.DelegatedSession.Codex.{AuthProfile, Schema}

  test "the packaged stable schema has its pinned identity" do
    assert :ok = Schema.verify_bundle()
    assert Schema.cli_version() == "0.146.0"
    assert Schema.protocol_version() == "2"
    assert byte_size(Schema.digest()) == 64
  end

  test "stable lifecycle methods require exact fields and experimental methods are denied" do
    assert :ok =
             Schema.validate_request("turn/interrupt", %{
               "threadId" => "thread",
               "turnId" => "turn"
             })

    assert {:error, {:codex_schema_required_fields_missing, ["turnId"]}} =
             Schema.validate_request("turn/interrupt", %{"threadId" => "thread"})

    assert {:error, :codex_experimental_method_denied} =
             Schema.validate_request("experimentalFeature/list", %{})

    assert {:error, {:codex_unsupported_stable_method, "unknown/read"}} =
             Schema.validate_request("unknown/read", %{})

    assert {:error, :codex_request_invalid} = Schema.validate_request(:turn_start, [])
  end

  test "response validation and turn policy reject malformed or unbounded requests" do
    assert :ok =
             Schema.validate_response("initialize", %{
               "userAgent" => "codex",
               "codexHome" => "/tmp",
               "platformFamily" => "unix",
               "platformOs" => "linux"
             })

    assert {:error, {:codex_schema_required_fields_missing, ["platformOs"]}} =
             Schema.validate_response("initialize", %{
               "userAgent" => "codex",
               "codexHome" => "/tmp",
               "platformFamily" => "unix"
             })

    assert :ok = Schema.validate_response("thread/start", %{"thread" => %{"id" => "thread"}})

    assert {:error, :codex_response_schema_invalid} =
             Schema.validate_response("thread/start", %{})

    assert :ok = Schema.validate_response("turn/start", %{"turn" => %{"id" => "turn"}})
    assert :ok = Schema.validate_response("account/read", %{})
    assert {:error, :codex_response_schema_invalid} = Schema.validate_response("account/read", [])

    assert {:error, :codex_approval_policy_denied} =
             Schema.validate_policy("turn/start", %{"sandboxPolicy" => %{}}, :restricted)

    assert {:error, :codex_sandbox_policy_required} =
             Schema.validate_policy(
               "turn/start",
               %{"approvalPolicy" => "on-request"},
               :restricted
             )

    for sandbox <- [
          "danger-full-access",
          %{"type" => "dangerFullAccess"},
          %{type: "dangerFullAccess"}
        ] do
      assert {:error, :codex_sandbox_policy_denied} =
               Schema.validate_policy(
                 "turn/start",
                 %{"approvalPolicy" => "on-request", "sandboxPolicy" => sandbox},
                 :restricted
               )
    end

    assert :ok =
             Schema.validate_policy(
               "turn/start",
               %{
                 "approvalPolicy" => "on-request",
                 "sandboxPolicy" => %{"type" => "workspaceWrite"}
               },
               :restricted
             )

    assert :ok = Schema.validate_policy("account/read", %{}, :unrestricted)
  end

  test "schema bundle verification reports missing and drifted files" do
    path = Path.join(System.tmp_dir!(), "codex-schema-#{System.unique_integer([:positive])}.json")
    File.write!(path, ~s({"definitions":{}}))
    on_exit(fn -> File.rm(path) end)

    assert {:error, :codex_schema_digest_mismatch} = Schema.verify_bundle(path)

    assert {:error, {:codex_schema_unreadable, :enoent}} =
             Schema.verify_bundle(path <> ".missing")
  end

  test "restricted profiles require an inner sandbox and approval boundary" do
    assert {:error, :codex_sandbox_policy_denied} =
             Schema.validate_policy(
               "thread/start",
               %{"sandbox" => "danger-full-access", "approvalPolicy" => "on-request"},
               :restricted
             )

    assert {:error, :codex_approval_policy_denied} =
             Schema.validate_policy(
               "thread/start",
               %{"sandbox" => "workspace-write", "approvalPolicy" => "never"},
               :restricted
             )

    assert :ok =
             Schema.validate_policy(
               "thread/start",
               %{"sandbox" => "workspace-write", "approvalPolicy" => "on-request"},
               :restricted
             )
  end

  test "local account state is interactive-only while unattended auth is brokered" do
    local =
      AuthProfile.new(%{
        id: "local",
        type: :local_user,
        revision: 1,
        codex_home: "/isolated/codex-home"
      })

    assert {:error, :local_login_unattended_denied} =
             AuthProfile.validate(local, %{mode: :unattended})

    assert :ok = AuthProfile.validate(local, %{mode: :interactive})

    service =
      AuthProfile.new(%{
        id: "service",
        type: :brokered_service,
        revision: 1,
        credential_lease_id: "lease",
        broker_endpoint: "https://broker.invalid"
      })

    assert :ok = AuthProfile.validate(service, %{mode: :unattended})
    assert AuthProfile.runtime_environment(service) == []
  end
end
