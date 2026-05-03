defmodule Twelvgaige.Store.SQLite.Schema.CommittedTransition do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "committed_transitions" do
    field(:round_id, :string, primary_key: true)
    field(:transition_id, :string, primary_key: true)
  end
end
