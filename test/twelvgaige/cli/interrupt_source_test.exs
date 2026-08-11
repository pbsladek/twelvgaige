defmodule Twelvgaige.CLI.InterruptSourceTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.CLI.InterruptSource

  setup do
    previous_fifo = System.get_env("TWELVGAIGE_INTERRUPT_FIFO")
    previous_ready = System.get_env("TWELVGAIGE_INTERRUPT_READY")

    on_exit(fn ->
      restore_env("TWELVGAIGE_INTERRUPT_FIFO", previous_fifo)
      restore_env("TWELVGAIGE_INTERRUPT_READY", previous_ready)
    end)

    :ok
  end

  test "reads each launcher interrupt and publishes only an owner-only readiness marker" do
    root = temp_dir("interrupt-source")
    fifo = Path.join(root, "interrupt.fifo")
    ready = Path.join(root, "interrupt.ready")

    assert {"", 0} = System.cmd("mkfifo", [fifo], stderr_to_stdout: true)
    File.chmod!(fifo, 0o600)
    {:ok, keepalive} = File.open(fifo, [:read, :write, :binary, :raw])

    System.put_env("TWELVGAIGE_INTERRUPT_FIFO", fifo)
    System.put_env("TWELVGAIGE_INTERRUPT_READY", ready)
    parent = self()

    assert {:ok, source} = InterruptSource.start(fn -> send(parent, :interrupt) end)
    assert {:ok, %{type: :regular, mode: mode}} = File.lstat(ready)
    assert Bitwise.band(mode, 0o077) == 0

    {:ok, writer} = File.open(fifo, [:write, :binary, :raw])
    :ok = File.close(keepalive)
    assert :ok = IO.binwrite(writer, "II")

    assert_receive :interrupt
    assert_receive :interrupt

    assert :ok = InterruptSource.stop(source)
    refute File.exists?(ready)
    assert File.exists?(fifo)
    :ok = File.close(writer)
  end

  test "refuses a regular file in place of the launcher FIFO" do
    root = temp_dir("interrupt-source-invalid")
    fifo = Path.join(root, "interrupt.fifo")
    ready = Path.join(root, "interrupt.ready")
    File.write!(fifo, "not a fifo")
    File.chmod!(fifo, 0o600)

    System.put_env("TWELVGAIGE_INTERRUPT_FIFO", fifo)
    System.put_env("TWELVGAIGE_INTERRUPT_READY", ready)

    assert {:error, {:interrupt_fifo_unavailable, :interrupt_fifo_type_invalid}} =
             InterruptSource.start(fn -> :ok end)

    refute File.exists?(ready)
  end

  defp temp_dir(name) do
    path =
      Path.join(System.tmp_dir!(), "twelvgaige-#{name}-#{System.unique_integer([:positive])}")

    File.mkdir_p!(path)
    File.chmod!(path, 0o700)
    on_exit(fn -> File.rm_rf!(path) end)
    path
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
