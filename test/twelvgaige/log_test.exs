defmodule Twelvgaige.LogTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Twelvgaige.Log

  import ExUnit.CaptureIO

  test "is quiet by default" do
    assert capture_io(:stderr, fn ->
             assert :ok = Log.emit(:info, :daemon_started, "started")
           end) == ""
  end

  test "emits json lines when enabled" do
    output =
      capture_io(fn ->
        assert :ok =
                 Log.emit(
                   :info,
                   :round_queued,
                   "round queued",
                   [round_id: "round_1", token: "secret"],
                   format: :json,
                   io: :stdio
                 )
      end)

    assert %{
             "level" => "info",
             "event" => "round_queued",
             "message" => "round queued",
             "round_id" => "round_1",
             "token" => "[REDACTED]"
           } = Jason.decode!(output)
  end

  test "writes json lines to a retained file sink" do
    path = Path.join(tmp_dir!(), "twelvgaige.jsonl")

    for index <- 1..8 do
      assert :ok =
               Log.emit(
                 :info,
                 :round_completed,
                 "round completed",
                 %{round_id: "round_#{index}", token: "secret"},
                 format: :json,
                 path: path,
                 max_file_bytes: 700,
                 timestamp: ~U[2026-01-02 03:04:05Z]
               )
    end

    contents = File.read!(path)
    assert byte_size(contents) <= 700

    lines = String.split(contents, "\n", trim: true)
    decoded = Enum.map(lines, &Jason.decode!/1)

    assert Enum.all?(decoded, &(&1["event"] == "round_completed"))
    refute Enum.any?(decoded, &(&1["round_id"] == "round_1"))
    assert Enum.any?(decoded, &(&1["round_id"] == "round_8"))
    assert Enum.all?(decoded, &(&1["token"] == "[REDACTED]"))
  end

  @tag :posix_only
  test "writes private log directory and file" do
    posix_only(fn ->
      path = Path.join(tmp_dir!(), "logs/twelvgaige.jsonl")

      assert :ok =
               Log.emit(:info, :round_completed, "round completed", %{round_id: "round_1"},
                 format: :json,
                 path: path
               )

      assert file_mode(Path.dirname(path)) == 0o700
      assert file_mode(path) == 0o600
    end)
  end

  defp tmp_dir! do
    path = Path.join(System.tmp_dir!(), "twelvgaige-log-#{System.unique_integer([:positive])}")
    File.rm_rf!(path)
    File.mkdir_p!(path)
    on_exit(fn -> File.rm_rf(path) end)
    path
  end

  defp file_mode(path) do
    {:ok, %{mode: mode}} = File.stat(path)
    mode &&& 0o777
  end

  defp posix_only(fun), do: unless(windows?(), do: fun.())
  defp windows?, do: match?({:win32, _name}, :os.type())
end
