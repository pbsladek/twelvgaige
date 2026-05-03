defmodule Twelvgaige.Tool.Safety do
  @moduledoc """
  Ordered safety levels for policy checks.

  The comparison is a maximum-allowed threshold. A shot whose choke allows
  `:read_only` cannot run an `:idempotent_write` tool. A shot whose choke
  allows `:destructive` can run read-only, idempotent-write, or destructive
  tools, but not irreversible tools.
  """

  @levels [:read_only, :idempotent_write, :destructive, :irreversible]
  @rank @levels |> Enum.with_index() |> Map.new()

  @type level :: :read_only | :idempotent_write | :destructive | :irreversible

  @spec levels() :: [level()]
  def levels, do: @levels

  @spec valid?(term()) :: boolean()
  def valid?(level), do: level in @levels

  @spec allows?(level(), level()) :: boolean()
  def allows?(max_allowed, actual) when max_allowed in @levels and actual in @levels do
    Map.fetch!(@rank, actual) <= Map.fetch!(@rank, max_allowed)
  end

  def allows?(_max_allowed, _actual), do: false
end
