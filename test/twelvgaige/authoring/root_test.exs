defmodule Twelvgaige.Authoring.RootTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Authoring.Root

  test "resolves an explicit traphouse root" do
    root = tmp_dir!()

    assert {:ok, resolution} = Root.resolve(root: root)
    assert resolution.root == Path.expand(root)
    assert resolution.source == :explicit
    refute resolution.user_local_included?
  end

  test "rejects paths outside a resolved root" do
    root = tmp_dir!()
    inside = Path.join(root, "workflows/a.yaml")
    outside = Path.join(tmp_dir!(), "a.yaml")

    assert {:ok, resolution} = Root.resolve(root: root)
    assert :ok = Root.ensure_within_root(inside, resolution)

    assert {:error, error} = Root.ensure_within_root(outside, resolution)
    assert error.reason == :invalid_shell
    assert error.message =~ "outside the resolved traphouse root"
  end

  test "rejects symlink paths inside a resolved root" do
    root = tmp_dir!()
    outside = Path.join(tmp_dir!(), "outside.yaml")
    link = Path.join(root, "workflows/linked.yaml")

    File.mkdir_p!(Path.dirname(link))
    File.write!(outside, "kind: workflow\n")
    File.ln_s!(outside, link)

    assert {:ok, resolution} = Root.resolve(root: root)
    assert {:error, error} = Root.ensure_within_root(link, resolution)
    assert error.reason == :invalid_shell
    assert error.message =~ "symlink"
  end

  test "uses nearest cwd traphouse when no explicit root is supplied" do
    original = File.cwd!()
    workspace = tmp_dir!()
    traphouse = Path.join(workspace, "traphouse")
    nested = Path.join(workspace, "src/app")
    File.mkdir_p!(traphouse)
    File.mkdir_p!(nested)

    on_exit(fn -> File.cd!(original) end)

    File.cd!(nested)

    assert {:ok, resolution} = Root.resolve()
    assert normalize_tmp_path(resolution.root) == normalize_tmp_path(Path.expand(traphouse))
    assert resolution.source == :cwd_traphouse
  end

  defp normalize_tmp_path("/private" <> rest), do: rest
  defp normalize_tmp_path(path), do: path

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-root-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
