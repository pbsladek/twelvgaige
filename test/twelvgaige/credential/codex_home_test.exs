defmodule Twelvgaige.Credential.CodexHomeTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Twelvgaige.Credential.CodexHome

  setup do
    root =
      Path.join(System.tmp_dir!(), "twelvgaige-codex-home-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, destination: Path.join(root, "session-home")}
  end

  test "materializes a bounded private home with the secret only on stdin", context do
    parent = self()

    runner = fn binary, args, stdin, opts ->
      send(parent, {:login, binary, args, stdin, opts[:environment]})
      File.mkdir_p!(Path.join(opts[:environment]["CODEX_HOME"], "state"))
      File.write!(Path.join(opts[:environment]["CODEX_HOME"], "auth.json"), "authenticated")
      File.write!(Path.join(opts[:environment]["CODEX_HOME"], "state/session"), "ready")
      :ok
    end

    assert {:ok, mount} =
             CodexHome.materialize("sk-private", context.destination,
               allowed_root: context.root,
               codex_binary: "/opt/codex/bin/codex",
               login_runner: runner
             )

    assert_receive {:login, "/opt/codex/bin/codex", ["login", "--with-api-key"], "sk-private\n",
                    environment}

    assert environment["HOME"] == context.destination
    assert environment["CODEX_HOME"] == context.destination
    refute Map.has_key?(environment, "OPENAI_API_KEY")

    assert mount == %{
             source: context.destination,
             destination: "/run/codex-home",
             mode: :read_write
           }

    assert private_mode?(context.destination)
    assert private_mode?(Path.join(context.destination, "auth.json"))
    assert private_mode?(Path.join(context.destination, "state/session"))

    assert :ok = CodexHome.cleanup(context.destination, allowed_root: context.root)
    refute File.exists?(context.destination)
    assert :already_removed = CodexHome.cleanup(context.destination, allowed_root: context.root)
  end

  test "rejects links and erases partial materialization without leaking runner output",
       context do
    runner = fn _binary, _args, stdin, opts ->
      File.write!(Path.join(opts[:environment]["CODEX_HOME"], "partial"), "state")
      File.ln_s!("/tmp", Path.join(opts[:environment]["CODEX_HOME"], "escape"))
      {:error, {:provider_reported, stdin}}
    end

    result =
      CodexHome.materialize("never-report-me", context.destination,
        allowed_root: context.root,
        codex_binary: "/opt/codex/bin/codex",
        login_runner: runner
      )

    assert {:error, {:codex_login_failed, :redacted}} = result
    refute inspect(result) =~ "never-report-me"
    refute File.exists?(context.destination)
  end

  test "fails closed when a successful login creates an unsupported entry", context do
    runner = fn _binary, _args, _stdin, opts ->
      File.ln_s!("/tmp", Path.join(opts[:environment]["CODEX_HOME"], "escape"))
      :ok
    end

    assert {:error, :codex_home_unsupported_entry} =
             CodexHome.materialize("sk-private", context.destination,
               allowed_root: context.root,
               codex_binary: "/opt/codex/bin/codex",
               login_runner: runner
             )

    refute File.exists?(context.destination)
  end

  test "redacts a runner exception that contains the secret", context do
    runner = fn _binary, _args, stdin, _opts -> raise "failed with #{stdin}" end

    result =
      CodexHome.materialize("never-echo-this", context.destination,
        allowed_root: context.root,
        codex_binary: "/opt/codex/bin/codex",
        login_runner: runner
      )

    assert {:error, :codex_home_materialization_crashed} = result
    refute inspect(result) =~ "never-echo-this"
    refute File.exists?(context.destination)
  end

  test "default runner uses stdin and a cleared process environment", context do
    fake_codex = Path.join(context.root, "fake-codex")

    File.mkdir_p!(context.root)

    File.write!(
      fake_codex,
      """
      #!/bin/sh
      IFS= read -r api_key
      [ "$1" = "login" ] || exit 2
      [ "$2" = "--with-api-key" ] || exit 3
      [ "$api_key" = "stdin-only" ] || exit 4
      [ -z "${OPENAI_API_KEY+x}" ] || exit 5
      /usr/bin/printf '%s' authenticated > "$CODEX_HOME/auth.json"
      """
    )

    File.chmod!(fake_codex, 0o700)

    assert {:ok, _mount} =
             CodexHome.materialize("stdin-only", context.destination,
               allowed_root: context.root,
               codex_binary: fake_codex
             )

    assert File.read!(Path.join(context.destination, "auth.json")) == "authenticated"
  end

  test "never cleans a path outside the exact credential root", context do
    outside = context.root <> "-outside"
    File.mkdir_p!(outside)

    assert {:error, :codex_home_outside_allowed_root} =
             CodexHome.cleanup(outside, allowed_root: context.root)

    assert File.dir?(outside)
    File.rm_rf!(outside)
  end

  defp private_mode?(path), do: (File.stat!(path).mode &&& 0o077) == 0
end
