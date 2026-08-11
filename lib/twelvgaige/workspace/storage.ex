defmodule Twelvgaige.Workspace.Storage do
  @moduledoc "Host disk-capacity inspection for workspace admission and finalization reserves."

  @spec available_bytes(Path.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def available_bytes(path) do
    case System.cmd("df", ["-Pk", Path.expand(path)],
           stderr_to_stdout: true,
           env: [{"LC_ALL", "C"}, {"LANG", "C"}]
         ) do
      {output, 0} -> parse_df(output)
      {output, status} -> {:error, {:workspace_disk_probe_failed, status, output}}
    end
  rescue
    error in ErlangError -> {:error, {:workspace_disk_probe_unavailable, error.original}}
  end

  @doc false
  def parse_df(output) when is_binary(output) do
    case output |> String.split("\n", trim: true) |> List.last() do
      nil ->
        {:error, :workspace_disk_probe_invalid}

      line ->
        fields = String.split(line, ~r/\s+/, trim: true)

        case Enum.at(fields, 3) do
          nil ->
            {:error, :workspace_disk_probe_invalid}

          available_kib ->
            case Integer.parse(available_kib) do
              {value, ""} when value >= 0 -> {:ok, value * 1_024}
              _invalid -> {:error, :workspace_disk_probe_invalid}
            end
        end
    end
  end
end
