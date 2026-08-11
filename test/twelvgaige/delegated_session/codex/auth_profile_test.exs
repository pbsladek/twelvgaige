defmodule Twelvgaige.DelegatedSession.Codex.AuthProfileTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.DelegatedSession.Codex.AuthProfile

  test "normalizes string-keyed local-user profiles and exposes only CODEX_HOME" do
    profile =
      AuthProfile.new(%{
        "id" => "interactive",
        "type" => "local_user",
        "revision" => 2,
        "codex_home" => "/private/session/codex-home"
      })

    assert profile.type == :local_user
    assert :ok = AuthProfile.validate(profile, %{mode: :interactive})

    assert AuthProfile.runtime_environment(profile) == [
             {"CODEX_HOME", "/private/session/codex-home"}
           ]
  end

  test "local login is interactive-only and requires an absolute Codex home" do
    for home <- [nil, "", "relative/codex-home"] do
      profile = AuthProfile.new(%{id: "local", type: :local_user, revision: 1, codex_home: home})

      assert {:error, :codex_home_invalid} =
               AuthProfile.validate(profile, %{mode: :interactive})
    end

    profile =
      AuthProfile.new(%{
        id: "local",
        type: :local_user,
        revision: 1,
        codex_home: "/private/codex-home"
      })

    assert {:error, :local_login_unattended_denied} =
             AuthProfile.validate(profile, %{mode: :unattended})

    assert {:error, :local_login_unattended_denied} = AuthProfile.validate(profile, %{})
  end

  test "brokered service profiles require both opaque lease and endpoint identifiers" do
    valid =
      AuthProfile.new(%{
        "id" => "service",
        "type" => "brokered_service",
        "revision" => 4,
        "credential_lease_id" => "lease-one",
        "broker_endpoint" => "broker://session-one"
      })

    assert valid.type == :brokered_service
    assert :ok = AuthProfile.validate(valid, %{mode: :unattended})
    assert AuthProfile.runtime_environment(valid) == []

    for {lease, endpoint} <- [
          {nil, "broker://session"},
          {"", "broker://session"},
          {"lease", nil},
          {"lease", ""}
        ] do
      incomplete = %{valid | credential_lease_id: lease, broker_endpoint: endpoint}
      assert {:error, :brokered_auth_incomplete} = AuthProfile.validate(incomplete, %{})
    end
  end

  test "rejects auth profile types outside the closed contract" do
    assert_raise ArgumentError, "invalid Codex auth profile", fn ->
      AuthProfile.new(%{id: "ambient", type: :ambient, revision: 1})
    end
  end
end
