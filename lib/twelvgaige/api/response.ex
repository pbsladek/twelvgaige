defmodule Twelvgaige.API.Response do
  @moduledoc """
  Transport-neutral HTTP response shape.

  Phase 5 starts with a pure router so endpoint behavior can be tested without
  committing to a listener dependency. A Plug/Bandit or raw transport adapter
  can translate this struct into wire responses later.
  """

  @type t :: %__MODULE__{
          status: pos_integer(),
          headers: [{String.t(), String.t()}],
          body: String.t()
        }

  @enforce_keys [:status, :body]
  defstruct [:status, :body, headers: [{"content-type", "application/json"}]]
end
