defmodule Twelvgaige.Workspace.CanonicalTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Workspace.Canonical
  alias Twelvgaige.Workspace.ResultManifest

  test "encodes stable canonical JSON and a domain-separated golden digest" do
    value = %{"b" => 1, "a" => [true, nil, "x"]}

    assert {:ok, ~s({"a":[true,null,"x"],"b":1})} = Canonical.encode(value)

    assert {:ok, "sha256:bef4f9d5ea6de22b02afd8d4f76db52f8de70cfab6021340fb26b3f52824dc41"} =
             Canonical.digest("golden", 1, value)

    assert Canonical.digest("other", 1, value) != Canonical.digest("golden", 1, value)
    assert {:error, {:canonical_encoding_invalid, _message}} = Canonical.encode(1.5)
    assert {:error, {:canonical_encoding_invalid, _message}} = Canonical.encode(%{1 => "bad"})
  end

  test "round trips arbitrary path bytes without treating display text as identity" do
    raw = <<"lib/", 0xFF, ".ex">>
    encoded = Canonical.path(raw)

    assert encoded == %{"encoding" => "base64url", "bytes" => "bGliL_8uZXg"}
    assert {:ok, ^raw} = Canonical.decode_path(encoded)
  end

  test "result manifests are stable across map ordering and exclude timestamps from identity" do
    attrs = %{
      workspace_id: "ws_1",
      source_base_commit: String.duplicate("a", 40),
      workspace_baseline_commit: String.duplicate("a", 40),
      result_tree: String.duplicate("b", 40),
      patch: "patch",
      changed_paths: [
        %{
          "path" => Canonical.path("lib/example.ex"),
          "status" => "modified",
          "new_mode" => "100644",
          "bytes" => 4,
          "digest" => "sha256:value"
        }
      ],
      outcomes: %{artifact_integrity: :verified},
      created_at: ~U[2026-08-10 01:00:00Z]
    }

    assert {:ok, first} = ResultManifest.new(attrs)

    assert {:ok, second} =
             ResultManifest.new(%{
               attrs
               | created_at: ~U[2026-08-11 01:00:00Z],
                 outcomes: %{"artifact_integrity" => "verified"}
             })

    assert first.manifest_digest == second.manifest_digest
    refute first.no_change
    assert first.outcomes["test_verification"] == "not_run"
  end

  test "result manifest v1 identity remains interpretable without v2 bundle fields" do
    legacy = %{
      schema_version: 1,
      encoding_version: 1,
      digest_algorithm: "sha256",
      workspace_id: "ws_legacy",
      source_base_commit: String.duplicate("a", 40),
      workspace_baseline_commit: String.duplicate("a", 40),
      result_tree: String.duplicate("b", 40),
      result_commit: nil,
      changed_paths: [],
      patch_digest: "sha256:legacy",
      patch_bytes: 0,
      no_change: true,
      outcomes: %{},
      out_of_policy: []
    }

    payload = ResultManifest.payload(legacy)
    assert payload["schema_version"] == 1
    refute Map.has_key?(payload, "bundle_digest")
    refute Map.has_key?(payload, "bundle_bytes")
    assert {:ok, "sha256:" <> _digest} = Canonical.digest("result-manifest", 1, payload)
  end
end
