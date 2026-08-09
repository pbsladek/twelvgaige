defmodule Twelvgaige.ID do
  @moduledoc """
  ID generation helpers.

  IDs are prefixed ASCII slugs so logs, API responses, and persisted records can
  identify their domain without parsing embedded state.
  """

  @type prefix ::
          :round
          | :shot
          | :attempt
          | :tool_call
          | :event
          | :transition
          | :audit
          | :daemon
          | :artifact
          | :workspace
          | :session
          | :sandbox
          | :manager_plan
          | :manager_child

  @callback new(prefix()) :: String.t()

  @prefixes %{
    round: "round",
    shot: "shot",
    attempt: "att",
    tool_call: "tool",
    event: "evt",
    transition: "tr",
    audit: "aud",
    daemon: "daemon",
    artifact: "art",
    workspace: "ws",
    session: "sess",
    sandbox: "sbx",
    manager_plan: "mgr",
    manager_child: "child"
  }

  @spec new(prefix()) :: String.t()
  def new(prefix) when is_map_key(@prefixes, prefix) do
    impl().new(prefix)
  end

  @spec transition_id() :: String.t()
  def transition_id, do: new(:transition)

  @spec prefix_slug(prefix()) :: String.t()
  def prefix_slug(prefix) when is_map_key(@prefixes, prefix), do: @prefixes[prefix]

  defp impl do
    Application.get_env(:twelvgaige, :id_generator, Twelvgaige.ID.Random)
  end
end
