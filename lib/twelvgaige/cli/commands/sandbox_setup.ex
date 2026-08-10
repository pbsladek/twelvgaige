defmodule Twelvgaige.CLI.Commands.SandboxSetup do
  @moduledoc false

  alias Twelvgaige.CLI.{CommandHelpers, ExitCode}
  alias Twelvgaige.Sandbox.Onboarding

  def run(args, deps \\ []) do
    with {:ok, opts} <- parse_opts(args),
         {:ok, result} <- execute(opts, deps) do
      {:ok, format(result, opts[:format]), 0}
    else
      {:error, reason} ->
        format = if("json" in args, do: :json, else: :human)
        {:ok, CommandHelpers.format_command_error(reason, format), ExitCode.for_error(reason)}
    end
  end

  defp execute(opts, deps) do
    function = if opts[:check?], do: :check, else: :setup
    dependency = if opts[:check?], do: :check_fun, else: :setup_fun
    backend = opts[:backend]
    onboarding_opts = onboarding_opts(opts)

    case Keyword.get(deps, dependency) do
      fun when is_function(fun, 2) -> fun.(backend, onboarding_opts)
      nil -> apply(Onboarding, function, [backend, onboarding_opts])
    end
  end

  defp onboarding_opts(opts) do
    [
      data_root: opts[:data_root],
      source_root: opts[:source_root],
      machine_name: opts[:machine_name],
      cpus: opts[:cpus],
      memory_mib: opts[:memory_mib],
      disk_size_gib: opts[:disk_size_gib],
      worker_image: opts[:worker_image],
      qualify_image?: opts[:qualify_image?],
      timeout_ms: opts[:timeout_ms]
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp parse_opts(args) do
    parse_opts(args,
      backend: :podman,
      format: :human,
      check?: false,
      qualify_image?: false,
      data_root: nil,
      source_root: nil,
      machine_name: "twelvgaige",
      cpus: 4,
      memory_mib: 6144,
      disk_size_gib: 64,
      worker_image: nil,
      timeout_ms: 1_800_000
    )
  end

  defp parse_opts([], opts), do: {:ok, opts}

  defp parse_opts(["--backend", "podman" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :backend, :podman))

  defp parse_opts(["--backend", "apple-container" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :backend, :apple_container))

  defp parse_opts(["--backend", "auto" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :backend, :auto))

  defp parse_opts(["--backend", value | _rest], _opts),
    do: {:error, {:sandbox_backend_invalid, value}}

  defp parse_opts(["--format", value | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :format, CommandHelpers.parse_format(value)))

  defp parse_opts(["--check" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :check?, true))

  defp parse_opts(["--qualify-image" | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :qualify_image?, true))

  defp parse_opts(["--data-root", value | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :data_root, value))

  defp parse_opts(["--source-root", value | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :source_root, value))

  defp parse_opts(["--machine", value | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :machine_name, value))

  defp parse_opts(["--worker-image", value | rest], opts),
    do: parse_opts(rest, Keyword.put(opts, :worker_image, value))

  defp parse_opts(["--cpus", value | rest], opts), do: positive(rest, opts, :cpus, value)

  defp parse_opts(["--memory-mib", value | rest], opts),
    do: positive(rest, opts, :memory_mib, value)

  defp parse_opts(["--disk-gib", value | rest], opts),
    do: positive(rest, opts, :disk_size_gib, value)

  defp parse_opts(["--timeout-ms", value | rest], opts),
    do: positive(rest, opts, :timeout_ms, value)

  defp parse_opts([unknown | _rest], _opts), do: {:error, {:unknown_option, unknown}}

  defp positive(rest, opts, key, value) do
    case Integer.parse(value) do
      {number, ""} when number > 0 -> parse_opts(rest, Keyword.put(opts, key, number))
      _other -> {:error, {:sandbox_setup_positive_integer_required, key}}
    end
  end

  defp format(result, :json), do: CommandHelpers.encode_line(result)

  defp format(result, :human) do
    steps =
      result
      |> value(:steps, [])
      |> Enum.map_join("\n", fn step -> "  - #{value(step, :name)}" end)

    """
    Sandbox ready: #{value(result, :backend)}
    Data root: #{value(result, :data_root)}
    #{if(steps == "", do: "", else: "Completed:\n" <> steps)}
    """
  end

  defp value(map, key, default \\ nil),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))
end
