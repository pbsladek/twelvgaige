defmodule Twelvgaige.Store.SQLite.Schema.ToolJournal do
  @moduledoc false

  use Ecto.Schema

  @primary_key false
  schema "tool_journals" do
    field(:round_id, :string, primary_key: true)
    field(:shot_id, :string, primary_key: true)
    field(:attempt, :integer, primary_key: true)
    field(:tool_key, :string, primary_key: true)
    field(:status, :string)
    field(:journal, :binary)
  end
end
