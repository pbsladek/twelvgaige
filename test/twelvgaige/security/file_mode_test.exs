defmodule Twelvgaige.Security.FileModeTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Twelvgaige.Security.FileMode

  @tag :posix_only
  test "creates private directories and rejects non-sticky world-writable parents" do
    posix_only(fn ->
      root = tmp_dir!()
      private_dir = Path.join(root, "private")

      assert :ok = FileMode.ensure_private_dir(private_dir)
      assert mode(private_dir) == 0o700

      insecure_parent = Path.join(root, "insecure")
      File.mkdir_p!(insecure_parent)
      File.chmod!(insecure_parent, 0o777)

      assert {:error, {:insecure_world_writable_parent, ^insecure_parent}} =
               FileMode.ensure_private_dir(Path.join(insecure_parent, "child"))
    end)
  end

  @tag :posix_only
  test "marks files private" do
    posix_only(fn ->
      path = Path.join(tmp_dir!(), "secret.log")
      File.write!(path, "secret")
      File.chmod!(path, 0o644)

      assert :ok = FileMode.ensure_private_file(path)
      assert mode(path) == 0o600
    end)
  end

  @tag :posix_only
  test "allows files in existing sticky shared parents without chmoding the parent" do
    posix_only(fn ->
      parent = tmp_dir!()
      File.chmod!(parent, 0o755)

      assert :ok = FileMode.ensure_private_parent_dir(Path.join(parent, "store.sqlite3"))
      assert mode(parent) == 0o755
    end)
  end

  @tag :posix_only
  test "creates missing file parent directories as private" do
    posix_only(fn ->
      parent = Path.join(tmp_dir!(), "state")

      assert :ok = FileMode.ensure_private_parent_dir(Path.join(parent, "store.sqlite3"))
      assert mode(parent) == 0o700
    end)
  end

  defp mode(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    mode &&& 0o777
  end

  defp posix_only(fun), do: unless(windows?(), do: fun.())
  defp windows?, do: match?({:win32, _name}, :os.type())

  defp tmp_dir! do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-file-mode-#{System.unique_integer([:positive])}")

    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end
end
