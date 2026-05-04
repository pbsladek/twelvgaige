defmodule Twelvgaige.Shell.Impact do
  @moduledoc """
  Deterministic impact reports over shell inventory data.

  Impact answers "which workflow shells reference this agent/tool/template?" It
  is read-only and does not require the daemon.
  """

  alias Twelvgaige.Error
  alias Twelvgaige.Shell.Inventory

  @type selector_kind :: :agent | :tool | :template
  @type report :: %{
          path: Path.t(),
          status: :ok | :degraded,
          exit_code: 0,
          selector: map(),
          summary: map(),
          matches: [map()],
          errors: [map()]
        }

  @spec run(Path.t(), selector_kind(), String.t(), keyword()) ::
          {:ok, report()} | {:error, Error.t()}
  def run(path, selector_kind, selector_value, opts \\ [])
      when selector_kind in [:agent, :tool, :template] and is_binary(selector_value) do
    with {:ok, inventory} <- Inventory.run(path, opts) do
      matches =
        inventory.workflows
        |> Enum.map(&workflow_match(&1, selector_kind, selector_value))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort_by(& &1["path"])

      {:ok,
       %{
         path: inventory.path,
         status: inventory.status,
         exit_code: 0,
         selector: %{
           "kind" => Atom.to_string(selector_kind),
           "value" => selector_value
         },
         summary: %{
           "workflow_count" => length(matches),
           "shot_count" => matches |> Enum.flat_map(& &1["matching_shots"]) |> length(),
           "error_count" => length(inventory.errors)
         },
         matches: matches,
         errors: inventory.errors
       }}
    end
  end

  @spec to_map(report()) :: map()
  def to_map(report) do
    %{
      path: report.path,
      status: Atom.to_string(report.status),
      exit_code: report.exit_code,
      selector: report.selector,
      summary: report.summary,
      matches: report.matches,
      errors: report.errors
    }
  end

  defp workflow_match(workflow, selector_kind, selector_value) do
    matching_shots =
      workflow
      |> Map.get("shots", [])
      |> Enum.filter(&shot_matches?(&1, selector_kind, selector_value))
      |> Enum.map(&matching_shot_map/1)

    cond do
      matching_shots != [] ->
        workflow_match_map(workflow, matching_shots)

      selector_kind == :template and selector_value in Map.get(workflow, "templates", []) ->
        workflow_match_map(workflow, [])

      true ->
        nil
    end
  end

  defp shot_matches?(shot, :agent, value), do: Map.get(shot, "agent") == value
  defp shot_matches?(shot, :tool, value), do: value in Map.get(shot, "tools", [])
  defp shot_matches?(shot, :template, value), do: value in Map.get(shot, "templates", [])

  defp workflow_match_map(workflow, matching_shots) do
    %{
      "path" => workflow["path"],
      "id" => workflow["id"],
      "version" => workflow["version"],
      "owner" => workflow["owner"],
      "lifecycle" => workflow["lifecycle"],
      "write_capable" => Map.get(workflow, "write_capable", false),
      "matching_shots" => matching_shots
    }
    |> compact()
  end

  defp matching_shot_map(shot) do
    %{
      "id" => shot["id"],
      "kind" => shot["kind"],
      "agent" => shot["agent"],
      "tools" => Map.get(shot, "tools", []),
      "templates" => Map.get(shot, "templates", []),
      "write_capable" => Map.get(shot, "write_capable", false),
      "safety" => Map.get(shot, "safety", false)
    }
    |> compact()
  end

  defp compact(map) when is_map(map) do
    map
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      value = compact(value)

      if empty?(value) do
        acc
      else
        Map.put(acc, key, value)
      end
    end)
  end

  defp compact(list) when is_list(list), do: Enum.map(list, &compact/1)
  defp compact(value), do: value

  defp empty?(nil), do: true
  defp empty?(map) when map == %{}, do: true
  defp empty?(_value), do: false
end
