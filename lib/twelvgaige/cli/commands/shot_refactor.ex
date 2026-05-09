defmodule Twelvgaige.CLI.Commands.ShotRefactor do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.ShotInsert
  alias Twelvgaige.CLI.Commands.ShotReplace
  alias Twelvgaige.CLI.Commands.ShotUpdate

  @spec add(String.t(), String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  defdelegate add(path, shot_id, args), to: ShotInsert

  @spec split(String.t(), String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  defdelegate split(path, shot_id, args), to: ShotInsert

  @spec merge(String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  defdelegate merge(path, args), to: ShotInsert

  @spec gate(String.t(), String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  defdelegate gate(path, target_id, args), to: ShotInsert

  @spec rename(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t(), non_neg_integer()}
  defdelegate rename(path, old_id, new_id, args), to: ShotUpdate

  @spec move(String.t(), String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  defdelegate move(path, shot_id, args), to: ShotUpdate

  @spec remove(String.t(), String.t(), [String.t()]) :: {:ok, String.t(), non_neg_integer()}
  defdelegate remove(path, shot_id, args), to: ShotUpdate

  @spec set_schema(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t(), non_neg_integer()}
  defdelegate set_schema(path, shot_id, schema_path, args), to: ShotReplace

  @spec replace_agent(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t(), non_neg_integer()}
  defdelegate replace_agent(path, old_agent, new_agent, args), to: ShotReplace

  @spec replace_tool(String.t(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t(), non_neg_integer()}
  defdelegate replace_tool(path, old_tool, new_tool, args), to: ShotReplace
end
