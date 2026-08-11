defmodule Twelvgaige.MixProject do
  use Mix.Project

  def project do
    [
      app: :twelvgaige,
      version: "0.0.3",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      dialyzer: dialyzer(),
      test_coverage: test_coverage(),
      escript: escript(),
      default_release: :twelvgaige_native,
      releases: releases()
    ]
  end

  def application do
    [
      # Providers and built-in HTTP tools use OTP's :httpc at runtime. These
      # applications must be explicit so Mix releases include their .app files
      # instead of relying on a full development OTP installation.
      extra_applications: [:logger, :inets, :ssl],
      mod: {Twelvgaige.Application, []}
    ]
  end

  def cli do
    [
      preferred_envs: [
        coveralls: :test,
        "coveralls.cobertura": :test,
        "coveralls.detail": :test,
        "coveralls.html": :test,
        "coveralls.json": :test,
        "coveralls.lcov": :test,
        "coveralls.multiple": :test
      ]
    ]
  end

  defp deps do
    [
      {:burrito, "~> 1.5", runtime: false},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},
      {:jason, "~> 1.4"},
      {:excoveralls, "~> 0.18.5", only: :test},
      {:sobelow, "~> 0.14.1", only: [:dev, :test], runtime: false, warn_if_outdated: true},
      {:stream_data, "~> 1.1", only: :test},
      {:toml_elixir, "~> 3.1"},
      {:yamerl, "~> 0.10"}
    ]
  end

  defp escript do
    options = [main_module: Twelvgaige.CLI.Main, app: nil, include_priv_for: [:exqlite]]

    case System.get_env("TWELVGAIGE_ESCRIPT_PATH") do
      path when is_binary(path) and path != "" -> Keyword.put(options, :path, path)
      _unset -> options
    end
  end

  defp dialyzer do
    [
      plt_add_apps: [:ex_unit, :inets, :mix, :public_key, :ssl],
      flags: [:error_handling]
    ]
  end

  def test_coverage do
    [
      summary: [threshold: 75],
      ignore_modules: coverage_ignore_modules()
    ]
  end

  def coverage_ignore_modules do
    [
      ~r/^Twelvgaige\.TestSupport\./,
      ~r/^Twelvgaige\.Store\.SQLite\.Schema\./,
      Twelvgaige.Store.SQLite.Repo,
      Twelvgaige.Store.SQLite.Migration.Repo,
      Twelvgaige.Crypto.SQLCipherSpike.Repo
    ]
  end

  defp releases do
    [
      twelvgaige: [
        applications: [burrito: :load, twelvgaige: :permanent],
        steps: [:assemble, &Burrito.wrap/1],
        burrito: [
          targets: [
            macos_silicon: burrito_target(:macos_silicon, :darwin, :aarch64),
            linux: burrito_target(:linux, :linux, :x86_64),
            linux_arm64: burrito_target(:linux_arm64, :linux, :aarch64)
          ]
        ]
      ],
      twelvgaige_native: [
        include_erts: true,
        include_executables_for: [:unix],
        applications: [twelvgaige: :permanent],
        steps: [:assemble, &write_mix_release_wrappers/1, :tar]
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp burrito_target(alias, os, cpu) do
    [os: os, cpu: cpu] ++ burrito_custom_erts(alias)
  end

  defp burrito_custom_erts(alias) do
    alias_env =
      alias
      |> Atom.to_string()
      |> String.upcase()
      |> then(&"BURRITO_CUSTOM_ERTS_#{&1}")

    case System.get_env(alias_env) || System.get_env("BURRITO_CUSTOM_ERTS") do
      nil -> []
      "" -> []
      path -> [custom_erts: path]
    end
  end

  defp write_mix_release_wrappers(%Mix.Release{} = release) do
    bin_dir = Path.join(release.path, "bin")
    File.mkdir_p!(bin_dir)
    build_cli_launcher!(Path.join(bin_dir, "twelvgaige_interrupt"))

    unix_wrapper = Path.join(bin_dir, "twelvgaige")
    File.write!(unix_wrapper, unix_release_wrapper())
    File.chmod!(unix_wrapper, 0o755)

    release
  end

  defp unix_release_wrapper do
    """
    #!/bin/sh
    set -eu

    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    RELEASE_BIN="$SCRIPT_DIR/twelvgaige_native"
    SIGNAL_LAUNCHER="$SCRIPT_DIR/twelvgaige_interrupt"
    ARGS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/twelvgaige-release-cli.XXXXXX")
    ARGS_FILE="$ARGS_DIR/args"

    umask 077
    : > "$ARGS_FILE"

    cleanup() {
      rm -f "$ARGS_FILE"
      rmdir "$ARGS_DIR" 2>/dev/null || true
    }

    trap cleanup EXIT

    for arg in "$@"; do
      printf '%s\\000' "$arg" >> "$ARGS_FILE"
    done

    export TWELVGAIGE_RELEASE_CLI_ARGS_FILE="$ARGS_FILE"
    export TWELVGAIGE_CLI_CLEANUP_FILE="$ARGS_FILE"
    export TWELVGAIGE_CLI_CLEANUP_DIR="$ARGS_DIR"

    exec "$SIGNAL_LAUNCHER" --payload "$RELEASE_BIN" -- eval "Twelvgaige.CLI.Release.main()"
    """
  end

  defp build_cli_launcher!(destination) do
    source = Path.join(__DIR__, "native/cli_launcher")

    case System.cmd("go", ["-C", source, "build", "-o", destination, "."], stderr_to_stdout: true) do
      {_output, 0} ->
        File.chmod!(destination, 0o755)

      {output, status} ->
        raise "failed to build CLI interrupt launcher (#{status}): #{output}"
    end
  end
end
