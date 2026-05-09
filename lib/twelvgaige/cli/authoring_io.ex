defmodule Twelvgaige.CLI.AuthoringIO do
  @moduledoc false

  alias Twelvgaige.Authoring.AtomicFile
  alias Twelvgaige.Authoring.Root, as: AuthoringRoot
  alias Twelvgaige.CLI.ExitCode

  import Twelvgaige.CLI.CommandHelpers, only: [format_command_error: 2]

  @spec write_file(Path.t(), iodata()) :: :ok | {:error, term()}
  def write_file(path, contents), do: AtomicFile.write(path, contents)

  @spec ensure_can_write(Path.t(), keyword()) :: :ok | {:error, Twelvgaige.Error.t()}
  def ensure_can_write(path, opts) do
    if File.exists?(path) and not opts[:force?] do
      {:error,
       Twelvgaige.Error.new(:input_error, :invalid_shell, "output file already exists",
         details: %{path: path}
       )}
    else
      :ok
    end
  end

  @spec ensure_output_within_root(nil | Path.t(), AuthoringRoot.resolution()) ::
          :ok | {:error, Twelvgaige.Error.t()}
  def ensure_output_within_root(nil, _root), do: :ok
  def ensure_output_within_root(path, root), do: AuthoringRoot.ensure_within_root(path, root)

  @spec format_write_error(term()) :: {:ok, String.t(), non_neg_integer()}
  def format_write_error(error) do
    {:ok, format_command_error(error, :human), ExitCode.for_error(error)}
  end

  @spec maybe_write_json_report(map(), keyword(), String.t(), (-> String.t()), non_neg_integer()) ::
          {:ok, String.t(), non_neg_integer()}
  def maybe_write_json_report(report_map, opts, label, stdout_fun, exit_code \\ 0) do
    case opts[:output] do
      nil ->
        {:ok, stdout_fun.(), exit_code}

      output_path ->
        with :ok <- ensure_can_write(output_path, opts),
             :ok <- write_file(output_path, Jason.encode!(report_map, pretty: true) <> "\n") do
          {:ok, "wrote #{label} report: #{output_path}\n", exit_code}
        else
          {:error, error} -> format_write_error(error)
        end
    end
  end
end
