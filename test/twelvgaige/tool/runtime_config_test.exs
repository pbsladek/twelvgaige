defmodule Twelvgaige.Tool.RuntimeConfigTest do
  use ExUnit.Case, async: false

  alias Twelvgaige.Tool.RuntimeConfig

  setup do
    env_names = [
      "TWELVGAIGE_HTTP_ALLOWED_HOSTS",
      "TWELVGAIGE_HTTP_ALLOW_PRIVATE_HOSTS",
      "TWELVGAIGE_HTTP_TIMEOUT_MS",
      "TWELVGAIGE_HTTP_DEFAULT_MAX_BYTES"
    ]

    old_values = Map.new(env_names, &{&1, System.get_env(&1)})
    Enum.each(env_names, &System.delete_env/1)

    on_exit(fn ->
      Enum.each(old_values, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "does not add tool opts when HTTP environment is absent" do
    assert RuntimeConfig.merge(profile: :laptop) == [profile: :laptop]
  end

  test "adds HTTP policy to http_get and http_post" do
    System.put_env("TWELVGAIGE_HTTP_ALLOWED_HOSTS", "127.0.0.1, localhost")
    System.put_env("TWELVGAIGE_HTTP_ALLOW_PRIVATE_HOSTS", "true")
    System.put_env("TWELVGAIGE_HTTP_TIMEOUT_MS", "1500")

    opts = RuntimeConfig.merge([])
    by_name = Keyword.fetch!(opts, :tool_opts_by_name)

    for tool <- ["http_get", "http_post"] do
      assert by_name[tool][:allowed_hosts] == ["127.0.0.1", "localhost"]
      assert by_name[tool][:allow_private_hosts] == true
      assert by_name[tool][:timeout_ms] == 1500
    end
  end

  test "keeps explicit tool opts ahead of environment defaults" do
    System.put_env("TWELVGAIGE_HTTP_ALLOWED_HOSTS", "env.example")
    System.put_env("TWELVGAIGE_HTTP_ALLOW_PRIVATE_HOSTS", "1")

    opts =
      RuntimeConfig.merge(
        tool_opts_by_name: %{
          http_get: [allowed_hosts: ["explicit.example"]]
        }
      )

    by_name = Keyword.fetch!(opts, :tool_opts_by_name)
    assert by_name["http_get"][:allowed_hosts] == ["explicit.example"]
    assert by_name["http_get"][:allow_private_hosts] == true
    assert by_name["http_post"][:allowed_hosts] == ["env.example"]
  end
end
