defmodule Twelvgaige.CLI.Commands.ShotInsert do
  @moduledoc false

  alias Twelvgaige.CLI.Commands.ShotAdd
  alias Twelvgaige.CLI.Commands.ShotGate
  alias Twelvgaige.CLI.Commands.ShotSplitMerge

  defdelegate add(path, shot_id, args), to: ShotAdd
  defdelegate gate(path, target_id, args), to: ShotGate
  defdelegate split(path, shot_id, args), to: ShotSplitMerge
  defdelegate merge(path, args), to: ShotSplitMerge
end
