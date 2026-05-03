defmodule Twelvgaige.Shot.Attempt do
  @moduledoc """
  Immutable input passed to a shot executor for one attempt.
  """

  @type t :: %__MODULE__{
          round_id: String.t(),
          shot_id: String.t(),
          attempt: pos_integer(),
          definition: term(),
          loadout: term(),
          input: map(),
          dependency_outputs: map()
        }

  @enforce_keys [
    :round_id,
    :shot_id,
    :attempt,
    :definition,
    :loadout,
    :input,
    :dependency_outputs
  ]
  defstruct [
    :round_id,
    :shot_id,
    :attempt,
    :definition,
    :loadout,
    :input,
    :dependency_outputs
  ]

  @doc "Builds a validated attempt from atom-key or string-key attributes."
  @spec new(map() | keyword()) :: t()
  def new(attrs) do
    attempt = required!(attrs, :attempt)

    unless is_integer(attempt) and attempt > 0 do
      raise ArgumentError, "shot attempt must be a positive integer"
    end

    input = required!(attrs, :input)
    dependency_outputs = required!(attrs, :dependency_outputs)

    unless is_map(input) do
      raise ArgumentError, "shot attempt input must be a map"
    end

    unless is_map(dependency_outputs) do
      raise ArgumentError, "shot attempt dependency_outputs must be a map"
    end

    %__MODULE__{
      round_id: required!(attrs, :round_id),
      shot_id: required!(attrs, :shot_id),
      attempt: attempt,
      definition: required!(attrs, :definition),
      loadout: required!(attrs, :loadout),
      input: input,
      dependency_outputs: dependency_outputs
    }
  end

  @doc "Returns the deterministic attempt identity."
  @spec identity(t()) :: {String.t(), String.t(), pos_integer()}
  def identity(%__MODULE__{} = attempt) do
    {attempt.round_id, attempt.shot_id, attempt.attempt}
  end

  defp required!(attrs, key) do
    case value(attrs, key, :__missing__) do
      :__missing__ -> raise ArgumentError, "missing required shot attempt field: #{key}"
      value -> value
    end
  end

  defp value(attrs, key, default) when is_list(attrs) do
    Keyword.get(attrs, key, default)
  end

  defp value(attrs, key, default) when is_map(attrs) do
    Map.get(attrs, key, Map.get(attrs, Atom.to_string(key), default))
  end
end
