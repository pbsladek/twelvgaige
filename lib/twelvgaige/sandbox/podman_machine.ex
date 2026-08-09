defmodule Twelvgaige.Sandbox.PodmanMachine do
  @moduledoc "Explicit bootstrap and health checks for the dedicated Podman machine."

  alias Twelvgaige.Sandbox.Backend.Podman
  alias Twelvgaige.Tool.CommandRunner

  @machine_name "twelvgaige"

  def health(opts \\ []) do
    Podman.probe(
      Keyword.merge(opts,
        machine_name: Keyword.get(opts, :machine_name, @machine_name),
        machine_allowed_mounts: Keyword.fetch!(opts, :allowed_roots),
        restricted?: true
      )
    )
  end

  def bootstrap_plan(opts) do
    with {:ok, roots} <- validate_roots(Keyword.fetch!(opts, :allowed_roots)) do
      machine = Keyword.get(opts, :machine_name, @machine_name)

      args = [
        "machine",
        "init",
        "--cpus",
        to_string(Keyword.get(opts, :cpus, 4)),
        "--memory",
        to_string(Keyword.get(opts, :memory_mib, 6144)),
        "--disk-size",
        to_string(Keyword.get(opts, :disk_size_gib, 64)),
        "--rootful=false",
        "--user-mode-networking=true"
      ]

      volume_args = Enum.flat_map(roots, &["--volume", "#{&1}:#{&1}"])

      {:ok,
       %{
         machine_name: machine,
         allowed_roots: roots,
         init_argv: args ++ volume_args ++ [machine],
         start_argv: ["machine", "start", "--no-info", machine]
       }}
    end
  end

  def bootstrap(opts) do
    if Keyword.get(opts, :confirm?, false) do
      with {:ok, plan} <- bootstrap_plan(opts),
           {:ok, _init} <- command(plan.init_argv, opts),
           {:ok, _start} <- command(plan.start_argv, opts),
           {:ok, health} <- health(Keyword.put(opts, :allowed_roots, plan.allowed_roots)) do
        {:ok, %{plan: plan, health: health}}
      end
    else
      {:error, :podman_machine_bootstrap_confirmation_required}
    end
  end

  defp validate_roots(roots) when is_list(roots) and roots != [] do
    roots = Enum.map(roots, &(&1 |> Path.expand() |> Path.absname()))

    cond do
      Enum.any?(roots, &(Path.type(&1) != :absolute)) ->
        {:error, :podman_machine_root_not_absolute}

      Enum.any?(roots, &broad_root?/1) ->
        {:error, :podman_machine_root_too_broad}

      true ->
        {:ok, Enum.uniq(roots)}
    end
  end

  defp validate_roots(_roots), do: {:error, :podman_machine_roots_required}

  defp broad_root?(path) do
    path in ["/", System.user_home!(), "/Users", "/home", "/private", "/var", "/tmp"]
  end

  defp command(args, opts) do
    runner = Keyword.get(opts, :command_runner, &CommandRunner.run/3)

    case runner.(Keyword.get(opts, :podman_binary, "podman"), args,
           timeout_ms: Keyword.get(opts, :timeout_ms, 120_000),
           require_absolute_binary?: Keyword.get(opts, :require_absolute_binary?, false),
           scrub_env?: true,
           posix_port?: true
         ) do
      {:ok, %{status: 0} = result} -> {:ok, result}
      {:ok, %{status: status, stdout: output}} -> {:error, %{status: status, output: output}}
      {:error, reason} -> {:error, reason}
    end
  end
end
