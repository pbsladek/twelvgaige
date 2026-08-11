defmodule Twelvgaige.Developer.SupportBundleTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Developer.SupportBundle
  alias Twelvgaige.CLI.Dispatcher

  test "public CLI previews and writes the same request without exposing contents" do
    root = temp_dir("support-cli")
    destination = Path.join(root, "bundle")

    assert {:ok, preview, 0} =
             Dispatcher.run([
               "support",
               "bundle",
               "--output",
               destination,
               "--root",
               root,
               "--request-id",
               "support-cli-request"
             ])

    assert preview =~ "Support bundle preview"
    refute File.exists?(destination)

    assert {:ok, written, 0} =
             Dispatcher.run([
               "support",
               "bundle",
               "--output",
               destination,
               "--root",
               root,
               "--request-id",
               "support-cli-request",
               "--write",
               "--yes"
             ])

    assert written =~ "Support bundle written"
    assert File.regular?(Path.join(destination, "manifest.json"))
  end

  test "preview is allowlisted and writing is private, redacted, and replay-safe" do
    root = temp_dir("support")
    destination = Path.join(root, "bundle")
    canary = "secret-task-and-api-key-canary"
    File.write!(Path.join(root, "task.md"), canary)

    opts = [
      destination: destination,
      project_root: root,
      request_id: "support-request-1",
      profile_names_fun: fn _opts -> {:ok, ["local"]} end,
      endpoint_discover_fun: fn _opts ->
        {:ok, %{address: {:tcp, {127, 0, 0, 1}, 42}, token: canary}}
      end
    ]

    assert {:ok, preview} = SupportBundle.run(opts)
    assert preview.dry_run
    refute File.exists?(destination)

    assert Map.keys(preview.files) |> Enum.sort() ==
             ["configuration.json", "daemon.json", "environment.json"]

    assert Enum.any?(preview.excluded, &String.contains?(&1, "credential"))

    assert {:error, :support_bundle_confirmation_required} =
             SupportBundle.run(Keyword.put(opts, :write?, true))

    assert {:ok, written} =
             SupportBundle.run(opts ++ [write?: true, yes?: true])

    refute written.dry_run
    assert File.stat!(destination).mode |> Bitwise.band(0o777) == 0o700

    contents =
      destination
      |> File.ls!()
      |> Enum.map_join("", &File.read!(Path.join(destination, &1)))

    refute contents =~ canary
    refute contents =~ root
    assert contents =~ "allowlist-only"

    Enum.each(File.ls!(destination), fn name ->
      assert File.stat!(Path.join(destination, name)).mode |> Bitwise.band(0o777) == 0o600
    end)

    assert {:ok, replayed} =
             SupportBundle.run(opts ++ [write?: true, yes?: true])

    assert replayed.replayed

    assert {:error, :support_bundle_destination_conflict} =
             SupportBundle.run(
               Keyword.merge(opts,
                 request_id: "different-request",
                 write?: true,
                 yes?: true
               )
             )
  end

  defp temp_dir(name) do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end
end
