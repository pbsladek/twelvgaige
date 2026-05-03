defmodule Twelvgaige.MixProject do
  use Mix.Project

  def project do
    [
      app: :twelvgaige,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      escript: [main_module: Twelvgaige.CLI.Main, app: nil, include_priv_for: [:exqlite]],
      default_release: :twelvgaige_native,
      releases: releases()
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {Twelvgaige.Application, []}
    ]
  end

  defp deps do
    [
      {:burrito, "~> 1.5", runtime: false},
      {:ecto_sql, "~> 3.12"},
      {:ecto_sqlite3, "~> 0.17"},
      {:jason, "~> 1.4"},
      {:toml_elixir, "~> 3.1"},
      {:yamerl, "~> 0.10"}
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
            linux_arm64: burrito_target(:linux_arm64, :linux, :aarch64),
            windows: burrito_target(:windows, :windows, :x86_64)
          ]
        ]
      ],
      twelvgaige_native: [
        include_erts: true,
        include_executables_for: [:unix, :windows],
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

    unix_wrapper = Path.join(bin_dir, "twelvgaige")
    File.write!(unix_wrapper, unix_release_wrapper())
    File.chmod!(unix_wrapper, 0o755)

    File.write!(Path.join(bin_dir, "twelvgaige.bat"), windows_batch_wrapper())
    File.write!(Path.join(bin_dir, "twelvgaige.ps1"), windows_powershell_wrapper())

    release
  end

  defp unix_release_wrapper do
    """
    #!/bin/sh
    set -eu

    SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
    RELEASE_BIN="$SCRIPT_DIR/twelvgaige_native"
    ARGS_FILE="${TMPDIR:-/tmp}/twelvgaige-cli-$$.args"

    : > "$ARGS_FILE"

    cleanup() {
      rm -f "$ARGS_FILE"
    }

    trap cleanup EXIT INT TERM

    for arg in "$@"; do
      printf '%s\\000' "$arg" >> "$ARGS_FILE"
    done

    export TWELVGAIGE_RELEASE_CLI_ARGS_FILE="$ARGS_FILE"

    "$RELEASE_BIN" eval "Twelvgaige.CLI.Release.main()"
    status=$?
    cleanup
    exit "$status"
    """
  end

  defp windows_batch_wrapper do
    """
    @echo off
    setlocal

    set "SCRIPT_DIR=%~dp0"

    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%twelvgaige.ps1" %*
    exit /b %ERRORLEVEL%
    """
  end

  defp windows_powershell_wrapper do
    """
    $ErrorActionPreference = "Stop"

    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ReleaseBin = Join-Path $ScriptDir "twelvgaige_native.bat"
    $ArgsFile = Join-Path ([System.IO.Path]::GetTempPath()) "twelvgaige-cli-$PID.args"
    $PreviousArgsFile = $env:TWELVGAIGE_RELEASE_CLI_ARGS_FILE

    try {
      $contents = [string]::Join([char]0, $args)

      if ($args.Count -gt 0) {
        $contents = $contents + [char]0
      }

      $encoding = New-Object System.Text.UTF8Encoding $false
      [System.IO.File]::WriteAllText($ArgsFile, $contents, $encoding)

      $env:TWELVGAIGE_RELEASE_CLI_ARGS_FILE = $ArgsFile
      & $ReleaseBin eval "Twelvgaige.CLI.Release.main()"
      exit $LASTEXITCODE
    }
    finally {
      if ($null -eq $PreviousArgsFile) {
        Remove-Item Env:TWELVGAIGE_RELEASE_CLI_ARGS_FILE -ErrorAction SilentlyContinue
      }
      else {
        $env:TWELVGAIGE_RELEASE_CLI_ARGS_FILE = $PreviousArgsFile
      }

      Remove-Item -LiteralPath $ArgsFile -Force -ErrorAction SilentlyContinue
    }
    """
  end
end
