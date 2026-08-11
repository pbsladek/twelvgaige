defmodule Twelvgaige.PlatformTest do
  use ExUnit.Case, async: true

  alias Twelvgaige.Platform

  test "supports only macOS and Linux" do
    assert :ok = Platform.ensure_supported({:unix, :darwin})
    assert :ok = Platform.ensure_supported({:unix, :linux})

    assert {:error, {:unsupported_platform, :windows}} =
             Platform.ensure_supported({:win32, :nt})

    assert {:error, {:unsupported_platform, :freebsd}} =
             Platform.ensure_supported({:unix, :freebsd})
  end
end
