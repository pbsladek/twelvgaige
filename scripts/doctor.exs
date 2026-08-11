defmodule TwelvgaigeDoctor do
  @moduledoc false

  @expected_elixir "1.20.3"
  @expected_otp "28"
  @expected_zig "0.15.2"
  @expected_k3d "5.8.3"

  def run(args) do
    live? = "--live" in args or env_enabled?("TWELVGAIGE_DOCTOR_LIVE")
    checks = core_checks() ++ optional_checks(live?)
    failures = Enum.reject(checks, & &1.ok?)

    Enum.each(checks, &print_check/1)

    if failures == [] do
      IO.puts("\nDoctor: ok")
      System.halt(0)
    else
      IO.puts("\nDoctor: #{length(failures)} issue(s)")
      System.halt(1)
    end
  end

  defp core_checks do
    [
      command_check("elixir", ["--version"], &contains?(&1, "Elixir #{@expected_elixir}")),
      command_check(
        "erl",
        ["-eval", "io:format(\"~s\", [erlang:system_info(otp_release)]), halt().", "-noshell"],
        &String.starts_with?(&1, @expected_otp)
      ),
      command_check("mix", ["--version"], &contains?(&1, "Mix #{@expected_elixir}")),
      command_check("git", ["--version"], &String.starts_with?(&1, "git version")),
      file_check("mix.lock", "mix.lock present"),
      file_check("docs/traphouse/workflows/simple.yaml", "traphouse fixtures present")
    ]
  end

  defp optional_checks(false) do
    [
      optional_command_check("zig", ["version"], @expected_zig, "Burrito builds")
    ]
  end

  defp optional_checks(true) do
    optional_checks(false) ++
      [
        live_command_check(
          "k3d",
          ["version"],
          &contains?(&1, "k3d version v#{@expected_k3d}"),
          "K3D_LIVE=1"
        ),
        live_command_check(
          "kubectl",
          ["version", "--client=true"],
          &contains?(&1, "Client Version:"),
          "K3D_LIVE=1"
        ),
        provider_live_check(),
        sqlcipher_live_check(),
        keychain_live_check()
      ]
  end

  defp command_check(command, args, validator) do
    case System.find_executable(command) do
      nil ->
        %{name: command, ok?: false, detail: "missing command"}

      path ->
        case System.cmd(path, args, stderr_to_stdout: true) do
          {output, 0} ->
            ok? = validator.(output)
            %{name: command, ok?: ok?, detail: first_line(output)}

          {output, status} ->
            %{name: command, ok?: false, detail: "exit #{status}: #{first_line(output)}"}
        end
    end
  rescue
    error -> %{name: command, ok?: false, detail: Exception.message(error)}
  end

  defp optional_command_check(command, args, expected, purpose) do
    case System.find_executable(command) do
      nil ->
        %{name: "#{command} optional", ok?: true, detail: "missing; needed for #{purpose}"}

      path ->
        {output, status} = System.cmd(path, args, stderr_to_stdout: true)
        expected? = is_nil(expected) or contains?(output, expected)
        %{name: "#{command} optional", ok?: status == 0 and expected?, detail: first_line(output)}
    end
  rescue
    error -> %{name: "#{command} optional", ok?: false, detail: Exception.message(error)}
  end

  defp live_command_check(command, args, validator, opt_in) do
    if live_opt_in_for_command?(command) do
      command_check(command, args, validator)
    else
      %{name: "#{command} live", ok?: true, detail: "skipped; set #{opt_in}"}
    end
  end

  defp provider_live_check do
    if env_enabled?("PROVIDER_LIVE") do
      providers = split_env("PROVIDER_LIVE_PROVIDERS")

      cond do
        providers == [] ->
          %{
            name: "provider live",
            ok?: true,
            detail: "auto-detect providers from configured keys/models"
          }

        Enum.all?(providers, &provider_ready?/1) ->
          %{name: "provider live", ok?: true, detail: "configured: #{Enum.join(providers, ",")}"}

        true ->
          missing =
            providers
            |> Enum.reject(&provider_ready?/1)
            |> Enum.join(",")

          %{name: "provider live", ok?: false, detail: "missing key/model config for #{missing}"}
      end
    else
      %{name: "provider live", ok?: true, detail: "skipped; set PROVIDER_LIVE=1"}
    end
  end

  defp sqlcipher_live_check do
    prefix = System.get_env("SQLCIPHER_PREFIX")

    cond do
      is_nil(prefix) or prefix == "" ->
        %{name: "sqlcipher live", ok?: true, detail: "skipped; set SQLCIPHER_PREFIX"}

      File.exists?(Path.join(prefix, "include/sqlcipher/sqlite3.h")) ->
        %{name: "sqlcipher live", ok?: true, detail: "found #{prefix}"}

      true ->
        %{
          name: "sqlcipher live",
          ok?: false,
          detail: "missing include/sqlcipher/sqlite3.h under #{prefix}"
        }
    end
  end

  defp keychain_live_check do
    cond do
      not env_enabled?("KEYCHAIN_LIVE") ->
        %{name: "keychain live", ok?: true, detail: "skipped; set KEYCHAIN_LIVE=1"}

      :os.type() == {:unix, :darwin} and not is_nil(System.find_executable("security")) ->
        %{name: "keychain live", ok?: true, detail: "macOS security command present"}

      true ->
        %{name: "keychain live", ok?: false, detail: "requires macOS security command"}
    end
  end

  defp provider_ready?("openai") do
    env_any?(["TWELVGAIGE_OPENAI_API_KEY", "OPENAI_API_KEY"]) and
      env_present?("TWELVGAIGE_OPENAI_LIVE_MODEL")
  end

  defp provider_ready?("ollama") do
    env_any?(["TWELVGAIGE_OLLAMA_BASE_URL", "OLLAMA_HOST"]) and
      env_present?("TWELVGAIGE_OLLAMA_LIVE_MODEL")
  end

  defp provider_ready?(_provider), do: false

  defp file_check(path, name), do: %{name: name, ok?: File.exists?(path), detail: path}

  defp print_check(%{name: name, ok?: true, detail: detail}) do
    IO.puts("[ok] #{name}: #{detail}")
  end

  defp print_check(%{name: name, ok?: false, detail: detail}) do
    IO.puts("[fail] #{name}: #{detail}")
  end

  defp live_opt_in_for_command?("k3d"), do: env_enabled?("K3D_LIVE")
  defp live_opt_in_for_command?("kubectl"), do: env_enabled?("K3D_LIVE")

  defp split_env(name) do
    name
    |> System.get_env("")
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp env_any?(names), do: Enum.any?(names, &env_present?/1)

  defp env_enabled?(name), do: System.get_env(name) in ["1", "true", "yes"]

  defp env_present?(name) do
    case System.get_env(name) do
      value when is_binary(value) and value != "" -> true
      _missing -> false
    end
  end

  defp contains?(output, value), do: String.contains?(output, value)

  defp first_line(output) do
    output
    |> String.trim()
    |> String.split("\n", parts: 2)
    |> List.first()
    |> case do
      nil -> "no output"
      "" -> "no output"
      line -> line
    end
  end
end

TwelvgaigeDoctor.run(System.argv())
