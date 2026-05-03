defmodule Twelvgaige.Pattern.Compiled do
  @moduledoc """
  Compiled workflow pattern.
  """

  @type shot_id :: String.t()

  @type t :: %__MODULE__{
          workflow_id: String.t(),
          workflow_version: String.t(),
          shots: [struct()],
          shot_by_id: %{shot_id() => struct()},
          dependency_graph: %{shot_id() => [shot_id()]},
          reverse_graph: %{shot_id() => [shot_id()]}
        }

  @enforce_keys [
    :workflow_id,
    :workflow_version,
    :shots,
    :shot_by_id,
    :dependency_graph,
    :reverse_graph
  ]
  defstruct [
    :workflow_id,
    :workflow_version,
    :shots,
    :shot_by_id,
    :dependency_graph,
    :reverse_graph
  ]
end
